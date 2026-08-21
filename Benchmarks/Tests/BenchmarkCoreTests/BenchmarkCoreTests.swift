@testable import BenchmarkCore
import DocumentKit
import Foundation
import XCTest

final class BenchmarkCoreTests: XCTestCase {
    func testExactRowsAndCriticalValuesArePerfect() {
        let rows = [
            row("2026-01-03", "Lantern Cafe", 1234),
            row("2026-01-04", "Orbit Paper Co.", -500),
        ]
        let criticals = [amount("new_balance", 734)]
        let truth = makeTruth(rows: rows, criticals: criticals)
        let observed = extraction(rows: rows, criticals: criticals)

        let score = FinancialScorer.score(truth: truth, observed: observed)
        XCTAssertEqual(score.row.f1, 1)
        XCTAssertEqual(score.cell.f1, 1)
        XCTAssertEqual(score.criticalAccuracy, 1)
        XCTAssertTrue(score.perfect)
    }

    func testSwappedAmountsKeepCellF1ButFailRowF1() {
        let expected = [row("2026-01-03", "Alpha Store", 100), row("2026-01-04", "Beta Store", 200)]
        let observed = [row("2026-01-03", "Alpha Store", 200), row("2026-01-04", "Beta Store", 100)]
        let score = FinancialScorer.score(
            truth: makeTruth(rows: expected, criticals: [amount("new_balance", 300)]),
            observed: extraction(rows: observed, criticals: [amount("new_balance", 300)])
        )

        XCTAssertEqual(score.cell.f1, 1)
        XCTAssertEqual(score.row.f1, 0)
        XCTAssertFalse(score.perfect)
    }

    func testMultisetScoringPreservesMissingExtraDuplicateAndLegitimateDuplicates() {
        let first = row("2026-01-03", "Alpha Store", 100)
        let second = row("2026-01-04", "Beta Store", 200)
        let truth = makeTruth(rows: [first, second, second], criticals: [amount("new_balance", 500)])

        let missing = FinancialScorer.score(
            truth: truth,
            observed: extraction(rows: [first, second], criticals: [amount("new_balance", 500)])
        )
        XCTAssertEqual(missing.row.truePositive, 2)
        XCTAssertEqual(missing.row.falseNegative, 1)

        let extra = FinancialScorer.score(
            truth: truth,
            observed: extraction(
                rows: [first, second, second, row("2026-01-05", "Gamma Store", 300)],
                criticals: [amount("new_balance", 500)]
            )
        )
        XCTAssertEqual(extra.row.falsePositive, 1)

        let exactDuplicate = FinancialScorer.score(
            truth: truth,
            observed: extraction(rows: [first, second, second], criticals: [amount("new_balance", 500)])
        )
        XCTAssertEqual(exactDuplicate.row.f1, 1)

        let merged = FinancialScorer.score(
            truth: truth,
            observed: extraction(
                rows: [row("2026-01-03", "Alpha Store Beta Store", 300)],
                criticals: [amount("new_balance", 500)]
            )
        )
        XCTAssertEqual(merged.row.f1, 0)
    }

    func testAdapterNormalizesOnlyAllowedFormsAndParsesSigns() throws {
        let raw = """
        Statement Period: 01/01/2026 - 01/31/2026
        Currency: USD
        New Balance: $1.00
        Transactions
        Date Description Amount
        01/03 Cafe\u{0301} Lantern $12.34
        01/04 Queen’s—Shop ($5.00)
        01/05 Card Credit $6.00 CR
        01/06 Debit Shop $7.00 DR
        01/07 Leading Minus -$8.00
        01/08 Trailing Minus $9.99-
        01/09 Wrapped
        Merchant $10.01
        """

        let result = try AMEXAdapter.extract(rawSurface: raw)
        XCTAssertEqual(result.statementPeriod, "2026-01")
        XCTAssertEqual(result.transactions.map(\.signedAmountMinor), [1234, -500, -600, 700, -800, -999, 1001])
        XCTAssertEqual(result.transactions[0].merchant, "café lantern")
        XCTAssertEqual(result.transactions[1].merchant, "queen's-shop")
        XCTAssertEqual(result.transactions.last?.merchant, "wrapped merchant")

        let noFuzzy = FinancialScorer.score(
            truth: makeTruth(rows: [row("2026-01-03", "Cafe Lantern", 1234)], criticals: [amount("new_balance", 100)]),
            observed: extraction(
                rows: [row("2026-01-03", "Cafe Lantern North", 1234)],
                criticals: [amount("new_balance", 100)]
            )
        )
        XCTAssertEqual(noFuzzy.row.f1, 0)
    }

    func testMalformedCommaGroupingAmbiguousSignsAndPrecisionAreFalsePositives() throws {
        let raw = """
        Statement Period: 01/01/2026 - 01/31/2026
        Currency: USD
        Transactions
        Date Description Amount
        01/03 Valid Store $1,000.00
        01/04 Broken Group $1,2.34
        01/05 Unsupported Precision $1.234
        01/06 Ambiguous Minus -$1.00-
        01/07 Conflicting Direction ($1.00) CR
        01/08 Multiple Direction $1.00 CR DR
        """
        let observed = try AMEXAdapter.extract(rawSurface: raw)
        XCTAssertEqual(observed.transactions.map(\.signedAmountMinor), [100_000])
        XCTAssertEqual(observed.malformedTransactionCandidates, 5)

        let score = FinancialScorer.score(
            truth: makeTruth(rows: [row("2026-01-03", "Valid Store", 100_000)], criticals: []),
            observed: observed
        )
        XCTAssertEqual(score.row.truePositive, 1)
        XCTAssertEqual(score.row.falsePositive, 5)
        XCTAssertFalse(score.perfect)
    }

    func testTransactionYearRequiresStatementPeriodConsistency() throws {
        let raw = """
        Statement Period: 01/01/2026 - 01/31/2026
        Currency: USD
        Transactions
        Date Description Amount
        01/03/26 Valid Two Digit $1.00
        01/04/99 Wrong Two Digit $1.00
        02/01 Wrong Period $1.00
        """
        let observed = try AMEXAdapter.extract(rawSurface: raw)
        XCTAssertEqual(observed.transactions.map(\.date), ["2026-01-03"])
        XCTAssertEqual(observed.malformedTransactionCandidates, 2)
    }

    func testCrossWindowTruthAndAdapterRowsAreAccepted() throws {
        let raw = """
        Statement Period: 12/15/2025 - 01/14/2026
        Currency: USD
        Transactions
        Date Description Amount
        12/31 Year End Store $1.00
        01/02 New Year Store $2.00
        """
        let observed = try AMEXAdapter.extract(rawSurface: raw)
        XCTAssertEqual(observed.statementPeriod, "2026-01")
        XCTAssertEqual(observed.transactions.map(\.date), ["2025-12-31", "2026-01-02"])

        let truth = makeTruth(
            rows: observed.transactions.map {
                row($0.date, $0.merchant, $0.signedAmountMinor)
            },
            criticals: [],
            statementPeriod: "2026-01"
        )
        XCTAssertTrue(FinancialScorer.score(truth: truth, observed: observed).perfect)

        let corpus = try makeTemporaryCorpus(truth: truth)
        defer { corpus.cleanup() }
        XCTAssertNoThrow(try CorpusPreflight.validate(configuration: corpus.configuration))
    }

    func testCriticalValuesAfterTableAndUnknownSummaryCandidatesAreCounted() throws {
        let raw = """
        Statement Period: 01/01/2026 - 01/31/2026
        Currency: USD
        Transactions
        Date Description Amount
        01/03 Lantern Cafe $12.34
        Transaction Summary
        New Balance: $127.33
        Minimum Payment: $25.00
        Payment Due Date: 02/15/2026
        Credit Limit: $1,000.00
        Payments/Credits: $50.00 CR
        Fees: $0.00
        Interest: $1.23
        Unregistered Summary: $2.00
        Other Date: 02/20/2026
        """
        let observed = try AMEXAdapter.extract(rawSurface: raw)
        XCTAssertEqual(observed.transactions.count, 1)
        XCTAssertEqual(Set(observed.criticalValues.map(\.id)), Set(AMEXAdapter.criticalValueKinds.keys))
        XCTAssertEqual(observed.unexpectedCriticalCandidates, 2)
        XCTAssertEqual(observed.criticalValues.first(where: { $0.id == "payments_credits" })?.signedAmountMinor, -5_000)
    }

    func testConflictingStatementMetadataFailsAndIdenticalDuplicatesDeduplicate() throws {
        let shared = """
        Statement Period: 01/01/2026 - 01/31/2026
        Currency: USD
        Transactions
        Date Description Amount
        01/03 Lantern Cafe $12.34
        """
        let duplicated = """
        \(shared)
        Statement Period: 01/01/2026 - 01/31/2026
        Currency: USD
        """
        XCTAssertNoThrow(try AMEXAdapter.extract(rawSurface: duplicated))

        let conflictingCurrency = """
        \(shared)
        Currency: EUR
        """
        XCTAssertThrowsError(try AMEXAdapter.extract(rawSurface: conflictingCurrency)) { error in
            XCTAssertEqual(error as? AdapterFailure, .conflictingStatementMetadata)
        }

        let conflictingPeriod = """
        \(shared)
        Statement Period: 02/01/2026 - 02/28/2026
        """
        XCTAssertThrowsError(try AMEXAdapter.extract(rawSurface: conflictingPeriod)) { error in
            XCTAssertEqual(error as? AdapterFailure, .conflictingStatementMetadata)
        }
    }

    func testMalformedKnownCriticalCandidateIsUnexpected() throws {
        let raw = """
        Statement Period: 01/01/2026 - 01/31/2026
        Currency: USD
        Transactions
        Date Description Amount
        01/03 Lantern Cafe $12.34
        New Balance: N/A
        """
        let observed = try AMEXAdapter.extract(rawSurface: raw)
        XCTAssertTrue(observed.criticalValues.isEmpty)
        XCTAssertEqual(observed.unexpectedCriticalCandidates, 1)
        let score = FinancialScorer.score(
            truth: makeTruth(
                rows: [row("2026-01-03", "Lantern Cafe", 1234)],
                criticals: [amount("new_balance", 12733)]
            ),
            observed: observed
        )
        XCTAssertEqual(score.criticalAccuracy, 0)
        XCTAssertEqual(score.unexpectedCriticalValues, 1)
        XCTAssertFalse(score.perfect)
    }

    func testCriticalOwnershipCurrencyMultiplicityAndStatementPeriodGuards() {
        let expectedCriticals = [
            amount("new_balance", 100),
            CanonicalCriticalValue(id: "payment_due_date", kind: .date, signedAmountMinor: nil, date: "2026-02-15", currency: nil),
        ]
        let truth = makeTruth(rows: [row("2026-01-03", "Alpha Store", 100)], criticals: expectedCriticals)
        let wrongCurrency = FinancialScorer.score(
            truth: truth,
            observed: FinancialExtraction(
                statementCurrency: "EUR",
                statementPeriod: "2026-01",
                transactions: [row("2026-01-03", "Alpha Store", 100)],
                criticalValues: [
                    CanonicalCriticalValue(id: "new_balance", kind: .amount, signedAmountMinor: 100, date: nil, currency: "EUR"),
                    CanonicalCriticalValue(id: "payment_due_date", kind: .date, signedAmountMinor: nil, date: "2026-02-16", currency: nil),
                ]
            )
        )
        XCTAssertEqual(wrongCurrency.row.f1, 1)
        XCTAssertEqual(wrongCurrency.criticalAccuracy, 0)
        XCTAssertFalse(wrongCurrency.perfect)

        let duplicate = FinancialScorer.score(
            truth: makeTruth(rows: [], criticals: [amount("new_balance", 100)]),
            observed: extraction(
                rows: [],
                criticals: [amount("new_balance", 100), amount("new_balance", 100)]
            )
        )
        XCTAssertEqual(duplicate.criticalAccuracy, 0)
        XCTAssertEqual(duplicate.duplicateCriticalValues, 1)

        let wrongPeriod = FinancialScorer.score(
            truth: truth,
            observed: extraction(
                rows: truth.transactions,
                criticals: expectedCriticals,
                period: "2026-02"
            )
        )
        XCTAssertEqual(wrongPeriod.row.f1, 1)
        XCTAssertFalse(wrongPeriod.perfect)
    }

    func testZeroMinorUnitTruthDoesNotTripPrivacySubstringScanning() async throws {
        let corpus = try makeTemporaryCorpus(
            truth: makeTruth(
                rows: [row("2026-01-03", "Alpha Store", 100)],
                criticals: [amount("fees", 0)]
            )
        )
        defer { corpus.cleanup() }
        do {
            _ = try await BenchmarkRunner.run(corpus.configuration)
        } catch {
            XCTFail("zero-valued truth must not trip privacy validation: \(error)")
        }
    }

    func testEmptyMultisetRulesAndNativeSHA256KnownVector() {
        XCTAssertEqual(Multiset.evaluate(expected: [String](), observed: []).f1, 1)
        XCTAssertEqual(Multiset.evaluate(expected: ["row"], observed: []).f1, 0)
        XCTAssertEqual(Multiset.evaluate(expected: [String](), observed: ["row"]).f1, 0)
        XCTAssertEqual(
            Digest.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testAdapterContractChecksumPinsCanonicalizationContract() {
        XCTAssertNotEqual(
            AMEXAdapter.checksum,
            AMEXAdapter.checksum(forCanonicalizationContract: AMEXAdapter.canonicalizationContract + ";changed")
        )
    }

    func testAdapterImplementationSourceDigestIsRepinned() throws {
        let sourceFiles = ["AMEXAdapter.swift", "Scoring.swift"]
        var aggregate = Data()
        for name in sourceFiles {
            let sourceURL = benchmarkRoot.appendingPathComponent("Sources/BenchmarkCore/\(name)")
            var source = try String(contentsOf: sourceURL, encoding: .utf8)
            if name == "AMEXAdapter.swift" {
                let normalized = source.replacingOccurrences(
                    of: #"static let implementationSourceDigest = "[0-9a-f]{64}""#,
                    with: #"static let implementationSourceDigest = "<pinned-source-digest>""#,
                    options: .regularExpression
                )
                XCTAssertNotEqual(source, normalized, "adapter source digest literal is missing or malformed")
                source = normalized
            }
            aggregate.append(contentsOf: Data(name.utf8))
            aggregate.append(contentsOf: [0])
            aggregate.append(contentsOf: Data(source.utf8))
            aggregate.append(contentsOf: [0])
        }
        XCTAssertEqual(AMEXAdapter.implementationSourceDigest, Digest.sha256Hex(aggregate))
    }

    func testRawAndOrderedSemanticNondeterminismAreDetected() {
        let extraction = extraction(rows: [row("2026-01-03", "Alpha Store", 100)], criticals: [amount("new_balance", 100)])
        let rawWhitespaceAttempts = [
            MeasuredAttempt(rawOutcome: .success("raw surface"), semanticOutcome: .success(extraction), elapsedMilliseconds: 1),
            MeasuredAttempt(rawOutcome: .success("raw  surface"), semanticOutcome: .success(extraction), elapsedMilliseconds: 2),
        ]
        let rawResult = BenchmarkRunner.makeCaseCandidateReport(
            candidate: .documentKitMarkdown,
            attempts: rawWhitespaceAttempts,
            truth: makeTruth(rows: extraction.transactions, criticals: extraction.criticalValues)
        ).report
        XCTAssertFalse(rawResult.rawDeterministic)
        XCTAssertTrue(rawResult.semanticDeterministic)
        XCTAssertFalse(rawResult.timingEligible)
        XCTAssertFalse(rawResult.score.perfect)

        let reordered = FinancialExtraction(
            statementCurrency: "USD",
            statementPeriod: "2026-01",
            transactions: [
                row("2026-01-04", "Beta Store", 200),
                row("2026-01-03", "Alpha Store", 100),
            ],
            criticalValues: [amount("new_balance", 100)]
        )
        let ordered = FinancialExtraction(
            statementCurrency: "USD",
            statementPeriod: "2026-01",
            transactions: reordered.transactions.reversed(),
            criticalValues: reordered.criticalValues
        )
        XCTAssertFalse(Determinism.semanticIsDeterministic([.success(reordered), .success(ordered)]))
    }

    func testOneFailedExtractionMakesCaseTimingUnavailable() {
        let semantic = extraction(rows: [row("2026-01-03", "Alpha Store", 100)], criticals: [amount("new_balance", 100)])
        var attempts = (1 ... 4).map {
            MeasuredAttempt(rawOutcome: .success("same"), semanticOutcome: .success(semantic), elapsedMilliseconds: Double($0))
        }
        attempts.append(MeasuredAttempt(rawOutcome: .failure("raw_empty"), semanticOutcome: .failure("raw_empty"), elapsedMilliseconds: 5))

        let report = BenchmarkRunner.makeCaseCandidateReport(
            candidate: .documentKitMarkdown,
            attempts: attempts,
            truth: makeTruth(rows: semantic.transactions, criticals: semantic.criticalValues)
        ).report
        XCTAssertNil(report.rawExtractionMedianMilliseconds)
        XCTAssertTrue(report.rawExtractionSamplesMilliseconds.isEmpty)
        XCTAssertEqual(report.successfulTimingAttempts, 4)
        XCTAssertEqual(report.failedTimingAttempts, 1)
        XCTAssertFalse(report.timingEligible)
    }

    func testAdapterFailureRetainsRawExtractionTiming() {
        let truth = makeTruth(
            rows: [row("2026-01-03", "Alpha Store", 100)],
            criticals: [amount("new_balance", 100)]
        )
        let attempts = [5, 1, 3, 2, 4].map {
            MeasuredAttempt(
                rawOutcome: .success("same raw surface"),
                semanticOutcome: .failure("adapter_missing_transaction_section"),
                elapsedMilliseconds: Double($0)
            )
        }

        let report = BenchmarkRunner.makeCaseCandidateReport(
            candidate: .documentKitMarkdown,
            attempts: attempts,
            truth: truth
        ).report
        XCTAssertEqual(report.rawExtractionMedianMilliseconds, 3)
        XCTAssertEqual(report.rawExtractionSamplesMilliseconds, [5, 1, 3, 2, 4])
        XCTAssertTrue(report.timingEligible)
        XCTAssertEqual(report.successfulTimingAttempts, 5)
        XCTAssertEqual(report.failedTimingAttempts, 0)
        XCTAssertTrue(report.executionFailed)
        XCTAssertFalse(report.score.perfect)
    }

    func testMedianAndAggregateUseAllEligibleAttemptSamplesAndEveryCase() {
        XCTAssertEqual(median([5, 1, 3, 2, 4]), 3)
        let first = aggregateCase(token: "c01", period: "p01", samples: [100, 1], includePDFKit: false)
        let second = aggregateCase(token: "c02", period: "p01", samples: [3, 5, 7], includePDFKit: false)
        let reports = BenchmarkRunner.aggregate([first, second])
        let documentKit = reports.first(where: { $0.candidate == Candidate.documentKitMarkdown.label })
        XCTAssertEqual(documentKit?.rawExtractionMedianMilliseconds, 5)
        XCTAssertEqual(documentKit?.totalCases, 2)
        XCTAssertEqual(documentKit?.eligibleCases, 2)
        XCTAssertEqual(documentKit?.macroFinancialTableCellF1, 1)

        let pdfKit = reports.first(where: { $0.candidate == Candidate.pdfKitDocumentString.label })
        XCTAssertEqual(pdfKit?.totalCases, 2)
        XCTAssertEqual(pdfKit?.failedCases, 2)
        XCTAssertEqual(pdfKit?.macroRowF1, 0)

        let timingUnavailable = aggregateCase(
            token: "c03",
            period: "p02",
            samples: [11],
            includePDFKit: false,
            timingEligible: false
        )
        let eligibility = BenchmarkRunner.aggregate([first, timingUnavailable])
        XCTAssertEqual(
            eligibility.first(where: { $0.candidate == Candidate.documentKitMarkdown.label })?.eligibleCases,
            1
        )
    }

    func testInvalidCLIIntegersThrowInvalidInvocation() {
        for arguments in [
            ["--manifest", "m", "--root", "r", "--output", "o", "--warmups", "nope"],
            ["--manifest", "m", "--root", "r", "--output", "o", "--repetitions", "nope"],
            ["--manifest", "m", "--root", "r", "--output", "o", "--warmups", "-1"],
            ["--manifest", "m", "--root", "r", "--output", "o", "--repetitions", "0"],
        ] {
            XCTAssertThrowsError(try BenchmarkCommandLine.configuration(arguments: arguments)) { error in
                XCTAssertEqual(error as? BenchmarkFailure, .invalidInvocation)
            }
        }
    }

    func testSourceRevisionRequiresFullLowercaseGitObject() {
        XCTAssertTrue(ReproducibilityMetadata.isSafeSourceRevision(String(repeating: "a", count: 40)))
        XCTAssertTrue(ReproducibilityMetadata.isSafeSourceRevision(String(repeating: "b", count: 64)))
        XCTAssertTrue(ReproducibilityMetadata.isSafeSourceRevision("working-tree"))
        XCTAssertFalse(ReproducibilityMetadata.isSafeSourceRevision("abcdef1"))
        XCTAssertFalse(ReproducibilityMetadata.isSafeSourceRevision(String(repeating: "A", count: 40)))
        XCTAssertFalse(ReproducibilityMetadata.isSafeSourceRevision(String(repeating: "g", count: 40)))
        XCTAssertEqual(
            ReproducibilityMetadata.sourceRevisionEvidence(for: String(repeating: "a", count: 40)),
            "asserted"
        )
        XCTAssertEqual(ReproducibilityMetadata.sourceRevisionEvidence(for: "working-tree"), "working_tree")
    }

    func testTruthPageRangeAndDuplicateCriticalIDsFailStructurally() throws {
        let pageOutOfRange = makeTruth(
            rows: [row("2026-01-03", "Alpha Store", 100, pageIndex: 1)],
            criticals: [amount("new_balance", 100)]
        )
        let outOfRangeCorpus = try makeTemporaryCorpus(truth: pageOutOfRange)
        defer { outOfRangeCorpus.cleanup() }
        XCTAssertThrowsError(try CorpusPreflight.validate(configuration: outOfRangeCorpus.configuration)) { error in
            XCTAssertEqual(error as? BenchmarkFailure, .invalidTruth)
        }

        let duplicatedCriticals = makeTruth(
            rows: [row("2026-01-03", "Alpha Store", 100)],
            criticals: [amount("new_balance", 100), amount("new_balance", 100)]
        )
        let duplicateCorpus = try makeTemporaryCorpus(truth: duplicatedCriticals)
        defer { duplicateCorpus.cleanup() }
        XCTAssertThrowsError(try CorpusPreflight.validate(configuration: duplicateCorpus.configuration)) { error in
            XCTAssertEqual(error as? BenchmarkFailure, .invalidTruth)
        }
    }

    func testReviewIsRequiredPinnedAndCannotBypassSharedTruthWithDifferentPaths() throws {
        let pending = try makeTemporaryCorpus(reviewStatus: .pending)
        defer { pending.cleanup() }
        XCTAssertThrowsError(try CorpusPreflight.validate(configuration: pending.configuration)) { error in
            XCTAssertEqual(error as? BenchmarkFailure, .invalidEquivalenceReview)
        }

        let pinned = try makeTemporaryCorpus(includeScreenReader: true)
        defer { pinned.cleanup() }
        XCTAssertNoThrow(try CorpusPreflight.validate(configuration: pinned.configuration))
        try Data("{}".utf8).write(to: pinned.root.appendingPathComponent("review.json"), options: .atomic)
        XCTAssertThrowsError(try CorpusPreflight.validate(configuration: pinned.configuration)) { error in
            XCTAssertEqual(error as? BenchmarkFailure, .invalidEquivalenceReview)
        }

        let bypass = try makeTemporaryCorpus(
            includeScreenReader: true,
            secondTruthAtDifferentPath: true,
            splitReviews: true
        )
        defer { bypass.cleanup() }
        XCTAssertThrowsError(try CorpusPreflight.validate(configuration: bypass.configuration)) { error in
            XCTAssertEqual(error as? BenchmarkFailure, .invalidEquivalenceReview)
        }

        let wrongCurrency = try makeTemporaryCorpus(reviewCurrency: "EUR")
        defer { wrongCurrency.cleanup() }
        XCTAssertThrowsError(try CorpusPreflight.validate(configuration: wrongCurrency.configuration)) { error in
            XCTAssertEqual(error as? BenchmarkFailure, .invalidEquivalenceReview)
        }
    }

    func testEndToEndSyntheticCorpusUsesRedactedReportsAndExactCandidateLabels() async throws {
        let corpus = try makeTemporaryCorpus(includeScreenReader: true)
        defer { corpus.cleanup() }
        let bundle = try await BenchmarkRunner.run(corpus.configuration)
        XCTAssertEqual(bundle.detailedReport.cases.count, 2)
        XCTAssertEqual(bundle.shareableReport.candidates.map(\.candidate), [
            "DocumentKit Markdown + AMEX adapter",
            "PDFKit PDFDocument.string + AMEX adapter",
        ])
        for item in bundle.detailedReport.cases {
            for candidate in item.candidates {
                XCTAssertFalse(candidate.executionFailed, "\(item.variant.rawValue) \(candidate.candidate): \(candidate.failureCodes)")
            }
        }
        XCTAssertEqual(bundle.shareableReport.warmups, 0)
        XCTAssertEqual(bundle.shareableReport.repetitions, 1)
        XCTAssertTrue(bundle.shareableText.contains("warmups=0 repetitions=1"))

        let sentinels = [
            "Lantern Cafe", "Orbit Paper Co.", "Northwind Books", "2026-01-03", "$127.33", "USD",
            "acct-9999", "00000000-0000-4000-8000-000000000000", corpus.root.path, "standard.pdf",
            "RAW-SURFACE-SENTINEL", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        ]
        XCTAssertNoThrow(try ReportPrivacy.validate(
            surfaces: [bundle.detailedJSON, bundle.shareableJSON, Data(bundle.shareableText.utf8)],
            forbiddenValues: sentinels
        ))
        XCTAssertFalse(bundle.shareableText.contains("Lantern Cafe"))
        XCTAssertFalse(bundle.shareableText.contains("standard.pdf"))

        XCTAssertThrowsError(try ReportPrivacy.validateJSONKeys(Data("{\"private_field\":true}".utf8)))
        for sentinel in sentinels {
            let text = "{\"profile\":\"\(sentinel)\"}"
            XCTAssertThrowsError(try ReportPrivacy.validate(
                surfaces: [Data(text.utf8)],
                forbiddenValues: [sentinel]
            ))
        }
    }

    func testCommittedSmokeFixtureExercisesBothCandidatePipelines() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("documentkit-benchmark-smoke-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let bundle = try await BenchmarkRunner.run(BenchmarkConfiguration(
            manifestURL: benchmarkRoot.appendingPathComponent("Manifests/smoke-v1.json"),
            rootURL: benchmarkRoot,
            outputURL: output,
            warmups: 0,
            repetitions: 1,
            sourceRevision: "working-tree"
        ))
        for item in bundle.detailedReport.cases {
            for candidate in item.candidates {
                XCTAssertFalse(candidate.executionFailed, "\(item.variant.rawValue) \(candidate.candidate): \(candidate.failureCodes)")
                XCTAssertTrue(candidate.score.perfect, "\(item.variant.rawValue) \(candidate.candidate)")
            }
        }
    }

    private var benchmarkRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func row(_ date: String, _ merchant: String, _ amount: Int64, pageIndex: Int = 0) -> TransactionRow {
        TransactionRow(date: date, merchant: merchant, signedAmountMinor: amount, pageIndex: pageIndex)
    }

    private func amount(_ id: String, _ value: Int64) -> CanonicalCriticalValue {
        CanonicalCriticalValue(id: id, kind: .amount, signedAmountMinor: value, date: nil, currency: "USD")
    }

    private func makeTruth(
        rows: [TransactionRow],
        criticals: [CanonicalCriticalValue],
        statementPeriod: String = "2026-01"
    ) -> FinancialTruth {
        FinancialTruth(
            schemaVersion: BenchmarkProfile.schemaVersion,
            statementID: "synthetic-test-statement",
            statementPeriod: statementPeriod,
            statementCurrency: "USD",
            transactions: rows,
            criticalValues: criticals,
            canonicalMarkdown: CanonicalMarkdownReference(
                path: "canonical.md",
                sha256: String(repeating: "0", count: 64)
            )
        )
    }

    private func replacingCanonicalMarkdown(
        in truth: FinancialTruth,
        with reference: CanonicalMarkdownReference
    ) -> FinancialTruth {
        FinancialTruth(
            schemaVersion: truth.schemaVersion,
            statementID: truth.statementID,
            statementPeriod: truth.statementPeriod,
            statementCurrency: truth.statementCurrency,
            transactions: truth.transactions,
            criticalValues: truth.criticalValues,
            canonicalMarkdown: reference
        )
    }

    private func extraction(
        rows: [TransactionRow],
        criticals: [CanonicalCriticalValue],
        period: String = "2026-01"
    ) -> FinancialExtraction {
        FinancialExtraction(
            statementCurrency: "USD",
            statementPeriod: period,
            transactions: rows,
            criticalValues: criticals
        )
    }

    private func aggregateCase(
        token: String,
        period: String,
        samples: [Double],
        includePDFKit: Bool,
        timingEligible: Bool = true
    ) -> CaseReport {
        let score = FinancialScore(
            row: MultisetScore(truePositive: 1, falsePositive: 0, falseNegative: 0, f1: 1),
            cell: MultisetScore(truePositive: 3, falsePositive: 0, falseNegative: 0, f1: 1),
            contentTokenF1: 1,
            criticalAccuracy: 1,
            correctCriticalValues: 1,
            expectedCriticalValues: 1,
            unexpectedCriticalValues: 0,
            duplicateCriticalValues: 0,
            malformedTransactionCandidates: 0,
            perfect: true
        )
        let candidate = CaseCandidateReport(
            candidate: Candidate.documentKitMarkdown.label,
            rawExtractionMedianMilliseconds: timingEligible ? median(samples) : nil,
            rawExtractionSamplesMilliseconds: timingEligible ? samples : [],
            timingEligible: timingEligible,
            successfulTimingAttempts: timingEligible ? samples.count : 0,
            failedTimingAttempts: timingEligible ? 0 : samples.count,
            rawDeterministic: true,
            semanticDeterministic: true,
            executionFailed: false,
            failureCodes: [],
            score: CaseScoreReport(score)
        )
        var candidates = [candidate]
        if includePDFKit {
            candidates.append(CaseCandidateReport(
                candidate: Candidate.pdfKitDocumentString.label,
                rawExtractionMedianMilliseconds: timingEligible ? median(samples) : nil,
                rawExtractionSamplesMilliseconds: timingEligible ? samples : [],
                timingEligible: timingEligible,
                successfulTimingAttempts: timingEligible ? samples.count : 0,
                failedTimingAttempts: timingEligible ? 0 : samples.count,
                rawDeterministic: true,
                semanticDeterministic: true,
                executionFailed: false,
                failureCodes: [],
                score: CaseScoreReport(score)
            ))
        }
        return CaseReport(
            caseToken: token,
            statementPeriodCluster: period,
            variant: .standard,
            pages: 1,
            inputBytes: 1,
            transactionRows: 1,
            criticalValues: 1,
            candidates: candidates
        )
    }

    private func makeTemporaryCorpus(
        truth suppliedTruth: FinancialTruth? = nil,
        includeScreenReader: Bool = false,
        secondTruthAtDifferentPath: Bool = false,
        splitReviews: Bool = false,
        reviewStatus: ReviewStatus = .complete,
        reviewCurrency: String? = nil
    ) throws -> TemporaryCorpus {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("documentkit-benchmark-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let standardName = "standard.pdf"
            let screenReaderName = "screen-reader.pdf"
            try FileManager.default.copyItem(
                at: benchmarkRoot.appendingPathComponent("Fixtures/Smoke/synthetic-amex-standard.pdf"),
                to: root.appendingPathComponent(standardName)
            )
            if includeScreenReader {
                try FileManager.default.copyItem(
                    at: benchmarkRoot.appendingPathComponent("Fixtures/Smoke/synthetic-amex-screen-reader.pdf"),
                    to: root.appendingPathComponent(screenReaderName)
                )
            }

            let initialTruth = suppliedTruth ?? makeTruth(
                rows: [row("2026-01-03", "Lantern Cafe", 1234)],
                criticals: [amount("new_balance", 12733)]
            )
            let canonicalName = "canonical.md"
            let canonicalData = Data(CanonicalMarkdown.render(initialTruth).utf8)
            try canonicalData.write(to: root.appendingPathComponent(canonicalName), options: .atomic)
            let truth = replacingCanonicalMarkdown(
                in: initialTruth,
                with: CanonicalMarkdownReference(
                    path: canonicalName,
                    sha256: Digest.sha256Hex(canonicalData)
                )
            )
            let truthData = try encoded(truth)
            let truthName = "truth.json"
            try truthData.write(to: root.appendingPathComponent(truthName), options: .atomic)
            let secondTruthName = "truth-copy.json"
            if secondTruthAtDifferentPath {
                try truthData.write(to: root.appendingPathComponent(secondTruthName), options: .atomic)
            }

            let standardData = try Data(contentsOf: root.appendingPathComponent(standardName))
            let standardSource = ReviewSourceVariant(
                variant: .standard,
                pdfSHA256: Digest.sha256Hex(standardData),
                pdfPageCount: 1
            )
            var sources = [standardSource]
            var screenReaderSource: ReviewSourceVariant?
            if includeScreenReader {
                let data = try Data(contentsOf: root.appendingPathComponent(screenReaderName))
                let source = ReviewSourceVariant(
                    variant: .screenReader,
                    pdfSHA256: Digest.sha256Hex(data),
                    pdfPageCount: 1
                )
                screenReaderSource = source
                sources.append(source)
            }

            let truthHash = Digest.sha256Hex(truthData)
            let completeReview = makeReview(
                truth: truth,
                truthHash: truthHash,
                canonicalMarkdownSHA256: truth.canonicalMarkdown.sha256,
                sources: sources,
                status: reviewStatus,
                semanticEquivalence: includeScreenReader ? true : nil,
                reviewCurrency: reviewCurrency
            )
            let reviewName = "review.json"
            let reviewData = try encoded(completeReview)
            try reviewData.write(to: root.appendingPathComponent(reviewName), options: .atomic)
            let fullReference = TruthReviewReference(path: reviewName, sha256: Digest.sha256Hex(reviewData))

            var standardReference = fullReference
            var screenReaderReference = fullReference
            if splitReviews, let screenReaderSource {
                let standardReview = makeReview(
                    truth: truth,
                    truthHash: truthHash,
                    canonicalMarkdownSHA256: truth.canonicalMarkdown.sha256,
                    sources: [standardSource],
                    status: .complete,
                    semanticEquivalence: nil,
                    reviewCurrency: reviewCurrency
                )
                let screenReview = makeReview(
                    truth: truth,
                    truthHash: truthHash,
                    canonicalMarkdownSHA256: truth.canonicalMarkdown.sha256,
                    sources: [screenReaderSource],
                    status: .complete,
                    semanticEquivalence: nil,
                    reviewCurrency: reviewCurrency
                )
                let standardData = try encoded(standardReview)
                let screenData = try encoded(screenReview)
                try standardData.write(to: root.appendingPathComponent("standard-review.json"), options: .atomic)
                try screenData.write(to: root.appendingPathComponent("screen-reader-review.json"), options: .atomic)
                standardReference = TruthReviewReference(path: "standard-review.json", sha256: Digest.sha256Hex(standardData))
                screenReaderReference = TruthReviewReference(path: "screen-reader-review.json", sha256: Digest.sha256Hex(screenData))
            }

            var cases = [BenchmarkCase(
                caseToken: "c01",
                statementID: truth.statementID,
                statementPeriod: truth.statementPeriod,
                variant: .standard,
                pdf: standardName,
                truth: truthName,
                pdfSHA256: standardSource.pdfSHA256,
                pdfByteCount: standardData.count,
                pdfPageCount: 1,
                truthSHA256: truthHash,
                review: standardReference
            )]
            if let screenReaderSource {
                let data = try Data(contentsOf: root.appendingPathComponent(screenReaderName))
                cases.append(BenchmarkCase(
                    caseToken: "c02",
                    statementID: truth.statementID,
                    statementPeriod: truth.statementPeriod,
                    variant: .screenReader,
                    pdf: screenReaderName,
                    truth: secondTruthAtDifferentPath ? secondTruthName : truthName,
                    pdfSHA256: screenReaderSource.pdfSHA256,
                    pdfByteCount: data.count,
                    pdfPageCount: 1,
                    truthSHA256: truthHash,
                    review: screenReaderReference
                ))
            }
            let manifest = BenchmarkManifest(
                schemaVersion: BenchmarkProfile.schemaVersion,
                profile: BenchmarkProfile.identifier,
                documentKitRevision: DocumentKit.engineRevision,
                adapterRevision: BenchmarkProfile.adapterRevision,
                adapterChecksum: AMEXAdapter.checksum,
                cases: cases
            )
            let manifestURL = root.appendingPathComponent("manifest.json")
            try encoded(manifest).write(to: manifestURL, options: .atomic)
            return TemporaryCorpus(
                root: root,
                configuration: BenchmarkConfiguration(
                    manifestURL: manifestURL,
                    rootURL: root,
                    outputURL: root.appendingPathComponent("output", isDirectory: true),
                    warmups: 0,
                    repetitions: 1,
                    sourceRevision: String(repeating: "a", count: 40)
                )
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func makeReview(
        truth: FinancialTruth,
        truthHash: String,
        canonicalMarkdownSHA256: String,
        sources: [ReviewSourceVariant],
        status: ReviewStatus,
        semanticEquivalence: Bool?,
        reviewCurrency: String?
    ) -> TruthReviewRecord {
        let authorPrompt = ReviewPrompt(
            text: "synthetic-author-prompt",
            sha256: Digest.sha256Hex(Data("synthetic-author-prompt".utf8))
        )
        let reviewerPrompt = ReviewPrompt(
            text: "synthetic-reviewer-prompt",
            sha256: Digest.sha256Hex(Data("synthetic-reviewer-prompt".utf8))
        )
        let adjudicatorPrompt = ReviewPrompt(
            text: "synthetic-adjudicator-prompt",
            sha256: Digest.sha256Hex(Data("synthetic-adjudicator-prompt".utf8))
        )
        let author = ReviewParticipant(
            kind: .model,
            model: "gpt-5.6-terra",
            reasoningEffort: "max",
            prompt: authorPrompt
        )
        let reviewer = status == .complete ? ReviewParticipant(
            kind: .model,
            model: "gpt-5.6-luna",
            reasoningEffort: "max",
            prompt: reviewerPrompt
        ) : nil
        let adjudication = status == .complete ? ReviewAdjudication(
            adjudicator: ReviewParticipant(
                kind: .model,
                model: "gpt-5.6-sol",
                reasoningEffort: "xhigh",
                prompt: adjudicatorPrompt
            ),
            adjudicationResult: ReviewAdjudicationResult(
                unresolvedTransactionDiscrepancies: 0,
                unresolvedCriticalDiscrepancies: 0
            )
        ) : nil
        return TruthReviewRecord(
            schemaVersion: BenchmarkProfile.schemaVersion,
            reviewStatus: status,
            statementID: truth.statementID,
            statementPeriod: truth.statementPeriod,
            statementCurrency: reviewCurrency ?? truth.statementCurrency,
            truthSHA256: truthHash,
            canonicalMarkdownSHA256: canonicalMarkdownSHA256,
            sources: sources,
            priorAuthor: PriorAuthorRecord(
                kind: .model,
                model: "gpt-5.6-terra",
                reasoningEffort: "max",
                exactPromptNotRetained: true
            ),
            authorReconstructionPrompt: authorPrompt,
            reviewerReconstructionPrompt: reviewerPrompt,
            author: status == .complete ? author : nil,
            reviewer: reviewer,
            authorReviewerIndependent: status == .complete,
            sourceOnlyAuthoring: true,
            sourceOnlyReview: status == .complete,
            allPagesVisuallyInspected: status == .complete,
            candidateOutputsConsulted: false,
            unresolvedTransactionDiscrepancies: status != .complete,
            unresolvedCriticalDiscrepancies: status != .complete,
            semanticEquivalence: semanticEquivalence,
            adjudication: adjudication
        )
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(value)
    }
}

private struct TemporaryCorpus {
    let root: URL
    let configuration: BenchmarkConfiguration

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
