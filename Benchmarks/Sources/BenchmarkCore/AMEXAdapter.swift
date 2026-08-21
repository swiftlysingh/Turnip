import Foundation

enum AMEXAdapter {
    struct CriticalRule: Hashable, Sendable {
        let id: String
        let kind: CriticalValueKind
        let labels: [String]
    }

    private static let criticalRules: [CriticalRule] = [
        CriticalRule(id: "new_balance", kind: .amount, labels: ["New Balance"]),
        CriticalRule(id: "minimum_payment", kind: .amount, labels: ["Minimum Payment"]),
        CriticalRule(id: "payment_due_date", kind: .date, labels: ["Payment Due Date"]),
        CriticalRule(id: "credit_limit", kind: .amount, labels: ["Credit Limit"]),
        CriticalRule(id: "payments_credits", kind: .amount, labels: ["Payments/Credits", "Payments and Credits"]),
        CriticalRule(id: "fees", kind: .amount, labels: ["Fees"]),
        CriticalRule(id: "interest", kind: .amount, labels: ["Interest"]),
    ]

    /// This text names the only canonicalization behavior the adapter applies.
    /// The checksum is intentionally independent of PDFs, manifests, and truth.
    static let canonicalizationContract = [
        "merchant=nfc|unicode_case_fold_posix|smart_punctuation|whitespace_collapse",
        "surface=physical_lines|collapsed_statement_markers",
        "line_wrap=adjacent_date_led_missing_amount_only",
        "dates=statement_period_consistent_year_resolution",
        "amounts=strict_decimal_2|strict_comma_grouping|single_direction",
        "matching=exact_multiset_no_alias_no_fuzzy_no_arithmetic_repair",
    ].joined(separator: ";")

    /// Digest of the normalized source aggregate for this adapter and exact
    /// financial scorer. `testAdapterImplementationSourceDigestIsRepinned`
    /// makes a source edit fail until this value and the manifest are repinned.
    static let implementationSourceDigest = "3ca3cd600a1d9407039afb2900b92f8401f6ffea9edf6bbd9fdc8acda7e2abb6"

    static let checksum = contractChecksum(
        contract: canonicalizationContract,
        rules: criticalRules,
        implementationSourceDigest: implementationSourceDigest
    )

    static let criticalValueKinds: [String: CriticalValueKind] = Dictionary(
        uniqueKeysWithValues: criticalRules.map { ($0.id, $0.kind) }
    )

    /// Adapters receive only one raw candidate surface. They have no truth, PDF,
    /// layout, page text, or candidate-specific expected-value input.
    static func extract(rawSurface: String) throws -> FinancialExtraction {
        try FinancialNormalizer.normalize(rawSurface: rawSurface, rules: criticalRules)
    }

    static func contractChecksum(
        contract: String,
        rules: [CriticalRule],
        implementationSourceDigest: String
    ) -> String {
        let description = [BenchmarkProfile.adapterRevision, contract, implementationSourceDigest]
            + rules.flatMap { [$0.id, $0.kind.rawValue] + $0.labels }
        return Digest.sha256Hex(Data(description.joined(separator: "|").utf8))
    }

    static func checksum(forCanonicalizationContract contract: String) -> String {
        contractChecksum(
            contract: contract,
            rules: criticalRules,
            implementationSourceDigest: implementationSourceDigest
        )
    }
}

/// Shared deterministic canonicalization for adapter extraction and scoring.
/// It deliberately has no access to corpus, truth, or candidate identity.
enum FinancialNormalizer {
    static func normalize(
        rawSurface: String,
        rules: [AMEXAdapter.CriticalRule]
    ) throws -> FinancialExtraction {
        guard !rawSurface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AdapterFailure.emptySurface
        }

        let physicalLines = rawSurface
            .split(whereSeparator: { $0.isNewline })
            .map(cleanLine)
            .filter { !$0.isEmpty }
        let lines = expandCollapsedSurface(physicalLines, rules: rules)
        let statementContext = try findStatementContext(in: lines)
        let statementPeriod = statementContext?.periodToken
        let currency = try findCurrency(in: lines)

        var transactions: [TransactionRow] = []
        var criticalValues: [CanonicalCriticalValue] = []
        var malformedTransactionCandidates = 0
        var unexpectedCriticalCandidates = 0
        var inTransactions = false
        var inTransactionSummary = false
        var sawTransactionSection = false
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if isStatementMetadata(line) {
                index += 1
                continue
            }
            if isTransactionHeading(line) {
                inTransactions = true
                inTransactionSummary = false
                sawTransactionSection = true
                index += 1
                continue
            }
            if isTransactionSummaryHeading(line) {
                inTransactions = false
                inTransactionSummary = true
                index += 1
                continue
            }
            if inTransactions, isTransactionHeader(line) {
                index += 1
                continue
            }

            if inTransactions, let prefix = datePrefix(in: line) {
                if let transaction = parseTransaction(
                    line: line,
                    prefix: prefix,
                    statementContext: statementContext
                ) {
                    transactions.append(transaction)
                    index += 1
                    continue
                }

                if let transaction = joinedWrappedTransaction(
                    firstLine: line,
                    prefix: prefix,
                    nextLine: index + 1 < lines.count ? lines[index + 1] : nil,
                    statementContext: statementContext
                ) {
                    transactions.append(transaction)
                    index += 2
                    continue
                }

                malformedTransactionCandidates += 1
                index += 1
                continue
            }

            if let critical = parseCritical(line: line, currency: currency, rules: rules) {
                criticalValues.append(critical)
            } else if isKnownCriticalCandidate(line, rules: rules)
                || looksLikeSummaryCandidate(line, inTransactionSummary: inTransactionSummary)
            {
                // Preserve an unknown or malformed summary candidate as an
                // unexpected critical without retaining its source text.
                unexpectedCriticalCandidates += 1
            } else if inTransactionSummary,
                datePrefix(in: line) != nil || containsAmountLikeToken(line)
            {
                // The summary heading closes transaction parsing, but a
                // date-led or amount-like non-field line there is still a
                // transaction-shaped candidate. Count it as a row false
                // positive instead of letting it disappear.
                malformedTransactionCandidates += 1
            } else if inTransactions, looksTransactionLike(line) {
                // A bare amount, an amount-like string, or another numeric lead
                // in a transaction section cannot quietly disappear from
                // financial scoring. Known/unknown summaries above remain
                // eligible regardless of whether they occur before or after it.
                malformedTransactionCandidates += 1
            }
            index += 1
        }

        guard sawTransactionSection else {
            throw AdapterFailure.missingTransactionSection
        }
        return FinancialExtraction(
            statementCurrency: currency,
            statementPeriod: statementPeriod,
            transactions: transactions,
            criticalValues: criticalValues,
            malformedTransactionCandidates: malformedTransactionCandidates,
            unexpectedCriticalCandidates: unexpectedCriticalCandidates
        )
    }

    private static let stableLocale = Locale(identifier: "en_US_POSIX")

    private static func cleanLine(_ raw: Substring) -> String {
        var line = normalizePresentation(String(raw))
        // These are Markdown/table wrappers, not statement content.
        line = line.replacingOccurrences(of: "|", with: " ")
        line = line.replacingOccurrences(of: "`", with: "")
        line = line.replacingOccurrences(of: "*", with: "")
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while line.first == "#" {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        return collapseWhitespace(line)
    }

    /// Some extractors expose a visually line-oriented statement as one
    /// whitespace-separated string. Reconstruct only explicit statement field,
    /// section, and transaction-date boundaries before applying the same parser
    /// used for physical lines. This is surface-shape handling, not a
    /// candidate-specific rule or a truth-derived repair.
    private static func expandCollapsedSurface(
        _ lines: [String],
        rules: [AMEXAdapter.CriticalRule]
    ) -> [String] {
        guard lines.count == 1 else { return lines }
        let surface = lines[0]
        var boundaries = [surface.startIndex]
        let markers = [
            "Statement Period:", "Currency:", "Transactions", "Transaction Activity",
            "Transaction Summary", "Date Description Amount",
        ] + rules.flatMap { $0.labels.map { $0 + ":" } }

        for marker in markers {
            var searchRange = surface.startIndex ..< surface.endIndex
            while let range = surface.range(
                of: marker,
                options: .caseInsensitive,
                range: searchRange,
                locale: stableLocale
            ) {
                boundaries.append(range.lowerBound)
                searchRange = range.upperBound ..< surface.endIndex
            }
        }

        if let header = surface.range(
            of: "Date Description Amount",
            options: .caseInsensitive,
            range: surface.startIndex ..< surface.endIndex,
            locale: stableLocale
        ) {
            let markerEnd = boundaries
                .filter { $0 > header.upperBound }
                .min() ?? surface.endIndex
            boundaries.append(contentsOf: transactionDateBoundaries(
                in: surface,
                from: header.upperBound,
                through: markerEnd
            ))
        }

        let ordered = boundaries.sorted().reduce(into: [String.Index]()) { result, boundary in
            if result.last != boundary { result.append(boundary) }
        }
        guard ordered.count > 1 else { return lines }
        return ordered.enumerated().compactMap { offset, start in
            let end = offset + 1 < ordered.count ? ordered[offset + 1] : surface.endIndex
            let line = cleanLine(surface[start ..< end])
            return line.isEmpty ? nil : line
        }
    }

    private static func transactionDateBoundaries(
        in surface: String,
        from start: String.Index,
        through end: String.Index
    ) -> [String.Index] {
        var result: [String.Index] = []
        var index = start
        while index < end {
            let beginsToken = index == surface.startIndex || surface[surface.index(before: index)].isWhitespace
            if beginsToken {
                let tokenEnd = surface[index ..< end].firstIndex(where: { $0.isWhitespace }) ?? end
                if parseDateParts(String(surface[index ..< tokenEnd])) != nil {
                    result.append(index)
                    index = tokenEnd
                    continue
                }
            }
            index = surface.index(after: index)
        }
        return result
    }

    static func normalizeMerchant(_ value: String) -> String {
        collapseWhitespace(
            normalizePresentation(value)
                .folding(options: [.caseInsensitive], locale: stableLocale)
        )
    }

    private static func normalizePresentation(_ value: String) -> String {
        let punctuation: [Character: Character] = [
            "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'",
            "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{201F}": "\"",
            "\u{2010}": "-", "\u{2011}": "-", "\u{2012}": "-", "\u{2013}": "-", "\u{2014}": "-", "\u{2212}": "-",
        ]
        return String(value.precomposedStringWithCanonicalMapping.map { punctuation[$0] ?? $0 })
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func fold(_ value: String) -> String {
        normalizePresentation(value).folding(options: [.caseInsensitive], locale: stableLocale)
    }

    private static func isTransactionHeading(_ line: String) -> Bool {
        let normalized = fold(line)
        return normalized == "transactions" || normalized == "transaction activity"
    }

    private static func isTransactionSummaryHeading(_ line: String) -> Bool {
        fold(line) == "transaction summary"
    }

    private static func isStatementMetadata(_ line: String) -> Bool {
        let normalized = fold(line)
        return normalized.hasPrefix("statement period") || normalized.hasPrefix("currency")
    }

    private static func isTransactionHeader(_ line: String) -> Bool {
        let normalized = fold(line)
        return normalized.contains("date")
            && normalized.contains("description")
            && normalized.contains("amount")
    }

    private static func parseCritical(
        line: String,
        currency: String?,
        rules: [AMEXAdapter.CriticalRule]
    ) -> CanonicalCriticalValue? {
        for rule in rules {
            for label in rule.labels {
                guard let range = line.range(
                    of: label,
                    options: [.caseInsensitive, .anchored],
                    range: line.startIndex ..< line.endIndex,
                    locale: stableLocale
                ) else { continue }
                let remainder = String(line[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                // A known label embedded in merchant prose is not a summary.
                // The explicit field delimiter keeps transaction merchants from
                // becoming critical values when summaries follow the table.
                guard remainder.first == ":" else { continue }
                let fieldValue = String(remainder.dropFirst())
                switch rule.kind {
                case .amount:
                    guard let amountText = trailingAmount(in: fieldValue),
                          let amount = parseAmount(amountText)
                    else { continue }
                    return CanonicalCriticalValue(
                        id: rule.id,
                        kind: .amount,
                        signedAmountMinor: amount,
                        date: nil,
                        currency: currency
                    )
                case .date:
                    guard let date = firstFullySpecifiedDate(in: fieldValue) else { continue }
                    return CanonicalCriticalValue(
                        id: rule.id,
                        kind: .date,
                        signedAmountMinor: nil,
                        date: date.isoString,
                        currency: nil
                    )
                }
            }
        }
        return nil
    }

    private static func isKnownCriticalCandidate(
        _ line: String,
        rules: [AMEXAdapter.CriticalRule]
    ) -> Bool {
        rules.contains { rule in
            rule.labels.contains { label in
                guard let range = line.range(
                    of: label,
                    options: [.caseInsensitive, .anchored],
                    range: line.startIndex ..< line.endIndex,
                    locale: stableLocale
                ) else { return false }
                let remainder = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                return remainder.first == ":"
            }
        }
    }

    private static func looksLikeSummaryCandidate(
        _ line: String,
        inTransactionSummary: Bool
    ) -> Bool {
        guard let separator = line.firstIndex(of: ":"), separator > line.startIndex else { return false }
        return inTransactionSummary
            || fold(String(line[..<separator])).contains("summary")
            || containsAmountLikeToken(line)
            || firstFullySpecifiedDate(in: line) != nil
    }

    private static func looksTransactionLike(_ line: String) -> Bool {
        datePrefix(in: line) != nil
            || line.first?.isNumber == true
            || containsAmountLikeToken(line)
    }

    private static func containsAmountLikeToken(_ value: String) -> Bool {
        if value.contains("$") { return true }
        let folded = fold(value)
        if folded.contains(" cr") || folded.contains(" dr") { return true }
        return value.contains(".") && value.contains(where: \.isNumber)
    }

    private static func datePrefix(in line: String) -> (token: String, remainder: String)? {
        let pieces = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let token = pieces.first else { return nil }
        let tokenString = String(token)
        guard looksLikeDate(tokenString) else { return nil }
        let remainder = pieces.count == 2 ? String(pieces[1]) : ""
        return (tokenString, remainder)
    }

    private static func parseTransaction(
        line: String,
        prefix: (token: String, remainder: String),
        statementContext: StatementPeriodContext?
    ) -> TransactionRow? {
        guard let date = resolveTransactionDate(prefix.token, in: statementContext),
              let amountText = trailingAmount(in: prefix.remainder),
              let amount = parseAmount(amountText)
        else { return nil }

        let words = prefix.remainder.split(whereSeparator: { $0.isWhitespace })
        let amountWordCount = amountText.split(whereSeparator: { $0.isWhitespace }).count
        guard words.count > amountWordCount else { return nil }
        let merchant = normalizeMerchant(words.dropLast(amountWordCount).joined(separator: " "))
        guard !merchant.isEmpty else { return nil }
        return TransactionRow(date: date.isoString, merchant: merchant, signedAmountMinor: amount, pageIndex: nil)
    }

    /// The only accepted join is an adjacent date-led row with no amount-like
    /// token, followed by a non-date continuation ending in one valid amount.
    private static func joinedWrappedTransaction(
        firstLine: String,
        prefix: (token: String, remainder: String),
        nextLine: String?,
        statementContext: StatementPeriodContext?
    ) -> TransactionRow? {
        guard !containsAmountLikeToken(prefix.remainder),
              !prefix.remainder.trimmingCharacters(in: .whitespaces).isEmpty,
              let nextLine,
              datePrefix(in: nextLine) == nil,
              !isTransactionHeading(nextLine),
              !isTransactionHeader(nextLine),
              !nextLine.contains(":"),
              trailingAmount(in: nextLine) != nil
        else { return nil }
        return parseTransaction(
            line: firstLine + " " + nextLine,
            prefix: datePrefix(in: firstLine + " " + nextLine)!,
            statementContext: statementContext
        )
    }

    private static func trailingAmount(in value: String) -> String? {
        let words = value.split(whereSeparator: { $0.isWhitespace })
        guard let last = words.last else { return nil }
        let lastString = String(last)
        if parseAmount(lastString) != nil { return lastString }
        guard words.count >= 2,
              let direction = directionToken(lastString)
        else { return nil }
        let candidate = String(words[words.count - 2]) + " " + direction
        return parseAmount(candidate) == nil ? nil : candidate
    }

    /// Reject malformed grouping, unsupported precision, plus signs, and every
    /// combination of direction markers. A single parenthesized, leading-minus,
    /// trailing-minus, CR, or DR direction is permitted.
    private static func parseAmount(_ input: String) -> Int64? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        var directionNegative: Bool?
        if value.count >= 2 {
            let suffix = String(value.suffix(2)).uppercased(with: stableLocale)
            if suffix == "CR" || suffix == "DR" {
                let before = value.dropLast(2)
                guard before.last?.isLetter != true else { return nil }
                directionNegative = suffix == "CR"
                value = before.trimmingCharacters(in: .whitespaces)
            }
        }

        var explicitNegative: Bool?
        if value.hasPrefix("(") || value.hasSuffix(")") {
            guard value.hasPrefix("("), value.hasSuffix(")"),
                  !value.dropFirst().dropLast().contains("(") && !value.dropFirst().dropLast().contains(")")
            else { return nil }
            explicitNegative = true
            value.removeFirst()
            value.removeLast()
        } else if value.contains("(") || value.contains(")") {
            return nil
        }

        if value.hasPrefix("-") {
            guard explicitNegative == nil else { return nil }
            explicitNegative = true
            value.removeFirst()
        }
        if value.hasSuffix("-") {
            guard explicitNegative == nil else { return nil }
            explicitNegative = true
            value.removeLast()
        }
        guard !value.contains("-") && !value.contains("+") else { return nil }
        guard explicitNegative == nil || directionNegative == nil else { return nil }

        if value.hasPrefix("$") {
            value.removeFirst()
        }
        guard !value.isEmpty, !value.contains("$") else { return nil }

        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[1].count == 2,
              pieces[1].allSatisfy(\.isNumber),
              validWholeAmount(String(pieces[0])),
              let major = Int64(String(pieces[0]).replacingOccurrences(of: ",", with: "")),
              let minor = Int64(pieces[1])
        else { return nil }
        let multiplied = major.multipliedReportingOverflow(by: 100)
        guard !multiplied.overflow else { return nil }
        let combined = multiplied.partialValue.addingReportingOverflow(minor)
        guard !combined.overflow else { return nil }
        let negative = explicitNegative ?? directionNegative ?? false
        return negative ? -combined.partialValue : combined.partialValue
    }

    private static func validWholeAmount(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if !value.contains(",") {
            return value.allSatisfy(\.isNumber)
        }
        let pieces = value.split(separator: ",", omittingEmptySubsequences: false)
        guard pieces.count >= 2, (1 ... 3).contains(pieces[0].count),
              pieces[0].allSatisfy(\.isNumber)
        else { return false }
        return pieces.dropFirst().allSatisfy { $0.count == 3 && $0.allSatisfy(\.isNumber) }
    }

    private static func directionToken(_ value: String) -> String? {
        let folded = value.uppercased(with: stableLocale)
        return folded == "CR" || folded == "DR" ? folded : nil
    }

    private static func findStatementContext(in lines: [String]) throws -> StatementPeriodContext? {
        var result: StatementPeriodContext?
        for line in lines where fold(line).contains("statement period") {
            let dates = dateTokens(in: line).compactMap(parseFullySpecifiedDate)
            guard dates.count >= 2, let context = StatementPeriodContext(start: dates[0], end: dates[1]) else {
                continue
            }
            if let result, result != context {
                throw AdapterFailure.conflictingStatementMetadata
            }
            result = context
        }
        return result
    }

    private static func findCurrency(in lines: [String]) throws -> String? {
        var result: String?
        for line in lines where fold(line).contains("currency") {
            for word in line.split(whereSeparator: { !$0.isLetter }) {
                let candidate = String(word).uppercased(with: stableLocale)
                if candidate.count == 3, candidate.allSatisfy(\.isASCII), candidate.allSatisfy(\.isLetter) {
                    if let result, result != candidate {
                        throw AdapterFailure.conflictingStatementMetadata
                    }
                    result = candidate
                }
            }
        }
        return result
    }

    private static func dateTokens(in value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for scalar in value.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) || scalar == "/" || scalar == "-" {
                current.unicodeScalars.append(scalar)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func firstFullySpecifiedDate(in value: String) -> CalendarDate? {
        dateTokens(in: value).compactMap(parseFullySpecifiedDate).first
    }

    private static func looksLikeDate(_ value: String) -> Bool {
        parseDateParts(value) != nil
    }

    private static func parseFullySpecifiedDate(_ value: String) -> CalendarDate? {
        guard let parts = parseDateParts(value), let year = parts.year, year >= 1900, year <= 2999 else {
            return nil
        }
        return CalendarDate(year: year, month: parts.month, day: parts.day)
    }

    private static func resolveTransactionDate(
        _ value: String,
        in context: StatementPeriodContext?
    ) -> CalendarDate? {
        guard let context, let parts = parseDateParts(value) else { return nil }
        if let year = parts.year {
            guard let date = CalendarDate(year: year, month: parts.month, day: parts.day), context.contains(date) else {
                return nil
            }
            return date
        }

        let years = context.years.filter { year in
            guard let date = CalendarDate(year: year, month: parts.month, day: parts.day) else { return false }
            if let suffix = parts.twoDigitYear, year % 100 != suffix { return false }
            return context.contains(date)
        }
        guard years.count == 1 else { return nil }
        return CalendarDate(year: years[0], month: parts.month, day: parts.day)
    }

    private static func parseDateParts(_ value: String) -> DateParts? {
        let separator: Character
        if value.contains("/") {
            separator = "/"
        } else if value.contains("-") {
            separator = "-"
        } else {
            return nil
        }
        let parts = value.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        let month: Int
        let day: Int
        let yearPart: Substring?
        if separator == "-", parts.count == 3, parts[0].count == 4 {
            guard let parsedYear = Int(parts[0]), let parsedMonth = Int(parts[1]), let parsedDay = Int(parts[2]) else {
                return nil
            }
            return DateParts(month: parsedMonth, day: parsedDay, year: parsedYear, twoDigitYear: nil)
        } else {
            guard let parsedMonth = Int(parts[0]), let parsedDay = Int(parts[1]) else { return nil }
            month = parsedMonth
            day = parsedDay
            yearPart = parts.count == 3 ? parts[2] : nil
        }

        if let yearPart {
            if yearPart.count == 4, let year = Int(yearPart) {
                return DateParts(month: month, day: day, year: year, twoDigitYear: nil)
            }
            if yearPart.count == 2, let twoDigitYear = Int(yearPart) {
                return DateParts(month: month, day: day, year: nil, twoDigitYear: twoDigitYear)
            }
            return nil
        }
        return DateParts(month: month, day: day, year: nil, twoDigitYear: nil)
    }
}

private struct DateParts {
    let month: Int
    let day: Int
    let year: Int?
    let twoDigitYear: Int?
}

private struct CalendarDate: Comparable {
    let year: Int
    let month: Int
    let day: Int

    init?(year: Int, month: Int, day: Int) {
        guard year >= 1900, year <= 2999, month >= 1, month <= 12, day >= 1 else { return nil }
        let daysInMonth = [31, year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) ? 29 : 28,
                           31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= daysInMonth[month - 1] else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    var isoString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

private struct StatementPeriodContext: Equatable {
    let start: CalendarDate
    let end: CalendarDate

    init?(start: CalendarDate, end: CalendarDate) {
        guard start <= end else { return nil }
        self.start = start
        self.end = end
    }

    var periodToken: String {
        String(format: "%04d-%02d", end.year, end.month)
    }

    var years: [Int] {
        Array(start.year ... end.year)
    }

    func contains(_ date: CalendarDate) -> Bool {
        start <= date && date <= end
    }
}
