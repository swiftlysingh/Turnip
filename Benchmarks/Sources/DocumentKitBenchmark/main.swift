import CryptoKit
import DocumentKit
import Foundation

#if canImport(Darwin)
import Darwin
#endif

@main
private struct DocumentKitBenchmarkCLI {
    static func main() async {
        do {
            guard let arguments = try Arguments.parse() else { return }
            try await BenchmarkRunner(arguments: arguments).run()
        } catch {
            let message = "error: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }
}

private struct Arguments {
    let manifestURL: URL
    let rootURL: URL?
    let outputURL: URL
    let repetitions: Int

    static func parse() throws -> Arguments? {
        let values = Array(CommandLine.arguments.dropFirst())
        if values.isEmpty {
            print(usage)
            throw BenchmarkError.usage("A manifest and output directory are required.")
        }

        var manifestPath: String?
        var rootPath: String?
        var outputPath: String?
        var repetitions = 2
        var index = 0

        while index < values.count {
            switch values[index] {
            case "--help", "-h":
                print(usage)
                return nil
            case "--manifest":
                manifestPath = try value(for: "--manifest", values: values, index: &index)
            case "--root":
                rootPath = try value(for: "--root", values: values, index: &index)
            case "--output":
                outputPath = try value(for: "--output", values: values, index: &index)
            case "--repetitions":
                let raw = try value(for: "--repetitions", values: values, index: &index)
                guard let parsed = Int(raw), parsed >= 2 else {
                    throw BenchmarkError.usage("--repetitions must be an integer of at least 2.")
                }
                repetitions = parsed
            default:
                throw BenchmarkError.usage("Unknown argument: \(values[index])")
            }
            index += 1
        }

        guard let manifestPath, !manifestPath.isEmpty else {
            throw BenchmarkError.usage("--manifest is required.")
        }
        guard let outputPath, !outputPath.isEmpty else {
            throw BenchmarkError.usage("--output is required.")
        }

        return Arguments(
            manifestURL: absoluteFileURL(manifestPath),
            rootURL: rootPath.map(absoluteFileURL),
            outputURL: absoluteFileURL(outputPath),
            repetitions: repetitions
        )
    }

    private static func value(
        for flag: String,
        values: [String],
        index: inout Int
    ) throws -> String {
        let next = index + 1
        guard next < values.count, !values[next].hasPrefix("--") else {
            throw BenchmarkError.usage("\(flag) requires a value.")
        }
        index = next
        return values[next]
    }

    fileprivate static var usage: String {
        """
        Usage: documentkit-benchmark --manifest PATH --output PATH [options]

        Options:
          --manifest PATH       JSON provenance/rights/checksum manifest.
          --root PATH           Root for relative PDF paths (default: manifest directory).
          --output PATH         Directory for Markdown, per-document JSON, and summary JSON.
          --repetitions N       Runs of inspect and extract per document (default: 2, minimum: 2).
          --help                Show this help.
        """
    }
}

private struct BenchmarkRunner {
    let arguments: Arguments

    func run() async throws {
        let loaded = try LoadedManifest(url: arguments.manifestURL)
        let rootURL = (arguments.rootURL ?? arguments.manifestURL.deletingLastPathComponent())
            .standardizedFileURL
        try loaded.manifest.validate(manifestURL: arguments.manifestURL, rootURL: rootURL)

        // Preflight every input before calling the engine. This makes a rights or
        // checksum failure fail closed instead of producing a partial green run.
        let documents = try preflight(loaded.manifest, rootURL: rootURL)
        try FileManager.default.createDirectory(
            at: arguments.outputURL,
            withIntermediateDirectories: true
        )

        let startedAt = ProcessInfo.processInfo.systemUptime
        var records: [DocumentResultRecord] = []
        records.reserveCapacity(documents.count)

        for document in documents {
            let record = await run(
                document,
                outputURL: arguments.outputURL,
                repetitions: arguments.repetitions,
                baseline: loaded.manifest.rawEngineBaseline
            )
            let resultURL = arguments.outputURL
                .appendingPathComponent("documents", isDirectory: true)
                .appendingPathComponent(document.id, isDirectory: true)
                .appendingPathComponent("result.json")
            try writeJSON(record, to: resultURL)
            records.append(record)

            let status = record.passed ? "passed" : "failed"
            print("\(document.id): \(status)")
        }

        let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
        let summary = BenchmarkSummary(
            manifestSHA256: loaded.sha256,
            manifestPath: arguments.manifestURL.path,
            corpus: loaded.manifest.corpus,
            rawEngineBaseline: loaded.manifest.rawEngineBaseline,
            repetitions: arguments.repetitions,
            elapsedMilliseconds: elapsedMilliseconds,
            records: records
        )
        try writeJSON(summary, to: arguments.outputURL.appendingPathComponent("summary.json"))

        print("summary: \(arguments.outputURL.appendingPathComponent("summary.json").path)")
        if !summary.passed {
            throw BenchmarkError.runFailed(
                "One or more documents failed parity, determinism, or engine execution."
            )
        }
    }

    private func preflight(
        _ manifest: BenchmarkManifest,
        rootURL: URL
    ) throws -> [PreparedDocument] {
        try manifest.documents.map { document in
            let pdfURL = try resolveRelativePath(document.pdf, rootURL: rootURL)
            let data: Data
            do {
                data = try Data(contentsOf: pdfURL, options: [.mappedIfSafe])
            } catch {
                throw BenchmarkError.inputReadFailed(
                    path: pdfURL.path,
                    message: error.localizedDescription
                )
            }

            let actualSHA256 = digestSHA256(data)
            guard actualSHA256 == document.sha256.lowercased() else {
                throw BenchmarkError.checksumMismatch(
                    id: document.id,
                    expected: document.sha256.lowercased(),
                    actual: actualSHA256
                )
            }
            return PreparedDocument(
                id: document.id,
                pdfPath: document.pdf,
                pdfURL: pdfURL,
                features: document.features,
                rightsStatus: document.rights.status,
                expectedSHA256: document.sha256.lowercased(),
                rawMarkdownSHA256: document.rawMarkdownSHA256,
                groundTruth: try document.groundTruth.map { groundTruth in
                    let markdownURL = try resolveRelativePath(
                        groundTruth.markdown,
                        rootURL: rootURL
                    )
                    let markdownData: Data
                    do {
                        markdownData = try Data(contentsOf: markdownURL)
                    } catch {
                        throw BenchmarkError.inputReadFailed(
                            path: markdownURL.path,
                            message: error.localizedDescription
                        )
                    }
                    let actualHash = digestSHA256(markdownData)
                    guard actualHash == groundTruth.sha256.lowercased() else {
                        throw BenchmarkError.checksumMismatch(
                            id: "\(document.id) ground truth",
                            expected: groundTruth.sha256.lowercased(),
                            actual: actualHash
                        )
                    }
                    guard let markdown = String(data: markdownData, encoding: .utf8) else {
                        throw BenchmarkError.invalidManifest(
                            "\(document.id) ground truth must be UTF-8 Markdown."
                        )
                    }
                    return PreparedGroundTruth(metadata: groundTruth, markdown: markdown)
                }
            )
        }
    }

    private func run(
        _ document: PreparedDocument,
        outputURL: URL,
        repetitions: Int,
        baseline: RawEngineBaseline?
    ) async -> DocumentResultRecord {
        let documentURL = outputURL
            .appendingPathComponent("documents", isDirectory: true)
            .appendingPathComponent(document.id, isDirectory: true)
        let markdownURL = documentURL.appendingPathComponent("markdown", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: markdownURL,
                withIntermediateDirectories: true
            )
        } catch {
            return DocumentResultRecord.inputFailure(
                document: document,
                error: ErrorRecord(code: "output_error", message: error.localizedDescription)
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: document.pdfURL, options: [.mappedIfSafe])
        } catch {
            return DocumentResultRecord.inputFailure(
                document: document,
                error: ErrorRecord(code: "input_read_failed", message: error.localizedDescription)
            )
        }

        // The file may have changed after preflight. Recheck immediately before
        // invoking the engine so the recorded result remains trustworthy.
        let observedSHA256 = digestSHA256(data)
        guard observedSHA256 == document.expectedSHA256 else {
            return DocumentResultRecord.inputFailure(
                document: document,
                observedSHA256: observedSHA256,
                error: ErrorRecord(
                    code: "checksum_mismatch",
                    message: "The PDF changed after preflight."
                )
            )
        }

        var inspectRuns: [InspectRunRecord] = []
        var extractRuns: [ExtractRunRecord] = []
        inspectRuns.reserveCapacity(repetitions)
        extractRuns.reserveCapacity(repetitions)

        for runNumber in 1...repetitions {
            let inspectStart = ProcessInfo.processInfo.systemUptime
            do {
                let inspection = try await DocumentKit.inspect(data)
                inspectRuns.append(
                    InspectRunRecord(
                        run: runNumber,
                        wallMilliseconds: elapsedMilliseconds(since: inspectStart),
                        inspection: InspectionSnapshot(inspection),
                        error: nil
                    )
                )
            } catch {
                inspectRuns.append(
                    InspectRunRecord(
                        run: runNumber,
                        wallMilliseconds: elapsedMilliseconds(since: inspectStart),
                        inspection: nil,
                        error: ErrorRecord(error)
                    )
                )
            }

            let extractStart = ProcessInfo.processInfo.systemUptime
            do {
                let extraction = try await DocumentKit.extract(data)
                let markdownData = Data(extraction.markdown.utf8)
                let relativeMarkdownPath = "documents/\(document.id)/markdown/\(markdownFileName(runNumber))"
                let outputMarkdownURL = outputURL.appendingPathComponent(relativeMarkdownPath)
                try markdownData.write(to: outputMarkdownURL, options: [.atomic])

                extractRuns.append(
                    ExtractRunRecord(
                        run: runNumber,
                        wallMilliseconds: elapsedMilliseconds(since: extractStart),
                        markdownSHA256: digestSHA256(markdownData),
                        markdownByteCount: markdownData.count,
                        markdownPath: relativeMarkdownPath,
                        inspection: InspectionSnapshot(extraction.inspection),
                        warnings: extraction.warnings.map(WarningSnapshot.init),
                        error: nil
                    )
                )
            } catch {
                extractRuns.append(
                    ExtractRunRecord(
                        run: runNumber,
                        wallMilliseconds: elapsedMilliseconds(since: extractStart),
                        markdownSHA256: nil,
                        markdownByteCount: nil,
                        markdownPath: nil,
                        inspection: nil,
                        warnings: [],
                        error: ErrorRecord(error)
                    )
                )
            }
        }

        let determinism = DeterminismRecord(
            inspectStable: stable(inspectRuns.compactMap(\.inspection), count: repetitions),
            extractStable: stable(extractRuns.compactMap(\.markdownSHA256), count: repetitions)
                && stable(extractRuns.compactMap(\.inspection), count: repetitions)
        )
        let baselineComparison = baseline.map {
            BaselineComparison(
                engine: $0.engine,
                revision: $0.revision,
                expectedMarkdownSHA256: document.rawMarkdownSHA256!,
                observedMarkdownSHA256: extractRuns.compactMap(\.markdownSHA256)
            )
        }
        let qualityComparison: QualityComparison?
        if let groundTruth = document.groundTruth,
           let path = extractRuns.first(where: { $0.error == nil })?.markdownPath,
           let markdown = try? String(
               contentsOf: outputURL.appendingPathComponent(path),
               encoding: .utf8
           ) {
            qualityComparison = QualityComparison(
                observed: markdown,
                groundTruth: groundTruth
            )
        } else {
            qualityComparison = nil
        }

        return DocumentResultRecord(
            id: document.id,
            pdfPath: document.pdfPath,
            features: document.features,
            rightsStatus: document.rightsStatus,
            expectedPDFSHA256: document.expectedSHA256,
            observedPDFSHA256: observedSHA256,
            preflightError: nil,
            inspectRuns: inspectRuns,
            extractRuns: extractRuns,
            determinism: determinism,
            baseline: baselineComparison,
            groundTruthExpected: document.groundTruth != nil,
            quality: qualityComparison
        )
    }
}

private struct LoadedManifest {
    let manifest: BenchmarkManifest
    let sha256: String

    init(url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw BenchmarkError.manifestReadFailed(
                path: url.path,
                message: error.localizedDescription
            )
        }

        do {
            manifest = try JSONDecoder().decode(BenchmarkManifest.self, from: data)
        } catch {
            throw BenchmarkError.invalidManifest(error.localizedDescription)
        }
        sha256 = digestSHA256(data)
    }
}

private struct BenchmarkManifest: Codable, Sendable {
    let schemaVersion: Int
    let corpus: CorpusMetadata
    let rawEngineBaseline: RawEngineBaseline?
    let documents: [ManifestDocument]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case corpus
        case rawEngineBaseline = "raw_engine_baseline"
        case documents
    }

    func validate(manifestURL: URL, rootURL: URL) throws {
        guard schemaVersion == 1 else {
            throw BenchmarkError.invalidManifest("Unsupported schema_version \(schemaVersion).")
        }
        guard !corpus.id.isEmpty else {
            throw BenchmarkError.invalidManifest("corpus.id must not be empty.")
        }
        guard !documents.isEmpty else {
            throw BenchmarkError.invalidManifest("documents must contain at least one PDF.")
        }
        if corpus.distribution == .externalOnly {
            try validateHTTPURL(corpus.sourceURL, field: "corpus.source_url")
            if let revision = corpus.revision, !isPinnedRevision(revision) {
                throw BenchmarkError.invalidManifest(
                    "When provided, corpus.revision must be an exact commit SHA."
                )
            }
        }

        var ids = Set<String>()
        var paths = Set<String>()
        for document in documents {
            guard validIdentifier(document.id), ids.insert(document.id).inserted else {
                throw BenchmarkError.invalidManifest(
                    "Document IDs must be unique and safe path components: \(document.id)"
                )
            }
            guard paths.insert(document.pdf).inserted else {
                throw BenchmarkError.invalidManifest(
                    "A PDF path is listed more than once: \(document.pdf)"
                )
            }
            _ = try resolveRelativePath(document.pdf, rootURL: rootURL)
            guard document.pdf.lowercased().hasSuffix(".pdf") else {
                throw BenchmarkError.invalidManifest(
                    "Document path must end in .pdf: \(document.pdf)"
                )
            }
            guard !document.features.isEmpty,
                  document.features.allSatisfy(validIdentifier) else {
                throw BenchmarkError.invalidManifest(
                    "\(document.id) must list safe extraction feature identifiers."
                )
            }
            guard isHex(document.sha256, count: 64) else {
                throw BenchmarkError.invalidManifest(
                    "\(document.id) has an invalid PDF SHA-256."
                )
            }
            try validateRights(document.rights, documentID: document.id)
            if corpus.distribution == .committed, document.rights.status != .cleared {
                throw BenchmarkError.unapprovedRights(
                    id: document.id,
                    status: document.rights.status.rawValue
                )
            }
            if let baselineHash = document.rawMarkdownSHA256,
               !isHex(baselineHash, count: 64) {
                throw BenchmarkError.invalidManifest(
                    "\(document.id) has an invalid raw_markdown_sha256."
                )
            }
            if let groundTruth = document.groundTruth {
                let url = try resolveRelativePath(groundTruth.markdown, rootURL: rootURL)
                guard url.pathExtension.lowercased() == "md" else {
                    throw BenchmarkError.invalidManifest(
                        "\(document.id) ground truth path must end in .md."
                    )
                }
                guard isHex(groundTruth.sha256, count: 64) else {
                    throw BenchmarkError.invalidManifest(
                        "\(document.id) has an invalid ground-truth SHA-256."
                    )
                }
                guard (0...1).contains(groundTruth.minimumTokenF1),
                      (0...1).contains(groundTruth.minimumStructureF1) else {
                    throw BenchmarkError.invalidManifest(
                        "\(document.id) ground-truth thresholds must be between 0 and 1."
                    )
                }
            }
        }

        if let baseline = rawEngineBaseline {
            guard !baseline.engine.isEmpty else {
                throw BenchmarkError.invalidManifest("raw_engine_baseline.engine must not be empty.")
            }
            guard isPinnedRevision(baseline.revision) else {
                throw BenchmarkError.invalidManifest(
                    "raw_engine_baseline.revision must be an exact commit SHA."
                )
            }
            if let markdownDirectory = baseline.markdownDirectory {
                _ = try resolveRelativePath(markdownDirectory, rootURL: rootURL)
            }
            guard documents.allSatisfy({ $0.rawMarkdownSHA256 != nil }) else {
                throw BenchmarkError.invalidManifest(
                    "Every document needs raw_markdown_sha256 when a baseline is pinned."
                )
            }
        } else if documents.contains(where: { $0.rawMarkdownSHA256 != nil }) {
            throw BenchmarkError.invalidManifest(
                "raw_markdown_sha256 requires raw_engine_baseline."
            )
        }

        _ = manifestURL
    }

    private func validateRights(_ rights: RightsMetadata, documentID: String) throws {
        guard !rights.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BenchmarkError.invalidManifest("\(documentID) must include rights.license.")
        }
        try validateHTTPURL(rights.sourceURL, field: "\(documentID).rights.source_url")
        guard rights.status == .cleared || rights.status == .externalOnly else {
            throw BenchmarkError.unapprovedRights(
                id: documentID,
                status: rights.status.rawValue
            )
        }
    }
}

private struct CorpusMetadata: Codable, Sendable {
    let id: String
    let distribution: Distribution
    let sourceURL: String?
    let revision: String?

    enum CodingKeys: String, CodingKey {
        case id
        case distribution
        case sourceURL = "source_url"
        case revision
    }
}

private enum Distribution: String, Codable, Sendable {
    case committed
    case externalOnly = "external-only"
}

private struct RawEngineBaseline: Codable, Sendable {
    let engine: String
    let revision: String
    let markdownDirectory: String?

    enum CodingKeys: String, CodingKey {
        case engine
        case revision
        case markdownDirectory = "markdown_directory"
    }
}

private struct ManifestDocument: Codable, Sendable {
    let id: String
    let pdf: String
    let sha256: String
    let features: [String]
    let rawMarkdownSHA256: String?
    let groundTruth: GroundTruthMetadata?
    let rights: RightsMetadata

    enum CodingKeys: String, CodingKey {
        case id
        case pdf
        case sha256
        case features
        case rawMarkdownSHA256 = "raw_markdown_sha256"
        case groundTruth = "ground_truth"
        case rights
    }
}

private struct GroundTruthMetadata: Codable, Sendable {
    let markdown: String
    let sha256: String
    let minimumTokenF1: Double
    let minimumStructureF1: Double

    enum CodingKeys: String, CodingKey {
        case markdown
        case sha256
        case minimumTokenF1 = "minimum_token_f1"
        case minimumStructureF1 = "minimum_structure_f1"
    }
}

private struct RightsMetadata: Codable, Sendable {
    let status: RightsStatus
    let license: String
    let sourceURL: String
    let attribution: String?

    enum CodingKeys: String, CodingKey {
        case status
        case license
        case sourceURL = "source_url"
        case attribution
    }
}

private enum RightsStatus: String, Codable, Sendable {
    case cleared
    case externalOnly = "external-only"
}

private struct PreparedDocument: Sendable {
    let id: String
    let pdfPath: String
    let pdfURL: URL
    let features: [String]
    let rightsStatus: RightsStatus
    let expectedSHA256: String
    let rawMarkdownSHA256: String?
    let groundTruth: PreparedGroundTruth?
}

private struct PreparedGroundTruth: Sendable {
    let metadata: GroundTruthMetadata
    let markdown: String
}

private struct DocumentResultRecord: Codable, Sendable {
    let id: String
    let pdfPath: String
    let features: [String]
    let rightsStatus: RightsStatus
    let expectedPDFSHA256: String
    let observedPDFSHA256: String?
    let preflightError: ErrorRecord?
    let inspectRuns: [InspectRunRecord]
    let extractRuns: [ExtractRunRecord]
    let determinism: DeterminismRecord
    let baseline: BaselineComparison?
    let groundTruthExpected: Bool
    let quality: QualityComparison?

    var passed: Bool {
        preflightError == nil
            && inspectRuns.count > 1
            && extractRuns.count > 1
            && inspectRuns.allSatisfy { $0.error == nil }
            && extractRuns.allSatisfy { $0.error == nil }
            && determinism.passed
            && (baseline?.matches ?? true)
            && (!groundTruthExpected || quality != nil)
            && (quality?.passes ?? true)
    }

    static func inputFailure(
        document: PreparedDocument,
        observedSHA256: String? = nil,
        error: ErrorRecord
    ) -> DocumentResultRecord {
        DocumentResultRecord(
            id: document.id,
            pdfPath: document.pdfPath,
            features: document.features,
            rightsStatus: document.rightsStatus,
            expectedPDFSHA256: document.expectedSHA256,
            observedPDFSHA256: observedSHA256,
            preflightError: error,
            inspectRuns: [],
            extractRuns: [],
            determinism: DeterminismRecord(inspectStable: false, extractStable: false),
            baseline: nil,
            groundTruthExpected: document.groundTruth != nil,
            quality: nil
        )
    }
}

private struct InspectRunRecord: Codable, Sendable {
    let run: Int
    let wallMilliseconds: Double
    let inspection: InspectionSnapshot?
    let error: ErrorRecord?

    enum CodingKeys: String, CodingKey {
        case run
        case wallMilliseconds = "wall_milliseconds"
        case inspection
        case error
    }
}

private struct ExtractRunRecord: Codable, Sendable {
    let run: Int
    let wallMilliseconds: Double
    let markdownSHA256: String?
    let markdownByteCount: Int?
    let markdownPath: String?
    let inspection: InspectionSnapshot?
    let warnings: [WarningSnapshot]
    let error: ErrorRecord?

    enum CodingKeys: String, CodingKey {
        case run
        case wallMilliseconds = "wall_milliseconds"
        case markdownSHA256 = "markdown_sha256"
        case markdownByteCount = "markdown_byte_count"
        case markdownPath = "markdown_path"
        case inspection
        case warnings
        case error
    }
}

private struct InspectionSnapshot: Codable, Equatable, Sendable {
    let kind: String
    let pageCount: Int
    let title: String?
    let confidence: Double
    let pagesNeedingOCR: [Int]
    let ocrReasonsByPage: [PageOCRReasonsSnapshot]
    let layout: LayoutSnapshot?
    let hasEncodingIssues: Bool?
    let engineVersion: String

    enum CodingKeys: String, CodingKey {
        case kind
        case pageCount = "page_count"
        case title
        case confidence
        case pagesNeedingOCR = "pages_needing_ocr"
        case ocrReasonsByPage = "ocr_reasons_by_page"
        case layout
        case hasEncodingIssues = "has_encoding_issues"
        case engineVersion = "engine_version"
    }

    init(_ inspection: DocumentInspection) {
        kind = inspection.kind.rawValue
        pageCount = inspection.pageCount
        title = inspection.title
        confidence = Double(inspection.confidence)
        pagesNeedingOCR = inspection.pagesNeedingOCR
        ocrReasonsByPage = inspection.ocrReasonsByPage.map(PageOCRReasonsSnapshot.init)
        layout = inspection.layout.map(LayoutSnapshot.init)
        hasEncodingIssues = inspection.hasEncodingIssues
        engineVersion = inspection.engineVersion
    }
}

private struct LayoutSnapshot: Codable, Equatable, Sendable {
    let isComplex: Bool
    let pagesWithTables: [Int]
    let pagesWithColumns: [Int]

    enum CodingKeys: String, CodingKey {
        case isComplex = "is_complex"
        case pagesWithTables = "pages_with_tables"
        case pagesWithColumns = "pages_with_columns"
    }

    init(_ layout: DocumentLayout) {
        isComplex = layout.isComplex
        pagesWithTables = layout.pagesWithTables
        pagesWithColumns = layout.pagesWithColumns
    }
}

private struct PageOCRReasonsSnapshot: Codable, Equatable, Sendable {
    let pageIndex: Int
    let reasons: [String]

    enum CodingKeys: String, CodingKey {
        case pageIndex = "page_index"
        case reasons
    }

    init(_ value: PageOCRReasons) {
        pageIndex = value.pageIndex
        reasons = value.reasons
    }
}

private struct WarningSnapshot: Codable, Sendable {
    let kind: String
    let pageIndexes: [Int]

    enum CodingKeys: String, CodingKey {
        case kind
        case pageIndexes = "page_indexes"
    }

    init(_ warning: DocumentWarning) {
        switch warning.kind {
        case .ocrRequired:
            kind = "ocr_required"
        case .encodingIssues:
            kind = "encoding_issues"
        }
        pageIndexes = warning.pageIndexes
    }
}

private struct DeterminismRecord: Codable, Sendable {
    let inspectStable: Bool
    let extractStable: Bool

    var passed: Bool { inspectStable && extractStable }

    enum CodingKeys: String, CodingKey {
        case inspectStable = "inspect_stable"
        case extractStable = "extract_stable"
    }
}

private struct BaselineComparison: Codable, Sendable {
    let engine: String
    let revision: String
    let expectedMarkdownSHA256: String
    let observedMarkdownSHA256: [String]
    let matches: Bool

    enum CodingKeys: String, CodingKey {
        case engine
        case revision
        case expectedMarkdownSHA256 = "expected_markdown_sha256"
        case observedMarkdownSHA256 = "observed_markdown_sha256"
        case matches
    }

    init(
        engine: String,
        revision: String,
        expectedMarkdownSHA256: String,
        observedMarkdownSHA256: [String]
    ) {
        self.engine = engine
        self.revision = revision
        self.expectedMarkdownSHA256 = expectedMarkdownSHA256.lowercased()
        self.observedMarkdownSHA256 = observedMarkdownSHA256
        matches = observedMarkdownSHA256.count > 1
            && observedMarkdownSHA256.allSatisfy {
                $0.lowercased() == expectedMarkdownSHA256.lowercased()
            }
    }
}

private struct QualityComparison: Codable, Sendable {
    let expectedMarkdownSHA256: String
    let observedMarkdownSHA256: String
    let exactMatch: Bool
    let tokenF1: Double
    let structureF1: Double
    let minimumTokenF1: Double
    let minimumStructureF1: Double
    let passes: Bool

    enum CodingKeys: String, CodingKey {
        case expectedMarkdownSHA256 = "expected_markdown_sha256"
        case observedMarkdownSHA256 = "observed_markdown_sha256"
        case exactMatch = "exact_match"
        case tokenF1 = "token_f1"
        case structureF1 = "structure_f1"
        case minimumTokenF1 = "minimum_token_f1"
        case minimumStructureF1 = "minimum_structure_f1"
        case passes
    }

    init(observed: String, groundTruth: PreparedGroundTruth) {
        let expectedData = Data(groundTruth.markdown.utf8)
        let observedData = Data(observed.utf8)
        expectedMarkdownSHA256 = digestSHA256(expectedData)
        observedMarkdownSHA256 = digestSHA256(observedData)
        exactMatch = expectedMarkdownSHA256 == observedMarkdownSHA256
        tokenF1 = multisetF1(tokens(observed), tokens(groundTruth.markdown))
        structureF1 = multisetF1(
            markdownStructure(observed),
            markdownStructure(groundTruth.markdown)
        )
        minimumTokenF1 = groundTruth.metadata.minimumTokenF1
        minimumStructureF1 = groundTruth.metadata.minimumStructureF1
        passes = tokenF1 >= minimumTokenF1 && structureF1 >= minimumStructureF1
    }
}

private struct ErrorRecord: Codable, Sendable {
    let code: String
    let message: String

    init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    init(_ error: Error) {
        if let error = error as? DocumentKitError {
            switch error {
            case .emptyInput:
                self.init(code: "empty_input", message: error.localizedDescription)
            case let .inputTooLarge(maximumBytes):
                self.init(code: "input_too_large", message: "Maximum bytes: \(maximumBytes).")
            case .encryptedPDF:
                self.init(code: "encrypted_pdf", message: error.localizedDescription)
            case .invalidPDF:
                self.init(code: "invalid_pdf", message: error.localizedDescription)
            case .noExtractableText:
                self.init(code: "no_extractable_text", message: error.localizedDescription)
            case let .engineFailure(code, message):
                self.init(code: code, message: message)
            }
        } else {
            self.init(code: "unknown_error", message: error.localizedDescription)
        }
    }
}

private struct BenchmarkSummary: Codable, Sendable {
    let schemaVersion: Int
    let status: String
    let passed: Bool
    let manifestSHA256: String
    let manifestPath: String
    let corpus: CorpusMetadata
    let rawEngineBaseline: RawEngineBaseline?
    let repetitions: Int
    let elapsedMilliseconds: Double
    let counts: Counts
    let timing: TimingSummary
    let documents: [DocumentSummary]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case status
        case passed
        case manifestSHA256 = "manifest_sha256"
        case manifestPath = "manifest_path"
        case corpus
        case rawEngineBaseline = "raw_engine_baseline"
        case repetitions
        case elapsedMilliseconds = "elapsed_milliseconds"
        case counts
        case timing
        case documents
    }

    init(
        manifestSHA256: String,
        manifestPath: String,
        corpus: CorpusMetadata,
        rawEngineBaseline: RawEngineBaseline?,
        repetitions: Int,
        elapsedMilliseconds: Double,
        records: [DocumentResultRecord]
    ) {
        schemaVersion = 1
        passed = records.allSatisfy(\.passed)
        status = passed ? "passed" : "failed"
        self.manifestSHA256 = manifestSHA256
        self.manifestPath = manifestPath
        self.corpus = corpus
        self.rawEngineBaseline = rawEngineBaseline
        self.repetitions = repetitions
        self.elapsedMilliseconds = elapsedMilliseconds
        counts = Counts(records)
        timing = TimingSummary(records)
        documents = records.map(DocumentSummary.init)
    }

}

private struct Counts: Codable, Sendable {
    let totalDocuments: Int
    let passedDocuments: Int
    let failedDocuments: Int
    let nondeterministicDocuments: Int
    let baselineMismatches: Int
    let qualityFailures: Int

    enum CodingKeys: String, CodingKey {
        case totalDocuments = "total_documents"
        case passedDocuments = "passed_documents"
        case failedDocuments = "failed_documents"
        case nondeterministicDocuments = "nondeterministic_documents"
        case baselineMismatches = "baseline_mismatches"
        case qualityFailures = "quality_failures"
    }

    init(_ records: [DocumentResultRecord]) {
        totalDocuments = records.count
        passedDocuments = records.count(where: \.passed)
        failedDocuments = totalDocuments - passedDocuments
        nondeterministicDocuments = records.count(where: {
            !$0.determinism.passed && $0.preflightError == nil
        })
        baselineMismatches = records.count(where: {
            $0.baseline?.matches == false
        })
        qualityFailures = records.count(where: {
            $0.quality?.passes == false
        })
    }
}

private struct TimingSummary: Codable, Sendable {
    let inspect: TimingAggregate
    let extract: TimingAggregate

    init(_ records: [DocumentResultRecord]) {
        inspect = TimingAggregate(records.flatMap { $0.inspectRuns.map(\.wallMilliseconds) })
        extract = TimingAggregate(records.flatMap { $0.extractRuns.map(\.wallMilliseconds) })
    }
}

private struct TimingAggregate: Codable, Sendable {
    let samples: Int
    let totalMilliseconds: Double
    let medianMilliseconds: Double?

    init(_ values: [Double]) {
        samples = values.count
        totalMilliseconds = values.reduce(0, +)
        guard !values.isEmpty else {
            medianMilliseconds = nil
            return
        }
        let sorted = values.sorted()
        if sorted.count.isMultiple(of: 2) {
            medianMilliseconds = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        } else {
            medianMilliseconds = sorted[sorted.count / 2]
        }
    }
}

private struct DocumentSummary: Codable, Sendable {
    let id: String
    let passed: Bool
    let resultPath: String
    let markdownSHA256: String?
    let baselineMatches: Bool?
    let qualityPasses: Bool?
    let tokenF1: Double?
    let structureF1: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case passed
        case resultPath = "result_path"
        case markdownSHA256 = "markdown_sha256"
        case baselineMatches = "baseline_matches"
        case qualityPasses = "quality_passes"
        case tokenF1 = "token_f1"
        case structureF1 = "structure_f1"
    }

    init(_ record: DocumentResultRecord) {
        id = record.id
        passed = record.passed
        resultPath = "documents/\(record.id)/result.json"
        markdownSHA256 = record.extractRuns.last?.markdownSHA256
        baselineMatches = record.baseline?.matches
        qualityPasses = record.quality?.passes
        tokenF1 = record.quality?.tokenF1
        structureF1 = record.quality?.structureF1
    }
}

private enum BenchmarkError: Error, LocalizedError {
    case usage(String)
    case manifestReadFailed(path: String, message: String)
    case invalidManifest(String)
    case inputReadFailed(path: String, message: String)
    case checksumMismatch(id: String, expected: String, actual: String)
    case unapprovedRights(id: String, status: String)
    case runFailed(String)

    var errorDescription: String? {
        switch self {
        case let .usage(message):
            return "\(message)\n\(Arguments.usage)"
        case let .manifestReadFailed(path, message):
            return "Could not read manifest at \(path): \(message)"
        case let .invalidManifest(message):
            return "Invalid manifest: \(message)"
        case let .inputReadFailed(path, message):
            return "Could not read PDF at \(path): \(message)"
        case let .checksumMismatch(id, expected, actual):
            return "Checksum mismatch for \(id): expected \(expected), got \(actual)."
        case let .unapprovedRights(id, status):
            return "Refusing \(id): rights status '\(status)' is not approved."
        case let .runFailed(message):
            return message
        }
    }
}

private func resolveRelativePath(_ path: String, rootURL: URL) throws -> URL {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
        throw BenchmarkError.invalidManifest("Path must be relative and safe: \(path)")
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.contains(where: { $0 == ".." }) else {
        throw BenchmarkError.invalidManifest("Path may not contain '..': \(path)")
    }

    let root = rootURL.standardizedFileURL
    let candidate = root.appendingPathComponent(path).standardizedFileURL
    guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
        throw BenchmarkError.invalidManifest("Path escapes root: \(path)")
    }
    return candidate
}

private func validateHTTPURL(_ value: String?, field: String) throws {
    guard let value,
          let url = URL(string: value),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.host != nil else {
        throw BenchmarkError.invalidManifest("\(field) must be an http(s) URL.")
    }
}

private func validIdentifier(_ value: String) -> Bool {
    !value.isEmpty
        && value != "."
        && value != ".."
        && !value.contains("/")
        && !value.contains("\\")
        && !value.contains(where: { $0.isNewline || $0.isWhitespace })
}

private func isHex(_ value: String, count: Int) -> Bool {
    value.count == count && value.allSatisfy { $0.isHexDigit }
}

private func isPinnedRevision(_ value: String) -> Bool {
    isHex(value, count: 40)
}

private func absoluteFileURL(_ path: String) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(path)
        .standardizedFileURL
}

private func digestSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func elapsedMilliseconds(since start: TimeInterval) -> Double {
    (ProcessInfo.processInfo.systemUptime - start) * 1_000
}

private func markdownFileName(_ run: Int) -> String {
    String(format: "run-%02d.md", run)
}

private func stable<T: Equatable>(_ values: [T], count: Int) -> Bool {
    values.count == count && values.dropFirst().allSatisfy { $0 == values[0] }
}

private func tokens(_ markdown: String) -> [String] {
    markdown
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
}

private func markdownStructure(_ markdown: String) -> [String] {
    markdown.split(separator: "\n", omittingEmptySubsequences: true).map { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            return "heading:\(trimmed.prefix(while: { $0 == "#" }).count)"
        }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return "unordered-list-item"
        }
        if trimmed.first?.isNumber == true,
           trimmed.drop(while: { $0.isNumber }).hasPrefix(". ") {
            return "ordered-list-item"
        }
        if trimmed.hasPrefix(">") { return "blockquote" }
        if trimmed.hasPrefix("```") { return "code-fence" }
        if trimmed.contains("|") { return "table-row" }
        return "paragraph"
    }
}

private func multisetF1(_ observed: [String], _ expected: [String]) -> Double {
    if observed.isEmpty && expected.isEmpty { return 1 }
    guard !observed.isEmpty, !expected.isEmpty else { return 0 }

    var remaining = Dictionary(grouping: expected, by: { $0 }).mapValues(\.count)
    var matches = 0
    for value in observed where remaining[value, default: 0] > 0 {
        matches += 1
        remaining[value, default: 0] -= 1
    }
    let precision = Double(matches) / Double(observed.count)
    let recall = Double(matches) / Double(expected.count)
    guard precision + recall > 0 else { return 0 }
    return 2 * precision * recall / (precision + recall)
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    try data.write(to: url, options: [.atomic])
}
