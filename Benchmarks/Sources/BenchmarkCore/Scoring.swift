import Foundation

enum FinancialScorer {
    static func score(
        truth: FinancialTruth,
        observed: FinancialExtraction
    ) -> FinancialScore {
        let expectedRows = truth.transactions.map {
            RowKey(
                date: $0.date,
                merchant: FinancialNormalizer.normalizeMerchant($0.merchant),
                signedAmountMinor: $0.signedAmountMinor
            )
        }
        let observedRows = observed.transactions.map {
            RowKey(
                date: $0.date,
                merchant: FinancialNormalizer.normalizeMerchant($0.merchant),
                signedAmountMinor: $0.signedAmountMinor
            )
        }
        let row = Multiset.evaluate(
            expected: expectedRows,
            observed: observedRows,
            extraFalsePositives: observed.malformedTransactionCandidates
        )

        let expectedCells = expectedRows.flatMap { CellKey.cells(for: $0) }
        let observedCells = observedRows.flatMap { CellKey.cells(for: $0) }
        let cell = Multiset.evaluate(
            expected: expectedCells,
            observed: observedCells,
            extraFalsePositives: observed.malformedTransactionCandidates * 3
        )

        let token = Multiset.evaluate(
            expected: expectedRows.flatMap { TokenKey.tokens(for: $0) },
            observed: observedRows.flatMap { TokenKey.tokens(for: $0) }
        )

        let expectedByID = Dictionary(grouping: truth.criticalValues, by: \.id)
        let observedByID = Dictionary(grouping: observed.criticalValues, by: \.id)
        var correctCriticalValues = 0
        var duplicateCriticalValues = 0
        var unexpectedCriticalValues = observed.unexpectedCriticalCandidates

        for (id, values) in observedByID {
            if expectedByID[id] == nil {
                unexpectedCriticalValues += values.count
            }
            if values.count > 1 {
                duplicateCriticalValues += values.count - 1
            }
        }
        for expected in truth.criticalValues {
            if let expectedValues = expectedByID[expected.id], expectedValues.count == 1,
               let observedValues = observedByID[expected.id], observedValues.count == 1,
               observedValues[0] == expected
            {
                correctCriticalValues += 1
            }
        }

        let criticalAccuracy: Double
        if truth.criticalValues.isEmpty {
            criticalAccuracy = observed.criticalValues.isEmpty && observed.unexpectedCriticalCandidates == 0 ? 1 : 0
        } else {
            criticalAccuracy = Double(correctCriticalValues) / Double(truth.criticalValues.count)
        }
        let currencyMatches = observed.statementCurrency == truth.statementCurrency
        let periodMatches = observed.statementPeriod == truth.statementPeriod
        let perfect = currencyMatches
            && periodMatches
            && row.falsePositive == 0
            && row.falseNegative == 0
            && row.truePositive == truth.transactions.count
            && correctCriticalValues == truth.criticalValues.count
            && unexpectedCriticalValues == 0
            && duplicateCriticalValues == 0

        return FinancialScore(
            row: row,
            cell: cell,
            contentTokenF1: token.f1,
            criticalAccuracy: criticalAccuracy,
            correctCriticalValues: correctCriticalValues,
            expectedCriticalValues: truth.criticalValues.count,
            unexpectedCriticalValues: unexpectedCriticalValues,
            duplicateCriticalValues: duplicateCriticalValues,
            malformedTransactionCandidates: observed.malformedTransactionCandidates,
            perfect: perfect
        )
    }
}

private struct RowKey: Hashable {
    let date: String
    let merchant: String
    let signedAmountMinor: Int64
}

private struct CellKey: Hashable {
    let field: String
    let value: String

    static func cells(for row: RowKey) -> [CellKey] {
        [
            CellKey(field: "date", value: row.date),
            CellKey(field: "merchant", value: row.merchant),
            CellKey(field: "signed_amount_minor", value: String(row.signedAmountMinor)),
        ]
    }
}

private struct TokenKey: Hashable {
    let value: String

    static func tokens(for row: RowKey) -> [TokenKey] {
        [TokenKey(value: row.date), TokenKey(value: String(row.signedAmountMinor))]
            + row.merchant.split(whereSeparator: { $0.isWhitespace }).map { TokenKey(value: String($0)) }
    }
}

enum Multiset {
    static func evaluate<Element: Hashable>(
        expected: [Element],
        observed: [Element],
        extraFalsePositives: Int = 0
    ) -> MultisetScore {
        var expectedCounts: [Element: Int] = [:]
        var observedCounts: [Element: Int] = [:]
        for value in expected { expectedCounts[value, default: 0] += 1 }
        for value in observed { observedCounts[value, default: 0] += 1 }

        let truePositive = expectedCounts.reduce(into: 0) { partial, entry in
            partial += min(entry.value, observedCounts[entry.key, default: 0])
        }
        let falsePositive = observed.count - truePositive + extraFalsePositives
        let falseNegative = expected.count - truePositive
        let f1: Double
        if expected.isEmpty, observed.isEmpty, extraFalsePositives == 0 {
            f1 = 1
        } else if expected.isEmpty || observed.isEmpty {
            f1 = 0
        } else {
            let denominator = 2 * truePositive + falsePositive + falseNegative
            f1 = denominator == 0 ? 0 : Double(2 * truePositive) / Double(denominator)
        }
        return MultisetScore(
            truePositive: truePositive,
            falsePositive: falsePositive,
            falseNegative: falseNegative,
            f1: f1
        )
    }
}

enum Determinism {
    static func rawIsDeterministic(_ outputs: [CandidateOutcome<String>]) -> Bool {
        guard let first = outputs.first else { return false }
        return outputs.dropFirst().allSatisfy { $0 == first }
    }

    static func semanticIsDeterministic(_ outputs: [CandidateOutcome<FinancialExtraction>]) -> Bool {
        guard let first = outputs.first else { return false }
        return outputs.dropFirst().allSatisfy { $0 == first }
    }
}
