import DocumentKit
import Foundation
import PDFKit

public struct BenchmarkConfiguration: Sendable {
    public let manifestURL: URL
    public let rootURL: URL
    public let outputURL: URL
    public let warmups: Int
    public let repetitions: Int
    /// A full sanitized source revision, when supplied by CLI or environment.
    /// Its reported evidence records whether this invocation verified it against
    /// the clean local Git HEAD. `working-tree` is not publishable evidence.
    public let sourceRevision: String?

    public init(
        manifestURL: URL,
        rootURL: URL,
        outputURL: URL,
        warmups: Int = 1,
        repetitions: Int = 5,
        sourceRevision: String? = nil
    ) {
        self.manifestURL = manifestURL
        self.rootURL = rootURL
        self.outputURL = outputURL
        self.warmups = warmups
        self.repetitions = repetitions
        self.sourceRevision = sourceRevision
    }
}

/// The executable only needs serialized redacted output. The decoded reports
/// remain target-internal so BenchmarkCore is not a public benchmark library.
public struct BenchmarkRunBundle: Sendable {
    public let detailedJSON: Data
    public let shareableJSON: Data
    public let shareableText: String
    let detailedReport: DetailedBenchmarkReport
    let shareableReport: ShareableBenchmarkReport
}

public enum BenchmarkCommandLine {
    public static let usage = "Usage: documentkit-benchmark --manifest <file> --root <directory> --output <directory> [--warmups <count>] [--repetitions <count>] [--source-revision <sha>]\n"

    public static func configuration(arguments: [String]) throws -> BenchmarkConfiguration {
        let allowed = Set(["--manifest", "--root", "--output", "--warmups", "--repetitions", "--source-revision"])
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard allowed.contains(option),
                  index + 1 < arguments.count,
                  !arguments[index + 1].hasPrefix("--"),
                  values[option] == nil
            else {
                throw BenchmarkFailure.invalidInvocation
            }
            values[option] = arguments[index + 1]
            index += 2
        }

        guard let manifest = values["--manifest"], !manifest.isEmpty,
              let root = values["--root"], !root.isEmpty,
              let output = values["--output"], !output.isEmpty
        else {
            throw BenchmarkFailure.invalidInvocation
        }
        let warmups: Int
        if let raw = values["--warmups"] {
            guard let parsed = Int(raw), parsed >= 0 else { throw BenchmarkFailure.invalidInvocation }
            warmups = parsed
        } else {
            warmups = 1
        }
        let repetitions: Int
        if let raw = values["--repetitions"] {
            guard let parsed = Int(raw), parsed > 0 else { throw BenchmarkFailure.invalidInvocation }
            repetitions = parsed
        } else {
            repetitions = 5
        }
        if let revision = values["--source-revision"], !ReproducibilityMetadata.isSafeSourceRevision(revision) {
            throw BenchmarkFailure.invalidInvocation
        }
        return BenchmarkConfiguration(
            manifestURL: URL(fileURLWithPath: manifest),
            rootURL: URL(fileURLWithPath: root),
            outputURL: URL(fileURLWithPath: output),
            warmups: warmups,
            repetitions: repetitions,
            sourceRevision: values["--source-revision"]
        )
    }
}

struct ReproducibilityMetadata: Codable, Sendable, Equatable {
    let operatingSystem: String
    let architecture: String
    let machineModel: String
    let swiftVersion: String
    let buildConfiguration: String
    let documentKitSourceRevision: String
    let documentKitSourceRevisionEvidence: String
    let documentKitEngineRevision: String
    let adapterRevision: String
    let adapterContractChecksum: String
    let inputPageCount: Int
    let inputByteCount: Int

    static func make(
        configuration: BenchmarkConfiguration,
        inputPageCount: Int,
        inputByteCount: Int
    ) throws -> ReproducibilityMetadata {
        let supplied = configuration.sourceRevision
            ?? ProcessInfo.processInfo.environment["DOCUMENTKIT_BENCHMARK_SOURCE_REVISION"]
            ?? "working-tree"
        guard isSafeSourceRevision(supplied) else { throw BenchmarkFailure.invalidInvocation }
        return ReproducibilityMetadata(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            machineModel: machineModel(),
            swiftVersion: installedSwiftVersion(),
            buildConfiguration: buildConfiguration,
            documentKitSourceRevision: supplied,
            documentKitSourceRevisionEvidence: sourceRevisionEvidence(for: supplied),
            documentKitEngineRevision: DocumentKit.engineRevision,
            adapterRevision: BenchmarkProfile.adapterRevision,
            adapterContractChecksum: AMEXAdapter.checksum,
            inputPageCount: inputPageCount,
            inputByteCount: inputByteCount
        )
    }

    static func isSafeSourceRevision(_ value: String) -> Bool {
        if value == "working-tree" { return true }
        guard value.count == 40 || value.count == 64 else { return false }
        return value.allSatisfy { character in
            character.isASCII && (("0" ... "9").contains(character) || ("a" ... "f").contains(character))
        }
    }

    static func sourceRevisionEvidence(for revision: String) -> String {
        guard revision != "working-tree" else { return "working_tree" }
        guard gitOutput(["rev-parse", "HEAD"]) == revision,
              gitOutput(["status", "--porcelain"])?.isEmpty == true
        else {
            return "asserted"
        }
        return "verified"
    }

    private static func gitOutput(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            else {
                return nil
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static var buildConfiguration: String {
        #if DOCUMENTKIT_BENCHMARK_RELEASE
        "release"
        #else
        "debug"
        #endif
    }

    private static func machineModel() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        process.arguments = ["-n", "hw.model"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let line = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                      .split(whereSeparator: { $0.isNewline }).first
            else {
                return "unknown"
            }
            let sanitized = String(line).filter { $0.isLetter || $0.isNumber || "._,-".contains($0) }
            return sanitized.isEmpty ? "unknown" : String(sanitized.prefix(80))
        } catch {
            return "unknown"
        }
    }

    private static func installedSwiftVersion() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swiftc", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let line = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                      .split(whereSeparator: { $0.isNewline }).first
            else {
                return languageModeVersion
            }
            let sanitized = String(line).filter { $0.isLetter || $0.isNumber || " ._-()".contains($0) }
            return sanitized.isEmpty ? languageModeVersion : String(sanitized.prefix(160))
        } catch {
            return languageModeVersion
        }
    }

    private static var languageModeVersion: String {
        #if compiler(>=6.2)
        "Swift 6.2 or newer"
        #else
        "Swift language mode"
        #endif
    }
}

struct CorpusSummaryReport: Codable, Sendable, Equatable {
    let totalCases: Int
    let statementPeriodClusters: Int
    let standardVariants: Int
    let screenReaderVariants: Int
    let pages: Int
    let inputBytes: Int
    let transactionRows: Int
}

struct CaseScoreReport: Codable, Sendable, Equatable {
    let rowF1: Double
    let financialTableCellF1: Double
    let contentTokenF1: Double
    let criticalAccuracy: Double
    let truePositiveRows: Int
    let falsePositiveRows: Int
    let falseNegativeRows: Int
    let correctCriticalValues: Int
    let expectedCriticalValues: Int
    let unexpectedCriticalValues: Int
    let duplicateCriticalValues: Int
    let malformedTransactionCandidates: Int
    let perfect: Bool

    init(_ score: FinancialScore) {
        rowF1 = score.row.f1
        financialTableCellF1 = score.cell.f1
        contentTokenF1 = score.contentTokenF1
        criticalAccuracy = score.criticalAccuracy
        truePositiveRows = score.row.truePositive
        falsePositiveRows = score.row.falsePositive
        falseNegativeRows = score.row.falseNegative
        correctCriticalValues = score.correctCriticalValues
        expectedCriticalValues = score.expectedCriticalValues
        unexpectedCriticalValues = score.unexpectedCriticalValues
        duplicateCriticalValues = score.duplicateCriticalValues
        malformedTransactionCandidates = score.malformedTransactionCandidates
        perfect = score.perfect
    }
}

struct CaseCandidateReport: Codable, Sendable, Equatable {
    let candidate: String
    let rawExtractionMedianMilliseconds: Double?
    let rawExtractionSamplesMilliseconds: [Double]
    let timingEligible: Bool
    let successfulTimingAttempts: Int
    let failedTimingAttempts: Int
    let rawDeterministic: Bool
    let semanticDeterministic: Bool
    let executionFailed: Bool
    let failureCodes: [String]
    let score: CaseScoreReport
}

struct CaseReport: Codable, Sendable, Equatable {
    let caseToken: String
    let statementPeriodCluster: String
    let variant: StatementVariant
    let pages: Int
    let inputBytes: Int
    let transactionRows: Int
    let criticalValues: Int
    let candidates: [CaseCandidateReport]
}

struct CandidateAggregateReport: Codable, Sendable, Equatable {
    let candidate: String
    let macroRowF1: Double
    let statementPeriodClusteredRowF1: Double
    let macroFinancialTableCellF1: Double
    let macroContentTokenF1: Double
    let macroCriticalAccuracy: Double
    let statementPeriodClusteredCriticalAccuracy: Double
    let perfectCases: Int
    let nonPerfectCases: Int
    let eligibleCases: Int
    let scoredCases: Int
    let failedCases: Int
    let totalCases: Int
    let successfulTimingAttempts: Int
    let failedTimingAttempts: Int
    let rawExtractionMedianMilliseconds: Double?
    let adoptionGatePassed: Bool
}

struct DetailedBenchmarkReport: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let profile: String
    let warmups: Int
    let repetitions: Int
    let reproducibility: ReproducibilityMetadata
    let corpus: CorpusSummaryReport
    let cases: [CaseReport]
    let candidates: [CandidateAggregateReport]
}

struct ShareableBenchmarkReport: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let profile: String
    let warmups: Int
    let repetitions: Int
    let reproducibility: ReproducibilityMetadata
    let corpus: CorpusSummaryReport
    let candidates: [CandidateAggregateReport]
}

public enum BenchmarkRunner {
    public static func run(_ configuration: BenchmarkConfiguration) async throws -> BenchmarkRunBundle {
        guard configuration.warmups >= 0, configuration.repetitions > 0 else {
            throw BenchmarkFailure.invalidInvocation
        }

        let prepared = try CorpusPreflight.prepare(configuration)
        let corpus = CorpusSummaryReport(
            totalCases: prepared.cases.count,
            statementPeriodClusters: Set(prepared.cases.map(\.periodCluster)).count,
            standardVariants: prepared.cases.count(where: { $0.specification.variant == .standard }),
            screenReaderVariants: prepared.cases.count(where: { $0.specification.variant == .screenReader }),
            pages: prepared.cases.reduce(0) { $0 + $1.specification.pdfPageCount },
            inputBytes: prepared.cases.reduce(0) { $0 + $1.specification.pdfByteCount },
            transactionRows: prepared.cases.reduce(0) { $0 + $1.truth.transactions.count }
        )
        let reproducibility = try ReproducibilityMetadata.make(
            configuration: configuration,
            inputPageCount: corpus.pages,
            inputByteCount: corpus.inputBytes
        )

        var internalReports: [InternalCaseReport] = []
        var forbiddenValues = prepared.privacyForbiddenValues
        for (caseIndex, item) in prepared.cases.enumerated() {
            let report = await runCase(
                item,
                caseIndex: caseIndex,
                warmups: configuration.warmups,
                repetitions: configuration.repetitions
            )
            internalReports.append(report)
            forbiddenValues.append(contentsOf: report.rawSurfaces)
        }

        let caseReports = internalReports.map(\.report)
        let aggregates = aggregate(caseReports)
        let detailed = DetailedBenchmarkReport(
            schemaVersion: BenchmarkProfile.schemaVersion,
            profile: BenchmarkProfile.identifier,
            warmups: configuration.warmups,
            repetitions: configuration.repetitions,
            reproducibility: reproducibility,
            corpus: corpus,
            cases: caseReports,
            candidates: aggregates
        )
        let shareable = ShareableBenchmarkReport(
            schemaVersion: BenchmarkProfile.schemaVersion,
            profile: BenchmarkProfile.identifier,
            warmups: configuration.warmups,
            repetitions: configuration.repetitions,
            reproducibility: reproducibility,
            corpus: corpus,
            candidates: aggregates
        )
        let detailedJSON = try encode(detailed)
        let shareableJSON = try encode(shareable)
        let shareableText = makeShareableText(
            warmups: configuration.warmups,
            repetitions: configuration.repetitions,
            reproducibility: reproducibility,
            corpus: corpus,
            candidates: aggregates
        )
        try ReportPrivacy.validate(
            surfaces: [detailedJSON, shareableJSON, Data(shareableText.utf8)],
            forbiddenValues: forbiddenValues
        )
        return BenchmarkRunBundle(
            detailedJSON: detailedJSON,
            shareableJSON: shareableJSON,
            shareableText: shareableText,
            detailedReport: detailed,
            shareableReport: shareable
        )
    }

    public static func write(_ bundle: BenchmarkRunBundle, to outputURL: URL) throws {
        do {
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            try bundle.detailedJSON.write(to: outputURL.appendingPathComponent("detailed.json"), options: .atomic)
            try bundle.shareableJSON.write(to: outputURL.appendingPathComponent("shareable.json"), options: .atomic)
            try Data(bundle.shareableText.utf8).write(
                to: outputURL.appendingPathComponent("shareable.txt"),
                options: .atomic
            )
        } catch {
            throw BenchmarkFailure.reportWritingFailed
        }
    }

    private static func runCase(
        _ item: PreparedCase,
        caseIndex: Int,
        warmups: Int,
        repetitions: Int
    ) async -> InternalCaseReport {
        for warmup in 0 ..< warmups {
            for candidate in orderedCandidates(caseIndex: caseIndex, repetition: warmup) {
                _ = await attempt(candidate: candidate, data: item.pdfData)
            }
        }

        var attempts: [Candidate: [MeasuredAttempt]] = Dictionary(
            uniqueKeysWithValues: Candidate.allCases.map { ($0, []) }
        )
        for repetition in 0 ..< repetitions {
            for candidate in orderedCandidates(caseIndex: caseIndex, repetition: repetition) {
                attempts[candidate, default: []].append(await attempt(candidate: candidate, data: item.pdfData))
            }
        }

        var candidateReports: [CaseCandidateReport] = []
        var rawSurfaces: [String] = []
        for candidate in Candidate.allCases {
            let result = makeCaseCandidateReport(
                candidate: candidate,
                attempts: attempts[candidate, default: []],
                truth: item.truth
            )
            candidateReports.append(result.report)
            rawSurfaces.append(contentsOf: result.rawSurfaces)
        }
        return InternalCaseReport(
            report: CaseReport(
                caseToken: item.specification.caseToken,
                statementPeriodCluster: item.periodCluster,
                variant: item.specification.variant,
                pages: item.specification.pdfPageCount,
                inputBytes: item.specification.pdfByteCount,
                transactionRows: item.truth.transactions.count,
                criticalValues: item.truth.criticalValues.count,
                candidates: candidateReports
            ),
            rawSurfaces: rawSurfaces
        )
    }

    private static func orderedCandidates(caseIndex: Int, repetition: Int) -> [Candidate] {
        (caseIndex + repetition).isMultiple(of: 2)
            ? Candidate.allCases
            : Array(Candidate.allCases.reversed())
    }

    private static func attempt(candidate: Candidate, data: Data) async -> MeasuredAttempt {
        let clock = ContinuousClock()
        let start = clock.now
        let rawOutcome: CandidateOutcome<String>
        do {
            let raw = try await candidate.extract(data: data)
            rawOutcome = raw.isEmpty ? .failure("raw_empty") : .success(raw)
        } catch {
            rawOutcome = .failure(candidate.errorCode(for: error))
        }
        // The monotonic interval intentionally ends before adapter work, truth
        // scoring, report work, or file I/O. PDFKit construction is in extract.
        let elapsedMilliseconds = milliseconds(from: start.duration(to: clock.now))

        let semanticOutcome: CandidateOutcome<FinancialExtraction>
        switch rawOutcome {
        case let .success(raw):
            do {
                semanticOutcome = .success(try AMEXAdapter.extract(rawSurface: raw))
            } catch let error as AdapterFailure {
                semanticOutcome = .failure(error.code)
            } catch {
                semanticOutcome = .failure("adapter_failed")
            }
        case let .failure(code):
            semanticOutcome = .failure(code)
        }
        return MeasuredAttempt(
            rawOutcome: rawOutcome,
            semanticOutcome: semanticOutcome,
            elapsedMilliseconds: elapsedMilliseconds
        )
    }

    static func makeCaseCandidateReport(
        candidate: Candidate,
        attempts: [MeasuredAttempt],
        truth: FinancialTruth
    ) -> InternalCandidateReport {
        let rawOutcomes = attempts.map(\.rawOutcome)
        let semanticOutcomes = attempts.map(\.semanticOutcome)
        let rawDeterministic = Determinism.rawIsDeterministic(rawOutcomes)
        let semanticDeterministic = Determinism.semanticIsDeterministic(semanticOutcomes)
        let rawSurfaces = rawOutcomes.compactMap { outcome -> String? in
            guard case let .success(raw) = outcome else { return nil }
            return raw
        }
        let semanticSuccesses = semanticOutcomes.compactMap { outcome -> FinancialExtraction? in
            guard case let .success(extraction) = outcome else { return nil }
            return extraction
        }
        var failureCodes = Set<String>()
        for outcome in rawOutcomes {
            if case let .failure(code) = outcome { failureCodes.insert(code) }
        }
        for outcome in semanticOutcomes {
            if case let .failure(code) = outcome { failureCodes.insert(code) }
        }
        if !rawDeterministic { failureCodes.insert("raw_nondeterministic") }
        if !semanticDeterministic { failureCodes.insert("semantic_nondeterministic") }

        let executionFailed = !failureCodes.isEmpty
        let score: FinancialScore
        if !executionFailed, let extraction = semanticSuccesses.first {
            score = FinancialScorer.score(
                truth: truth,
                observed: extraction
            )
        } else {
            score = FinancialScore.failed(
                expectedRows: truth.transactions.count,
                expectedCriticalValues: truth.criticalValues.count
            )
        }
        if score.row.f1 < 1 { failureCodes.insert("row_mismatch") }
        if score.criticalAccuracy < 1 { failureCodes.insert("critical_value_mismatch") }
        if score.unexpectedCriticalValues > 0 { failureCodes.insert("unexpected_critical_values") }
        if score.duplicateCriticalValues > 0 { failureCodes.insert("duplicate_critical_values") }
        if !score.perfect { failureCodes.insert("not_perfect") }

        let successfulTimingAttempts = attempts.count(where: { attempt in
            if case .success = attempt.rawOutcome { return true }
            return false
        })
        let failedTimingAttempts = attempts.count - successfulTimingAttempts
        let timingEligible = !attempts.isEmpty
            && failedTimingAttempts == 0
            && rawDeterministic
        let timingSamples = timingEligible ? attempts.map(\.elapsedMilliseconds) : []

        return InternalCandidateReport(
            report: CaseCandidateReport(
                candidate: candidate.label,
                rawExtractionMedianMilliseconds: timingEligible ? median(timingSamples) : nil,
                rawExtractionSamplesMilliseconds: timingSamples,
                timingEligible: timingEligible,
                successfulTimingAttempts: successfulTimingAttempts,
                failedTimingAttempts: failedTimingAttempts,
                rawDeterministic: rawDeterministic,
                semanticDeterministic: semanticDeterministic,
                executionFailed: executionFailed,
                failureCodes: failureCodes.sorted(),
                score: CaseScoreReport(score)
            ),
            rawSurfaces: rawSurfaces
        )
    }

    static func aggregate(_ cases: [CaseReport]) -> [CandidateAggregateReport] {
        Candidate.allCases.map { candidate in
            let caseResults = cases.map { item in
                (item, item.candidates.first(where: { $0.candidate == candidate.label })
                    ?? missingCandidateReport(for: item, candidate: candidate))
            }
            let rowF1s = caseResults.map { $0.1.score.rowF1 }
            let cellF1s = caseResults.map { $0.1.score.financialTableCellF1 }
            let contentF1s = caseResults.map { $0.1.score.contentTokenF1 }
            let criticalAccuracies = caseResults.map { $0.1.score.criticalAccuracy }
            let clusters = Dictionary(grouping: caseResults, by: { $0.0.statementPeriodCluster })
            let clusteredRows = clusters.values.map { average($0.map { $0.1.score.rowF1 }) }
            let clusteredCritical = clusters.values.map { average($0.map { $0.1.score.criticalAccuracy }) }
            let timingSamples = caseResults.flatMap { result in
                result.1.timingEligible ? result.1.rawExtractionSamplesMilliseconds : []
            }
            let failedCases = caseResults.count(where: { $0.1.executionFailed })
            let perfectCases = caseResults.count(where: { $0.1.score.perfect && !$0.1.executionFailed })
            let totalCases = cases.count
            return CandidateAggregateReport(
                candidate: candidate.label,
                macroRowF1: average(rowF1s),
                statementPeriodClusteredRowF1: average(clusteredRows),
                macroFinancialTableCellF1: average(cellF1s),
                macroContentTokenF1: average(contentF1s),
                macroCriticalAccuracy: average(criticalAccuracies),
                statementPeriodClusteredCriticalAccuracy: average(clusteredCritical),
                perfectCases: perfectCases,
                nonPerfectCases: totalCases - perfectCases,
                eligibleCases: caseResults.count(where: { $0.1.timingEligible }),
                scoredCases: totalCases,
                failedCases: failedCases,
                totalCases: totalCases,
                successfulTimingAttempts: caseResults.reduce(0) { $0 + $1.1.successfulTimingAttempts },
                failedTimingAttempts: caseResults.reduce(0) { $0 + $1.1.failedTimingAttempts },
                rawExtractionMedianMilliseconds: median(timingSamples),
                adoptionGatePassed: totalCases > 0
                    && rowF1s.allSatisfy { $0 == 1 }
                    && criticalAccuracies.allSatisfy { $0 == 1 }
                    && perfectCases == totalCases
                    && failedCases == 0
            )
        }
    }

    private static func missingCandidateReport(for item: CaseReport, candidate: Candidate) -> CaseCandidateReport {
        CaseCandidateReport(
            candidate: candidate.label,
            rawExtractionMedianMilliseconds: nil,
            rawExtractionSamplesMilliseconds: [],
            timingEligible: false,
            successfulTimingAttempts: 0,
            failedTimingAttempts: 0,
            rawDeterministic: false,
            semanticDeterministic: false,
            executionFailed: true,
            failureCodes: ["candidate_record_missing"],
            score: CaseScoreReport(FinancialScore.failed(
                expectedRows: item.transactionRows,
                expectedCriticalValues: item.criticalValues
            ))
        )
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.keyEncodingStrategy = .convertToSnakeCase
            return try encoder.encode(value)
        } catch {
            throw BenchmarkFailure.internalRunnerFailure
        }
    }

    private static func makeShareableText(
        warmups: Int,
        repetitions: Int,
        reproducibility: ReproducibilityMetadata,
        corpus: CorpusSummaryReport,
        candidates: [CandidateAggregateReport]
    ) -> String {
        var lines = [
            "DocumentKit AMEX transaction-integrity benchmark",
            "Methodology: exact financial row multiset and critical-value scoring; raw extraction timing only.",
            "Reproducibility: warmups=\(warmups) repetitions=\(repetitions) os=\(reproducibility.operatingSystem) architecture=\(reproducibility.architecture) machine=\(reproducibility.machineModel) swift=\(reproducibility.swiftVersion) build=\(reproducibility.buildConfiguration) documentkit-source-revision=\(reproducibility.documentKitSourceRevision) documentkit-source-revision-evidence=\(reproducibility.documentKitSourceRevisionEvidence) documentkit-engine-revision=\(reproducibility.documentKitEngineRevision) adapter-revision=\(reproducibility.adapterRevision) adapter-contract-checksum=\(reproducibility.adapterContractChecksum) input-pages=\(reproducibility.inputPageCount) input-bytes=\(reproducibility.inputByteCount)",
            "Corpus: cases=\(corpus.totalCases) statement-period-clusters=\(corpus.statementPeriodClusters) variants=\(corpus.standardVariants + corpus.screenReaderVariants) pages=\(corpus.pages) input-bytes=\(corpus.inputBytes) transaction-rows=\(corpus.transactionRows)",
        ]
        for candidate in candidates {
            let median = candidate.rawExtractionMedianMilliseconds.map { String(format: "%.3f", $0) } ?? "unavailable"
            lines.append("Candidate: \(candidate.candidate)")
            lines.append("  Row F1: \(String(format: "%.6f", candidate.macroRowF1))")
            lines.append("  Financial table-cell F1: \(String(format: "%.6f", candidate.macroFinancialTableCellF1))")
            lines.append("  Content token F1: \(String(format: "%.6f", candidate.macroContentTokenF1))")
            lines.append("  Critical accuracy: \(String(format: "%.6f", candidate.macroCriticalAccuracy))")
            lines.append("  Perfect cases: \(candidate.perfectCases)/\(candidate.totalCases)")
            lines.append("  Raw extraction median (ms): \(median)")
            lines.append("  Timing attempts: successful=\(candidate.successfulTimingAttempts) failed=\(candidate.failedTimingAttempts)")
            lines.append("  Execution failures: \(candidate.failedCases)")
            lines.append("  Adoption gate: \(candidate.adoptionGatePassed ? "passed" : "not-passed")")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum ReportPrivacy {
    static func validate(surfaces: [Data], forbiddenValues: [String]) throws {
        let values = Set(forbiddenValues
            .filter { !$0.isEmpty && !isPureNumeric($0) }
            .map { $0.lowercased() })
        for surface in surfaces {
            guard let text = String(data: surface, encoding: .utf8) else {
                throw BenchmarkFailure.privacyGuardFailed
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                try validateJSONKeys(surface)
            }
            let normalized = text.lowercased()
            if values.contains(where: { containsForbiddenValue($0, in: normalized) }) {
                throw BenchmarkFailure.privacyGuardFailed
            }
        }
    }

    /// Output DTOs are deliberately separate from raw candidates, truth,
    /// manifests, review sidecars, and paths. The allowlist catches accidental
    /// widening before a private value reaches disk or stdout.
    static func validateJSONKeys(_ data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BenchmarkFailure.privacyGuardFailed
        }
        try validateKeys(in: object)
    }

    private static func validateKeys(in object: Any) throws {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                guard allowedKeys.contains(key) else { throw BenchmarkFailure.privacyGuardFailed }
                try validateKeys(in: value)
            }
        } else if let array = object as? [Any] {
            for value in array { try validateKeys(in: value) }
        }
    }

    private static let allowedKeys: Set<String> = [
        "schema_version", "profile", "warmups", "repetitions", "reproducibility", "corpus", "cases", "candidates",
        "operating_system", "architecture", "machine_model", "swift_version", "build_configuration", "document_kit_source_revision", "document_kit_source_revision_evidence",
        "document_kit_engine_revision", "adapter_revision", "adapter_contract_checksum", "input_page_count", "input_byte_count",
        "total_cases", "statement_period_clusters", "standard_variants", "screen_reader_variants", "pages", "input_bytes",
        "transaction_rows", "case_token", "statement_period_cluster", "variant", "candidate", "critical_values",
        "raw_extraction_median_milliseconds", "raw_extraction_samples_milliseconds", "timing_eligible",
        "successful_timing_attempts", "failed_timing_attempts", "raw_deterministic", "semantic_deterministic",
        "execution_failed", "failure_codes", "score", "row_f1", "financial_table_cell_f1", "content_token_f1",
        "critical_accuracy", "true_positive_rows", "false_positive_rows", "false_negative_rows", "correct_critical_values",
        "expected_critical_values", "unexpected_critical_values", "duplicate_critical_values", "malformed_transaction_candidates",
        "perfect", "macro_row_f1", "statement_period_clustered_row_f1", "macro_financial_table_cell_f1",
        "macro_content_token_f1", "macro_critical_accuracy", "statement_period_clustered_critical_accuracy",
        "perfect_cases", "non_perfect_cases", "eligible_cases", "scored_cases", "failed_cases", "total_cases",
        "adoption_gate_passed",
    ]

    private static func isPureNumeric(_ value: String) -> Bool {
        let unsigned = value.hasPrefix("-") ? value.dropFirst() : Substring(value)
        return !unsigned.isEmpty && unsigned.allSatisfy(\.isNumber)
    }

    private static func containsForbiddenValue(_ value: String, in text: String) -> Bool {
        guard isShortASCIIAlphanumeric(value) else { return text.contains(value) }

        var searchRange = text.startIndex ..< text.endIndex
        while let range = text.range(of: value, range: searchRange) {
            let startsAtBoundary = range.lowerBound == text.startIndex
                || !isTokenCharacter(text[text.index(before: range.lowerBound)])
            let endsAtBoundary = range.upperBound == text.endIndex
                || !isTokenCharacter(text[range.upperBound])
            if startsAtBoundary && endsAtBoundary { return true }
            guard range.upperBound < text.endIndex else { return false }
            searchRange = range.upperBound ..< text.endIndex
        }
        return false
    }

    private static func isShortASCIIAlphanumeric(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 3 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48 ... 57, 97 ... 122:
                true
            default:
                false
            }
        }
    }

    private static func isTokenCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }
}

enum Candidate: CaseIterable, Hashable {
    case documentKitMarkdown
    case pdfKitDocumentString

    var label: String {
        switch self {
        case .documentKitMarkdown: "DocumentKit Markdown + AMEX adapter"
        case .pdfKitDocumentString: "PDFKit PDFDocument.string + AMEX adapter"
        }
    }

    func extract(data: Data) async throws -> String {
        switch self {
        case .documentKitMarkdown:
            return try await DocumentKit.extract(data).markdown
        case .pdfKitDocumentString:
            // Construction belongs inside the timed raw extraction surface.
            guard let value = PDFDocument(data: data)?.string else {
                throw CandidateExecutionError.pdfKitDocumentUnavailable
            }
            return value
        }
    }

    func errorCode(for error: Error) -> String {
        if let error = error as? CandidateExecutionError { return error.code }
        if let error = error as? DocumentKitError {
            switch error {
            case .emptyInput: return "documentkit_empty_input"
            case .inputTooLarge: return "documentkit_input_too_large"
            case .encryptedPDF: return "documentkit_encrypted_pdf"
            case .invalidPageSelection: return "documentkit_invalid_page_selection"
            case .pageOutOfRange: return "documentkit_page_out_of_range"
            case .invalidPDF: return "documentkit_invalid_pdf"
            case .noExtractableText: return "documentkit_no_extractable_text"
            case .engineFailure: return "documentkit_engine_failure"
            }
        }
        return self == .documentKitMarkdown ? "documentkit_extraction_failed" : "pdfkit_extraction_failed"
    }
}

private enum CandidateExecutionError: Error {
    case pdfKitDocumentUnavailable

    var code: String {
        switch self {
        case .pdfKitDocumentUnavailable: "pdfkit_document_unavailable"
        }
    }
}

struct MeasuredAttempt {
    let rawOutcome: CandidateOutcome<String>
    let semanticOutcome: CandidateOutcome<FinancialExtraction>
    let elapsedMilliseconds: Double
}

struct InternalCandidateReport {
    let report: CaseCandidateReport
    let rawSurfaces: [String]
}

fileprivate struct InternalCaseReport {
    let report: CaseReport
    let rawSurfaces: [String]
}

fileprivate struct PreparedCase {
    let specification: BenchmarkCase
    let pdfData: Data
    let truth: FinancialTruth
    let periodCluster: String
}

fileprivate struct PreparedCorpus {
    let cases: [PreparedCase]
    let privacyForbiddenValues: [String]
}

enum CorpusPreflight {
    /// Narrow test seam. It performs the same fail-closed validation as a run
    /// without exposing prepared PDFs, truth, raw source data, or private paths.
    static func validate(configuration: BenchmarkConfiguration) throws {
        _ = try prepare(configuration)
    }

    fileprivate static func prepare(_ configuration: BenchmarkConfiguration) throws -> PreparedCorpus {
        let manifest: BenchmarkManifest
        do {
            let data = try Data(contentsOf: configuration.manifestURL)
            let decoder = JSONDecoder()
            manifest = try decoder.decode(BenchmarkManifest.self, from: data)
        } catch {
            throw BenchmarkFailure.invalidManifest
        }
        try validateManifest(manifest)

        var prepared: [PreparedCase] = []
        var canonicalMarkdownHashes: [TruthGroupKey: String] = [:]
        var truthCurrencies: [TruthGroupKey: String] = [:]
        var forbiddenValues = protectedFileValues(for: configuration.manifestURL)
            + [configuration.rootURL.path, configuration.outputURL.path]
        for specification in manifest.cases {
            let pdfURL = try resolve(specification.pdf, under: configuration.rootURL)
            let truthURL = try resolve(specification.truth, under: configuration.rootURL)
            let reviewURL = try resolve(specification.review.path, under: configuration.rootURL)
            let pdfData: Data
            let truthData: Data
            do {
                pdfData = try Data(contentsOf: pdfURL)
                truthData = try Data(contentsOf: truthURL)
            } catch {
                throw BenchmarkFailure.inputValidationFailed
            }
            guard Digest.sha256Hex(pdfData) == specification.pdfSHA256,
                  pdfData.count == specification.pdfByteCount,
                  let document = PDFDocument(data: pdfData),
                  document.pageCount == specification.pdfPageCount,
                  Digest.sha256Hex(truthData) == specification.truthSHA256
            else {
                throw BenchmarkFailure.inputValidationFailed
            }
            let truth: FinancialTruth
            do {
                let decoder = JSONDecoder()
                truth = try decoder.decode(FinancialTruth.self, from: truthData)
            } catch {
                throw BenchmarkFailure.invalidTruth
            }
            try validateTruth(truth, for: specification)
            let canonicalURL = try resolve(truth.canonicalMarkdown.path, under: configuration.rootURL)
            let canonicalData: Data
            do {
                canonicalData = try Data(contentsOf: canonicalURL)
            } catch {
                throw BenchmarkFailure.invalidTruth
            }
            guard Digest.sha256Hex(canonicalData) == truth.canonicalMarkdown.sha256,
                  canonicalData == Data(CanonicalMarkdown.render(truth).utf8)
            else {
                throw BenchmarkFailure.invalidTruth
            }
            let truthKey = TruthGroupKey(
                statementID: specification.statementID,
                statementPeriod: specification.statementPeriod,
                truthSHA256: specification.truthSHA256
            )
            if let existing = canonicalMarkdownHashes[truthKey], existing != truth.canonicalMarkdown.sha256 {
                throw BenchmarkFailure.invalidTruth
            }
            canonicalMarkdownHashes[truthKey] = truth.canonicalMarkdown.sha256
            if let existing = truthCurrencies[truthKey], existing != truth.statementCurrency {
                throw BenchmarkFailure.invalidTruth
            }
            truthCurrencies[truthKey] = truth.statementCurrency
            prepared.append(
                PreparedCase(
                    specification: specification,
                    pdfData: pdfData,
                    truth: truth,
                    periodCluster: "p\(String(format: "%02d", periodIndex(specification.statementPeriod, in: manifest.cases)))"
                )
            )
            forbiddenValues += protectedFileValues(for: pdfURL)
                + protectedFileValues(for: truthURL)
                + protectedFileValues(for: reviewURL)
                + protectedFileValues(for: canonicalURL)
            forbiddenValues += [
                specification.statementID,
                specification.statementPeriod,
                specification.pdf,
                specification.truth,
                specification.pdfSHA256,
                specification.truthSHA256,
                specification.review.path,
                specification.review.sha256,
                truth.canonicalMarkdown.path,
                truth.canonicalMarkdown.sha256,
            ]
            forbiddenValues += sensitiveValues(in: truth)
        }
        try validateReviewRecords(
            cases: manifest.cases,
            rootURL: configuration.rootURL,
            canonicalMarkdownHashes: canonicalMarkdownHashes,
            truthCurrencies: truthCurrencies
        )
        return PreparedCorpus(cases: prepared, privacyForbiddenValues: forbiddenValues)
    }

    private static func validateManifest(_ manifest: BenchmarkManifest) throws {
        guard manifest.schemaVersion == BenchmarkProfile.schemaVersion,
              manifest.profile == BenchmarkProfile.identifier,
              manifest.documentKitRevision == DocumentKit.engineRevision,
              manifest.adapterRevision == BenchmarkProfile.adapterRevision,
              manifest.adapterChecksum == AMEXAdapter.checksum,
              !manifest.cases.isEmpty,
              Set(manifest.cases.map(\.caseToken)).count == manifest.cases.count,
              manifest.cases.allSatisfy({ isOpaqueCaseToken($0.caseToken) })
        else {
            throw BenchmarkFailure.invalidManifest
        }
        for item in manifest.cases {
            guard !item.statementID.isEmpty,
                  isStatementPeriod(item.statementPeriod),
                  isSafeRelativePath(item.pdf),
                  isSafeRelativePath(item.truth),
                  isSafeRelativePath(item.review.path),
                  isLowercaseSHA256(item.pdfSHA256),
                  isLowercaseSHA256(item.truthSHA256),
                  isLowercaseSHA256(item.review.sha256),
                  item.pdfByteCount > 0,
                  item.pdfPageCount > 0
            else { throw BenchmarkFailure.invalidManifest }
        }
    }

    private static func validateTruth(_ truth: FinancialTruth, for specification: BenchmarkCase) throws {
        guard truth.schemaVersion == BenchmarkProfile.schemaVersion,
              truth.statementID == specification.statementID,
              truth.statementPeriod == specification.statementPeriod,
              isStatementPeriod(truth.statementPeriod),
              isCurrency(truth.statementCurrency),
              isSafeRelativePath(truth.canonicalMarkdown.path),
              isLowercaseSHA256(truth.canonicalMarkdown.sha256),
              CanonicalMarkdown.isRepresentable(truth),
              Set(truth.criticalValues.map(\.id)).count == truth.criticalValues.count
        else {
            throw BenchmarkFailure.invalidTruth
        }
        for row in truth.transactions {
            guard isISODate(row.date),
                  !FinancialNormalizer.normalizeMerchant(row.merchant).isEmpty,
                  let pageIndex = row.pageIndex,
                  pageIndex >= 0,
                  pageIndex < specification.pdfPageCount
            else { throw BenchmarkFailure.invalidTruth }
        }
        for critical in truth.criticalValues {
            guard AMEXAdapter.criticalValueKinds[critical.id] == critical.kind else {
                throw BenchmarkFailure.invalidTruth
            }
            switch critical.kind {
            case .amount:
                guard critical.signedAmountMinor != nil,
                      critical.date == nil,
                      critical.currency == truth.statementCurrency
                else { throw BenchmarkFailure.invalidTruth }
            case .date:
                guard critical.signedAmountMinor == nil,
                      critical.currency == nil,
                      critical.date.map(isISODate) == true
                else { throw BenchmarkFailure.invalidTruth }
            }
        }
    }

    private static func validateReviewRecords(
        cases: [BenchmarkCase],
        rootURL: URL,
        canonicalMarkdownHashes: [TruthGroupKey: String],
        truthCurrencies: [TruthGroupKey: String]
    ) throws {
        let groups = Dictionary(grouping: cases) {
            TruthGroupKey(statementID: $0.statementID, statementPeriod: $0.statementPeriod, truthSHA256: $0.truthSHA256)
        }
        for (key, group) in groups {
            guard let reference = group.first?.review,
                  group.allSatisfy({ $0.review == reference }),
                  isSafeRelativePath(reference.path),
                  isLowercaseSHA256(reference.sha256)
            else {
                throw BenchmarkFailure.invalidEquivalenceReview
            }
            let reviewData: Data
            do {
                reviewData = try Data(contentsOf: resolve(reference.path, under: rootURL))
            } catch {
                throw BenchmarkFailure.invalidEquivalenceReview
            }
            guard Digest.sha256Hex(reviewData) == reference.sha256 else {
                throw BenchmarkFailure.invalidEquivalenceReview
            }
            let review: TruthReviewRecord
            do {
                let decoder = JSONDecoder()
                review = try decoder.decode(TruthReviewRecord.self, from: reviewData)
            } catch {
                throw BenchmarkFailure.invalidEquivalenceReview
            }
            try validate(
                review: review,
                group: group,
                key: key,
                canonicalMarkdownSHA256: canonicalMarkdownHashes[key],
                truthCurrency: truthCurrencies[key]
            )
        }
    }

    private static func validate(
        review: TruthReviewRecord,
        group: [BenchmarkCase],
        key: TruthGroupKey,
        canonicalMarkdownSHA256: String?,
        truthCurrency: String?
    ) throws {
        guard review.schemaVersion == BenchmarkProfile.schemaVersion,
              review.reviewStatus == .complete,
              review.statementID == key.statementID,
              review.statementPeriod == key.statementPeriod,
              review.statementCurrency == truthCurrency,
              isCurrency(review.statementCurrency),
              review.truthSHA256 == key.truthSHA256,
              isLowercaseSHA256(review.truthSHA256),
              review.canonicalMarkdownSHA256 == canonicalMarkdownSHA256,
              isLowercaseSHA256(review.canonicalMarkdownSHA256),
              valid(prompt: review.authorReconstructionPrompt),
              valid(prompt: review.reviewerReconstructionPrompt),
              review.author.map(valid(participant:)) == true,
              review.reviewer.map(valid(participant:)) == true,
              review.adjudication.map(valid(adjudication:)) == true,
              review.author != review.reviewer,
              review.adjudication?.adjudicator != review.author,
              review.adjudication?.adjudicator != review.reviewer,
              review.author?.prompt == review.authorReconstructionPrompt,
              review.reviewer?.prompt == review.reviewerReconstructionPrompt,
              review.priorAuthor.map(valid(priorAuthor:)) ?? true,
              review.authorReviewerIndependent,
              review.sourceOnlyAuthoring,
              review.sourceOnlyReview,
              review.allPagesVisuallyInspected,
              !review.candidateOutputsConsulted,
              !review.unresolvedTransactionDiscrepancies,
              !review.unresolvedCriticalDiscrepancies
        else {
            throw BenchmarkFailure.invalidEquivalenceReview
        }

        var expectedByVariant: [StatementVariant: (sha256: String, pageCount: Int)] = [:]
        for item in group {
            guard expectedByVariant[item.variant] == nil else {
                throw BenchmarkFailure.invalidEquivalenceReview
            }
            expectedByVariant[item.variant] = (item.pdfSHA256, item.pdfPageCount)
        }
        var reviewByVariant: [StatementVariant: ReviewSourceVariant] = [:]
        for source in review.sources {
            guard reviewByVariant[source.variant] == nil,
                  isLowercaseSHA256(source.pdfSHA256),
                  source.pdfPageCount > 0
            else {
                throw BenchmarkFailure.invalidEquivalenceReview
            }
            reviewByVariant[source.variant] = source
        }
        guard review.sources.count == reviewByVariant.count,
              reviewByVariant.count == expectedByVariant.count
        else {
            throw BenchmarkFailure.invalidEquivalenceReview
        }
        for (variant, expected) in expectedByVariant {
            guard let actual = reviewByVariant[variant],
                  actual.pdfSHA256 == expected.sha256,
                  actual.pdfPageCount == expected.pageCount
            else {
                throw BenchmarkFailure.invalidEquivalenceReview
            }
        }
        if group.count > 1 {
            guard review.semanticEquivalence == true else {
                throw BenchmarkFailure.invalidEquivalenceReview
            }
        } else {
            guard review.semanticEquivalence == nil else {
                throw BenchmarkFailure.invalidEquivalenceReview
            }
        }
    }

    private static func valid(prompt: ReviewPrompt) -> Bool {
        !prompt.text.isEmpty
            && isLowercaseSHA256(prompt.sha256)
            && Digest.sha256Hex(Data(prompt.text.utf8)) == prompt.sha256
    }

    private static func valid(participant: ReviewParticipant) -> Bool {
        guard valid(prompt: participant.prompt) else { return false }
        switch participant.kind {
        case .human:
            return participant.model == nil && participant.reasoningEffort == nil
        case .model:
            return participant.model?.isEmpty == false && participant.reasoningEffort?.isEmpty == false
        }
    }

    private static func valid(adjudication: ReviewAdjudication) -> Bool {
        valid(participant: adjudication.adjudicator)
            && adjudication.adjudicationResult.unresolvedTransactionDiscrepancies == 0
            && adjudication.adjudicationResult.unresolvedCriticalDiscrepancies == 0
    }

    private static func valid(priorAuthor: PriorAuthorRecord) -> Bool {
        guard priorAuthor.exactPromptNotRetained else { return false }
        switch priorAuthor.kind {
        case .human:
            return priorAuthor.model == nil && priorAuthor.reasoningEffort == nil
        case .model:
            return priorAuthor.model?.isEmpty == false && priorAuthor.reasoningEffort?.isEmpty == false
        }
    }

    private static func resolve(_ path: String, under rootURL: URL) throws -> URL {
        guard isSafeRelativePath(path) else { throw BenchmarkFailure.invalidManifest }
        return rootURL.appendingPathComponent(path)
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && path.split(separator: "/").allSatisfy { $0 != ".." && $0 != "." }
    }

    private static func isOpaqueCaseToken(_ token: String) -> Bool {
        token.count >= 2 && token.first == "c" && token.dropFirst().allSatisfy(\.isNumber)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            character.isASCII && (character.isNumber || (character >= "a" && character <= "f"))
        }
    }

    private static func isStatementPeriod(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1])
        else { return false }
        return year >= 1900 && year <= 2999 && month >= 1 && month <= 12
    }

    private static func isCurrency(_ value: String) -> Bool {
        value.count == 3 && value.allSatisfy(\.isASCII) && value.allSatisfy(\.isLetter) && value == value.uppercased()
    }

    private static func isISODate(_ value: String) -> Bool {
        let pieces = value.split(separator: "-")
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]),
              year >= 1900, year <= 2999, month >= 1, month <= 12, day >= 1
        else { return false }
        let days = [31, year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) ? 29 : 28,
                    31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= days[month - 1]
    }

    private static func periodIndex(_ period: String, in cases: [BenchmarkCase]) -> Int {
        let periods = Array(Set(cases.map(\.statementPeriod))).sorted()
        return (periods.firstIndex(of: period) ?? 0) + 1
    }

    private static func protectedFileValues(for url: URL) -> [String] {
        [url.path, url.lastPathComponent]
    }

    private static func sensitiveValues(in truth: FinancialTruth) -> [String] {
        var values = [truth.statementID, truth.statementPeriod, truth.statementCurrency]
        for row in truth.transactions {
            values += [row.date, row.merchant]
        }
        for critical in truth.criticalValues {
            values.append(critical.id)
            if let date = critical.date { values.append(date) }
            if let currency = critical.currency { values.append(currency) }
        }
        return values
    }
}

private struct TruthGroupKey: Hashable {
    let statementID: String
    let statementPeriod: String
    let truthSHA256: String
}

private func milliseconds(from duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
}

func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

private func average(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.reduce(0, +) / Double(values.count)
}
