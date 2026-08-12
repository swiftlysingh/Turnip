import CryptoKit
import DocumentKit
import Foundation
import PDFKit

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
    let warmups: Int
    let requireRelease: Bool

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
        var warmups = 0
        var requireRelease = false
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
            case "--warmups":
                let raw = try value(for: "--warmups", values: values, index: &index)
                guard let parsed = Int(raw), parsed >= 0 else {
                    throw BenchmarkError.usage("--warmups must be a non-negative integer.")
                }
                warmups = parsed
            case "--require-release":
                requireRelease = true
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
            repetitions: repetitions,
            warmups: warmups,
            requireRelease: requireRelease
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
          --warmups N           Unmeasured warm-up runs per engine (default: 0).
          --require-release     Require release build, pinned source SHA, and locked truth for every case.
          --help                Show this help.
        """
    }
}

private struct BenchmarkRunner {
    let arguments: Arguments

    func run() async throws {
        if arguments.requireRelease && benchmarkBuildConfiguration != "release" {
            throw BenchmarkError.usage(
                "--require-release requires 'swift run -c release'."
            )
        }
        let loaded = try LoadedManifest(url: arguments.manifestURL)
        let rootURL = (arguments.rootURL ?? arguments.manifestURL.deletingLastPathComponent())
            .standardizedFileURL
        try loaded.manifest.validate(manifestURL: arguments.manifestURL, rootURL: rootURL)
        if arguments.requireRelease {
            try loaded.manifest.validateReleaseEvidence()
            guard let revision = ProcessInfo.processInfo.environment[
                "DOCUMENTKIT_BENCHMARK_SOURCE_REVISION"
            ], isPinnedRevision(revision) else {
                throw BenchmarkError.invalidManifest(
                    "Release evidence requires DOCUMENTKIT_BENCHMARK_SOURCE_REVISION to be an exact commit SHA."
                )
            }
        }

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
                warmups: arguments.warmups,
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
            warmups: arguments.warmups,
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
                    try validateCanonicalMarkdown(markdown, documentID: document.id)
                    return PreparedGroundTruth(metadata: groundTruth, markdown: markdown)
                },
                expectedPageCount: document.expectedPageCount,
                expectedOCRPages: document.expectedOCRPages
            )
        }
    }

    private func run(
        _ document: PreparedDocument,
        outputURL: URL,
        repetitions: Int,
        warmups: Int,
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

        if warmups > 0 {
            for _ in 0..<warmups {
                _ = try? await DocumentKit.inspect(data)
                _ = try? await DocumentKit.extract(data)
                _ = try? pdfKitText(from: data)
            }
        }

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
                let extractWallMilliseconds = elapsedMilliseconds(since: extractStart)
                let markdownData = Data(extraction.markdown.utf8)
                let relativeMarkdownPath = "documents/\(document.id)/markdown/\(markdownFileName(runNumber))"
                let outputMarkdownURL = outputURL.appendingPathComponent(relativeMarkdownPath)
                try markdownData.write(to: outputMarkdownURL, options: [.atomic])

                extractRuns.append(
                    ExtractRunRecord(
                        run: runNumber,
                        wallMilliseconds: extractWallMilliseconds,
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
            extractStable: stable(
                extractRuns.compactMap(ExtractionFingerprint.init),
                count: repetitions
            )
        )
        let baselineComparison = baseline.map {
            BaselineComparison(
                engine: $0.engine,
                revision: $0.revision,
                expectedMarkdownSHA256: document.rawMarkdownSHA256!,
                observedMarkdownSHA256: extractRuns.compactMap(\.markdownSHA256)
            )
        }
        let extractionInspection = extractRuns.first(where: { $0.inspection != nil })?.inspection
        let qualityComparison: QualityComparison?
        if determinism.extractStable,
           let groundTruth = document.groundTruth,
           let path = extractRuns.first(where: { $0.error == nil })?.markdownPath,
           let markdown = try? String(
               contentsOf: outputURL.appendingPathComponent(path),
               encoding: .utf8
           ) {
            qualityComparison = QualityComparison(
                observed: markdown,
                groundTruth: groundTruth,
                observedOCRPages: extractionInspection?.pagesNeedingOCR,
                expectedOCRPages: document.expectedOCRPages
            )
        } else {
            qualityComparison = nil
        }

        let pdfKitBaseline = runPDFKitBaseline(
            data: data,
            document: document,
            documentURL: documentURL,
            repetitions: repetitions
        )

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
            groundTruthState: document.groundTruth?.metadata.effectiveState,
            quality: qualityComparison,
            pdfKitBaseline: pdfKitBaseline,
            expectedPageCount: document.expectedPageCount
        )
    }

    private func runPDFKitBaseline(
        data: Data,
        document: PreparedDocument,
        documentURL: URL,
        repetitions: Int
    ) -> PDFKitBaselineRecord {
        var runs: [PDFKitRunRecord] = []
        var firstText: String?
        var pageCount: Int?

        for runNumber in 1...repetitions {
            let start = ProcessInfo.processInfo.systemUptime
            do {
                let result = try pdfKitText(from: data)
                let pdfKitWallMilliseconds = elapsedMilliseconds(since: start)
                let textData = Data(result.text.utf8)
                if firstText == nil {
                    try textData.write(
                        to: documentURL.appendingPathComponent("pdfkit.txt"),
                        options: [.atomic]
                    )
                    firstText = result.text
                    pageCount = result.pageCount
                }
                runs.append(
                    PDFKitRunRecord(
                        run: runNumber,
                        wallMilliseconds: pdfKitWallMilliseconds,
                        textSHA256: digestSHA256(textData),
                        textByteCount: textData.count,
                        error: nil
                    )
                )
            } catch {
                runs.append(
                    PDFKitRunRecord(
                        run: runNumber,
                        wallMilliseconds: elapsedMilliseconds(since: start),
                        textSHA256: nil,
                        textByteCount: nil,
                        error: ErrorRecord(code: "pdfkit_error", message: error.localizedDescription)
                    )
                )
            }
        }

        let hashes = runs.compactMap(\.textSHA256)
        let deterministic = stable(hashes, count: repetitions)
        return PDFKitBaselineRecord(
            supported: true,
            attempted: true,
            pageCount: pageCount,
            textPath: firstText == nil ? nil : "documents/\(document.id)/pdfkit.txt",
            runs: runs,
            deterministic: deterministic,
            quality: deterministic ? firstText.flatMap { text in
                document.groundTruth.map {
                    PDFKitQualityComparison(observed: text, groundTruth: $0)
                }
            } : nil
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
        guard schemaVersion == 1 || schemaVersion == 2 else {
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
            let resolvedPDF = try resolveRelativePath(document.pdf, rootURL: rootURL)
            guard paths.insert(resolvedPDF.path).inserted else {
                throw BenchmarkError.invalidManifest(
                    "A PDF path is listed more than once: \(document.pdf)"
                )
            }
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
                try validateGroundTruth(
                    groundTruth,
                    documentID: document.id,
                    schemaVersion: schemaVersion,
                    features: document.features
                )
            }
            if let expectedPageCount = document.expectedPageCount, expectedPageCount < 1 {
                throw BenchmarkError.invalidManifest(
                    "\(document.id) expected_page_count must be positive."
                )
            }
            if let expectedOCRPages = document.expectedOCRPages {
                guard expectedOCRPages == expectedOCRPages.sorted(),
                      Set(expectedOCRPages).count == expectedOCRPages.count,
                      expectedOCRPages.allSatisfy({ $0 >= 0 }) else {
                    throw BenchmarkError.invalidManifest(
                        "\(document.id) expected_ocr_pages must be unique, ascending, zero-based indexes."
                    )
                }
                if let expectedPageCount = document.expectedPageCount,
                   expectedOCRPages.contains(where: { $0 >= expectedPageCount }) {
                    throw BenchmarkError.invalidManifest(
                        "\(document.id) expected_ocr_pages contains an out-of-range index."
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

    func validateReleaseEvidence() throws {
        guard schemaVersion == 2 else {
            throw BenchmarkError.invalidManifest(
                "Release evidence requires manifest schema v2."
            )
        }
        guard documents.allSatisfy({ $0.groundTruth?.effectiveState == .locked }) else {
            throw BenchmarkError.invalidManifest(
                "Release evidence requires locked ground truth for every document."
            )
        }
    }

    private func validateGroundTruth(
        _ groundTruth: GroundTruthMetadata,
        documentID: String,
        schemaVersion: Int,
        features: [String]
    ) throws {
        if schemaVersion == 2 {
            guard groundTruth.state != nil,
                  groundTruth.authoredWithoutDocumentKitOutput != nil,
                  groundTruth.authoringMethod != nil else {
                throw BenchmarkError.invalidManifest(
                    "\(documentID) schema v2 ground truth needs state, authoring_method, and authored_without_documentkit_output."
                )
            }
        }
        if schemaVersion == 2, groundTruth.effectiveState == .locked {
            guard groundTruth.authoredWithoutDocumentKitOutput == true else {
                throw BenchmarkError.invalidManifest(
                    "\(documentID) locked ground truth must be authored without DocumentKit output."
                )
            }
            guard let author = groundTruth.author?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !author.isEmpty,
                  let reviewer = groundTruth.reviewer?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !reviewer.isEmpty,
                  reviewer.localizedCaseInsensitiveCompare(author) != .orderedSame,
                  let reviewedAt = groundTruth.reviewedAt,
                  isISODate(reviewedAt) else {
                throw BenchmarkError.invalidManifest(
                    "\(documentID) locked ground truth needs distinct author/reviewer identities and reviewed_at (YYYY-MM-DD)."
                )
            }
        }
        for criticalValue in groundTruth.criticalValues ?? [] {
            guard validIdentifier(criticalValue.id),
                  !criticalValue.value.isEmpty,
                  criticalValue.occurrences > 0 else {
                throw BenchmarkError.invalidManifest(
                    "\(documentID) critical values need a safe id, non-empty value, and positive occurrences."
                )
            }
        }
        let criticalIDs = (groundTruth.criticalValues ?? []).map(\.id)
        guard Set(criticalIDs).count == criticalIDs.count else {
            throw BenchmarkError.invalidManifest(
                "\(documentID) critical-value ids must be unique."
            )
        }
        if groundTruth.effectiveState == .locked {
            let criticalValues = groundTruth.criticalValues ?? []
            if features.contains("critical-values"), criticalValues.isEmpty {
                throw BenchmarkError.invalidManifest(
                    "\(documentID) is marked critical-values and needs at least one locked critical value."
                )
            }
            if !criticalValues.isEmpty {
                guard groundTruth.minimumCriticalValueAccuracy == 1 else {
                    throw BenchmarkError.invalidManifest(
                        "\(documentID) locked critical values require minimum_critical_value_accuracy 1.0."
                    )
                }
                guard criticalValues.allSatisfy({ value in
                    guard let context = value.context else { return false }
                    return !context.isEmpty && context.contains(value.value)
                }) else {
                    throw BenchmarkError.invalidManifest(
                        "\(documentID) locked critical values need exact context containing the value."
                    )
                }
            }
        }
        let optionalThresholds = [
            groundTruth.minimumWordOrderF1,
            groundTruth.minimumTableCellF1,
            groundTruth.minimumCriticalValueAccuracy,
            groundTruth.minimumOCRRoutingF1,
        ].compactMap { $0 }
        guard optionalThresholds.allSatisfy({ (0...1).contains($0) }) else {
            throw BenchmarkError.invalidManifest(
                "\(documentID) optional quality thresholds must be between 0 and 1."
            )
        }
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
    let expectedPageCount: Int?
    let expectedOCRPages: [Int]?

    enum CodingKeys: String, CodingKey {
        case id
        case pdf
        case sha256
        case features
        case rawMarkdownSHA256 = "raw_markdown_sha256"
        case groundTruth = "ground_truth"
        case rights
        case expectedPageCount = "expected_page_count"
        case expectedOCRPages = "expected_ocr_pages"
    }
}

private struct GroundTruthMetadata: Codable, Sendable {
    let markdown: String
    let sha256: String
    let minimumTokenF1: Double
    let minimumStructureF1: Double
    let state: GroundTruthState?
    let authoringMethod: GroundTruthAuthoringMethod?
    let authoredWithoutDocumentKitOutput: Bool?
    let author: String?
    let reviewer: String?
    let reviewedAt: String?
    let criticalValues: [CriticalValue]?
    let minimumWordOrderF1: Double?
    let minimumTableCellF1: Double?
    let minimumCriticalValueAccuracy: Double?
    let minimumOCRRoutingF1: Double?

    // Schema v1 predates review-state provenance, so it is diagnostic only.
    var effectiveState: GroundTruthState { state ?? .draft }

    enum CodingKeys: String, CodingKey {
        case markdown
        case sha256
        case minimumTokenF1 = "minimum_token_f1"
        case minimumStructureF1 = "minimum_structure_f1"
        case state
        case authoringMethod = "authoring_method"
        case authoredWithoutDocumentKitOutput = "authored_without_documentkit_output"
        case author
        case reviewer
        case reviewedAt = "reviewed_at"
        case criticalValues = "critical_values"
        case minimumWordOrderF1 = "minimum_word_order_f1"
        case minimumTableCellF1 = "minimum_table_cell_f1"
        case minimumCriticalValueAccuracy = "minimum_critical_value_accuracy"
        case minimumOCRRoutingF1 = "minimum_ocr_routing_f1"
    }
}

private enum GroundTruthState: String, Codable, Sendable {
    case draft
    case reviewed
    case locked
}

private enum GroundTruthAuthoringMethod: String, Codable, Sendable {
    case sourceAuthored = "source-authored"
    case visualTranscription = "visual-transcription"
}

private struct CriticalValue: Codable, Sendable {
    let id: String
    let value: String
    let occurrences: Int
    let kind: String?
    let context: String?
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
    let expectedPageCount: Int?
    let expectedOCRPages: [Int]?
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
    let groundTruthState: GroundTruthState?
    let quality: QualityComparison?
    let pdfKitBaseline: PDFKitBaselineRecord
    let expectedPageCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case pdfPath = "pdf_path"
        case features
        case rightsStatus = "rights_status"
        case expectedPDFSHA256 = "expected_pdf_sha256"
        case observedPDFSHA256 = "observed_pdf_sha256"
        case preflightError = "preflight_error"
        case inspectRuns = "inspect_runs"
        case extractRuns = "extract_runs"
        case determinism
        case baseline
        case groundTruthExpected = "ground_truth_expected"
        case groundTruthState = "ground_truth_state"
        case quality
        case pdfKitBaseline = "pdfkit_baseline"
        case expectedPageCount = "expected_page_count"
    }

    var passed: Bool {
        preflightError == nil
            && inspectRuns.count > 1
            && extractRuns.count > 1
            && inspectRuns.allSatisfy { $0.error == nil }
            && extractRuns.allSatisfy { $0.error == nil }
            && determinism.passed
            && (baseline?.matches ?? true)
            && (!groundTruthExpected || quality != nil)
            && (quality?.requiredForPass != true || quality?.passes == true)
            && pdfKitBaseline.runs.count > 1
            && pdfKitBaseline.runs.allSatisfy { $0.error == nil }
            && pdfKitBaseline.deterministic
            && pageCountMatches
    }

    private var pageCountMatches: Bool {
        guard let expectedPageCount else { return true }
        return inspectRuns.compactMap(\.inspection).allSatisfy {
            $0.pageCount == expectedPageCount
        }
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
            groundTruthState: document.groundTruth?.metadata.effectiveState,
            quality: nil,
            pdfKitBaseline: .notRun,
            expectedPageCount: document.expectedPageCount
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

private struct WarningSnapshot: Codable, Equatable, Sendable {
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

private struct ExtractionFingerprint: Equatable, Sendable {
    let markdownSHA256: String
    let inspection: InspectionSnapshot
    let warnings: [WarningSnapshot]

    init?(_ run: ExtractRunRecord) {
        guard run.error == nil,
              let markdownSHA256 = run.markdownSHA256,
              let inspection = run.inspection else { return nil }
        self.markdownSHA256 = markdownSHA256
        self.inspection = inspection
        warnings = run.warnings
    }
}

private struct PDFKitBaselineRecord: Codable, Sendable {
    let supported: Bool
    let attempted: Bool
    let pageCount: Int?
    let textPath: String?
    let runs: [PDFKitRunRecord]
    let deterministic: Bool
    let quality: PDFKitQualityComparison?

    enum CodingKeys: String, CodingKey {
        case supported
        case attempted
        case pageCount = "page_count"
        case textPath = "text_path"
        case runs
        case deterministic
        case quality
    }

    static let notRun = PDFKitBaselineRecord(
        supported: false,
        attempted: false,
        pageCount: nil,
        textPath: nil,
        runs: [],
        deterministic: false,
        quality: nil
    )
}

private struct PDFKitRunRecord: Codable, Sendable {
    let run: Int
    let wallMilliseconds: Double
    let textSHA256: String?
    let textByteCount: Int?
    let error: ErrorRecord?

    enum CodingKeys: String, CodingKey {
        case run
        case wallMilliseconds = "wall_milliseconds"
        case textSHA256 = "text_sha256"
        case textByteCount = "text_byte_count"
        case error
    }
}

private struct PDFKitQualityComparison: Codable, Sendable {
    let contentPrecision: Double
    let contentRecall: Double
    let contentF1: Double
    let wordOrderBigramF1: Double
    let criticalValueAccuracy: Double?

    enum CodingKeys: String, CodingKey {
        case contentPrecision = "content_precision"
        case contentRecall = "content_recall"
        case contentF1 = "content_f1"
        case wordOrderBigramF1 = "word_order_bigram_f1"
        case criticalValueAccuracy = "critical_value_accuracy"
    }

    init(observed: String, groundTruth: PreparedGroundTruth) {
        let observedTokens = tokens(observed)
        let expectedTokens = tokens(groundTruth.markdown)
        let score = multisetScore(observedTokens, expectedTokens)
        contentPrecision = score.precision
        contentRecall = score.recall
        contentF1 = score.f1
        wordOrderBigramF1 = multisetF1(bigrams(observedTokens), bigrams(expectedTokens))
        let critical = (groundTruth.metadata.criticalValues ?? []).map {
            CriticalValueResult(expected: $0, observedMarkdown: observed).accuracy
        }
        criticalValueAccuracy = critical.isEmpty
            ? nil
            : critical.reduce(0, +) / Double(critical.count)
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
    let groundTruthState: GroundTruthState
    let requiredForPass: Bool
    let contentPrecision: Double
    let contentRecall: Double
    let tokenF1: Double
    let wordOrderBigramF1: Double
    let structureF1: Double
    let tableCellF1: Double?
    let criticalValueAccuracy: Double?
    let criticalValues: [CriticalValueResult]
    let ocrRouting: SetComparison?
    let minimumTokenF1: Double
    let minimumStructureF1: Double
    let minimumWordOrderF1: Double?
    let minimumTableCellF1: Double?
    let minimumCriticalValueAccuracy: Double?
    let minimumOCRRoutingF1: Double?
    let passes: Bool

    enum CodingKeys: String, CodingKey {
        case expectedMarkdownSHA256 = "expected_markdown_sha256"
        case observedMarkdownSHA256 = "observed_markdown_sha256"
        case exactMatch = "exact_match"
        case groundTruthState = "ground_truth_state"
        case requiredForPass = "required_for_pass"
        case contentPrecision = "content_precision"
        case contentRecall = "content_recall"
        case tokenF1 = "token_f1"
        case wordOrderBigramF1 = "word_order_bigram_f1"
        case structureF1 = "structure_f1"
        case tableCellF1 = "table_cell_f1"
        case criticalValueAccuracy = "critical_value_accuracy"
        case criticalValues = "critical_values"
        case ocrRouting = "ocr_routing"
        case minimumTokenF1 = "minimum_token_f1"
        case minimumStructureF1 = "minimum_structure_f1"
        case minimumWordOrderF1 = "minimum_word_order_f1"
        case minimumTableCellF1 = "minimum_table_cell_f1"
        case minimumCriticalValueAccuracy = "minimum_critical_value_accuracy"
        case minimumOCRRoutingF1 = "minimum_ocr_routing_f1"
        case passes
    }

    init(
        observed: String,
        groundTruth: PreparedGroundTruth,
        observedOCRPages: [Int]?,
        expectedOCRPages: [Int]?
    ) {
        let expectedData = Data(groundTruth.markdown.utf8)
        let observedData = Data(observed.utf8)
        let observedTokens = tokens(observed)
        let expectedTokens = tokens(groundTruth.markdown)
        let content = multisetScore(observedTokens, expectedTokens)
        expectedMarkdownSHA256 = digestSHA256(expectedData)
        observedMarkdownSHA256 = digestSHA256(observedData)
        exactMatch = expectedMarkdownSHA256 == observedMarkdownSHA256
        groundTruthState = groundTruth.metadata.effectiveState
        requiredForPass = groundTruthState == .locked
        contentPrecision = content.precision
        contentRecall = content.recall
        tokenF1 = content.f1
        wordOrderBigramF1 = multisetF1(bigrams(observedTokens), bigrams(expectedTokens))
        structureF1 = multisetF1(
            markdownStructure(observed),
            markdownStructure(groundTruth.markdown)
        )
        let expectedCells = markdownTableCells(groundTruth.markdown)
        tableCellF1 = expectedCells.isEmpty
            ? nil
            : multisetF1(markdownTableCells(observed), expectedCells)
        criticalValues = (groundTruth.metadata.criticalValues ?? []).map {
            CriticalValueResult(expected: $0, observedMarkdown: observed)
        }
        if criticalValues.isEmpty {
            criticalValueAccuracy = nil
        } else {
            criticalValueAccuracy = criticalValues.map(\.accuracy).reduce(0, +)
                / Double(criticalValues.count)
        }
        if let expectedOCRPages, let observedOCRPages {
            ocrRouting = SetComparison(
                observed: observedOCRPages,
                expected: expectedOCRPages
            )
        } else {
            ocrRouting = nil
        }
        minimumTokenF1 = groundTruth.metadata.minimumTokenF1
        minimumStructureF1 = groundTruth.metadata.minimumStructureF1
        minimumWordOrderF1 = groundTruth.metadata.minimumWordOrderF1
        minimumTableCellF1 = groundTruth.metadata.minimumTableCellF1
        minimumCriticalValueAccuracy = groundTruth.metadata.minimumCriticalValueAccuracy
        minimumOCRRoutingF1 = groundTruth.metadata.minimumOCRRoutingF1
        passes = tokenF1 >= minimumTokenF1
            && structureF1 >= minimumStructureF1
            && thresholdPasses(wordOrderBigramF1, minimum: minimumWordOrderF1)
            && thresholdPasses(tableCellF1, minimum: minimumTableCellF1)
            && thresholdPasses(criticalValueAccuracy, minimum: minimumCriticalValueAccuracy)
            && thresholdPasses(ocrRouting?.f1, minimum: minimumOCRRoutingF1)
    }
}

private struct CriticalValueResult: Codable, Sendable {
    let id: String
    let kind: String?
    let value: String
    let expectedOccurrences: Int
    let observedOccurrences: Int
    let expectedContext: String?
    let observedContextOccurrences: Int?
    let accuracy: Double

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case value
        case expectedOccurrences = "expected_occurrences"
        case observedOccurrences = "observed_occurrences"
        case expectedContext = "expected_context"
        case observedContextOccurrences = "observed_context_occurrences"
        case accuracy
    }

    init(expected: CriticalValue, observedMarkdown: String) {
        id = expected.id
        kind = expected.kind
        value = expected.value
        expectedOccurrences = expected.occurrences
        observedOccurrences = literalOccurrenceCount(of: expected.value, in: observedMarkdown)
        expectedContext = expected.context
        observedContextOccurrences = expected.context.map {
            literalOccurrenceCount(of: $0, in: observedMarkdown)
        }
        accuracy = observedOccurrences == expectedOccurrences
            && (observedContextOccurrences == nil
                || observedContextOccurrences == expectedOccurrences)
            ? 1
            : 0
    }
}

private struct SetComparison: Codable, Sendable {
    let expected: [Int]
    let observed: [Int]
    let precision: Double
    let recall: Double
    let f1: Double
    let exactMatch: Bool

    enum CodingKeys: String, CodingKey {
        case expected
        case observed
        case precision
        case recall
        case f1
        case exactMatch = "exact_match"
    }

    init(observed: [Int], expected: [Int]) {
        self.expected = expected.sorted()
        self.observed = observed.sorted()
        let observedSet = Set(observed)
        let expectedSet = Set(expected)
        let matches = observedSet.intersection(expectedSet).count
        precision = observedSet.isEmpty
            ? (expectedSet.isEmpty ? 1 : 0)
            : Double(matches) / Double(observedSet.count)
        recall = expectedSet.isEmpty
            ? (observedSet.isEmpty ? 1 : 0)
            : Double(matches) / Double(expectedSet.count)
        f1 = harmonicMean(precision, recall)
        exactMatch = observedSet == expectedSet
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
            case .invalidPageSelection:
                self.init(code: "invalid_page_selection", message: error.localizedDescription)
            case .pageOutOfRange:
                self.init(code: "page_out_of_range", message: error.localizedDescription)
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
    let warmups: Int
    let elapsedMilliseconds: Double
    let environment: BenchmarkEnvironment
    let counts: Counts
    let timing: TimingSummary
    let quality: QualitySummary
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
        case warmups
        case elapsedMilliseconds = "elapsed_milliseconds"
        case environment
        case counts
        case timing
        case quality
        case documents
    }

    init(
        manifestSHA256: String,
        manifestPath: String,
        corpus: CorpusMetadata,
        rawEngineBaseline: RawEngineBaseline?,
        repetitions: Int,
        warmups: Int,
        elapsedMilliseconds: Double,
        records: [DocumentResultRecord]
    ) {
        schemaVersion = 2
        passed = records.allSatisfy(\.passed)
        status = passed ? "passed" : "failed"
        self.manifestSHA256 = manifestSHA256
        self.manifestPath = manifestPath
        self.corpus = corpus
        self.rawEngineBaseline = rawEngineBaseline
        self.repetitions = repetitions
        self.warmups = warmups
        self.elapsedMilliseconds = elapsedMilliseconds
        environment = BenchmarkEnvironment(records: records)
        counts = Counts(records)
        timing = TimingSummary(records)
        quality = QualitySummary(records)
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
    let engineFailures: Int
    let pdfKitFailures: Int
    let lockedGroundTruthDocuments: Int
    let scoredLockedGroundTruthDocuments: Int
    let failedLockedGroundTruthDocuments: Int

    enum CodingKeys: String, CodingKey {
        case totalDocuments = "total_documents"
        case passedDocuments = "passed_documents"
        case failedDocuments = "failed_documents"
        case nondeterministicDocuments = "nondeterministic_documents"
        case baselineMismatches = "baseline_mismatches"
        case qualityFailures = "quality_failures"
        case engineFailures = "engine_failures"
        case pdfKitFailures = "pdfkit_failures"
        case lockedGroundTruthDocuments = "locked_ground_truth_documents"
        case scoredLockedGroundTruthDocuments = "scored_locked_ground_truth_documents"
        case failedLockedGroundTruthDocuments = "failed_locked_ground_truth_documents"
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
            $0.quality?.requiredForPass == true && $0.quality?.passes == false
        })
        engineFailures = records.count(where: {
            $0.preflightError != nil
                || $0.inspectRuns.contains(where: { $0.error != nil })
                || $0.extractRuns.contains(where: { $0.error != nil })
        })
        pdfKitFailures = records.count(where: {
            $0.pdfKitBaseline.runs.contains(where: { $0.error != nil })
        })
        lockedGroundTruthDocuments = records.count(where: { $0.groundTruthState == .locked })
        scoredLockedGroundTruthDocuments = records.count(where: {
            $0.groundTruthState == .locked && $0.quality != nil
        })
        failedLockedGroundTruthDocuments =
            lockedGroundTruthDocuments - scoredLockedGroundTruthDocuments
    }
}

private struct TimingSummary: Codable, Sendable {
    let inspect: TimingAggregate
    let extract: TimingAggregate
    let pdfKit: TimingAggregate
    let eligibility: String

    init(_ records: [DocumentResultRecord]) {
        let eligible = records.filter(\.passed)
        inspect = TimingAggregate(
            eligible.flatMap { record in
                let pages = record.inspectRuns.first?.inspection?.pageCount
                    ?? record.expectedPageCount
                return record.inspectRuns.compactMap {
                    $0.error == nil ? TimingSample(milliseconds: $0.wallMilliseconds, pages: pages) : nil
                }
            }
        )
        extract = TimingAggregate(
            eligible.flatMap { record in
                let pages = record.extractRuns.first?.inspection?.pageCount
                    ?? record.expectedPageCount
                return record.extractRuns.compactMap {
                    $0.error == nil ? TimingSample(milliseconds: $0.wallMilliseconds, pages: pages) : nil
                }
            }
        )
        pdfKit = TimingAggregate(
            eligible.flatMap { record in
                record.pdfKitBaseline.runs.compactMap {
                    $0.error == nil
                        ? TimingSample(
                            milliseconds: $0.wallMilliseconds,
                            pages: record.pdfKitBaseline.pageCount
                        )
                        : nil
                }
            }
        )
        eligibility = "Only documents passing execution, determinism, parity, and any applicable locked quality gates contribute."
    }
}

private struct TimingAggregate: Codable, Sendable {
    let samples: Int
    let totalMilliseconds: Double
    let p50Milliseconds: Double?
    let p95Milliseconds: Double?
    let p50MillisecondsPerPage: Double?
    let p95MillisecondsPerPage: Double?
    let aggregatePagesPerSecond: Double?

    enum CodingKeys: String, CodingKey {
        case samples
        case totalMilliseconds = "total_milliseconds"
        case p50Milliseconds = "p50_milliseconds"
        case p95Milliseconds = "p95_milliseconds"
        case p50MillisecondsPerPage = "p50_milliseconds_per_page"
        case p95MillisecondsPerPage = "p95_milliseconds_per_page"
        case aggregatePagesPerSecond = "aggregate_pages_per_second"
    }

    init(_ samples: [TimingSample]) {
        self.samples = samples.count
        let milliseconds = samples.map(\.milliseconds)
        totalMilliseconds = milliseconds.reduce(0, +)
        p50Milliseconds = percentile(milliseconds, 0.50)
        p95Milliseconds = percentile(milliseconds, 0.95)
        let perPage = samples.compactMap { sample -> Double? in
            guard let pages = sample.pages, pages > 0 else { return nil }
            return sample.milliseconds / Double(pages)
        }
        p50MillisecondsPerPage = percentile(perPage, 0.50)
        p95MillisecondsPerPage = percentile(perPage, 0.95)
        let totalPages = samples.compactMap(\.pages).reduce(0, +)
        aggregatePagesPerSecond = totalMilliseconds > 0 && totalPages > 0
            ? Double(totalPages) / (totalMilliseconds / 1_000)
            : nil
    }
}

private struct TimingSample: Sendable {
    let milliseconds: Double
    let pages: Int?
}

private struct QualitySummary: Codable, Sendable {
    let expectedLockedDocuments: Int
    let scoredLockedDocuments: Int
    let failedLockedDocuments: Int
    let contentF1Macro: Double?
    let wordOrderBigramF1Macro: Double?
    let structureF1Macro: Double?
    let tableCellF1Macro: Double?
    let tableDocuments: Int
    let criticalValueAccuracyMacro: Double?
    let criticalValueDocuments: Int
    let ocrRoutingF1Macro: Double?
    let ocrRoutingDocuments: Int

    enum CodingKeys: String, CodingKey {
        case expectedLockedDocuments = "expected_locked_documents"
        case scoredLockedDocuments = "scored_locked_documents"
        case failedLockedDocuments = "failed_locked_documents"
        case contentF1Macro = "content_f1_macro"
        case wordOrderBigramF1Macro = "word_order_bigram_f1_macro"
        case structureF1Macro = "structure_f1_macro"
        case tableCellF1Macro = "table_cell_f1_macro"
        case tableDocuments = "table_documents"
        case criticalValueAccuracyMacro = "critical_value_accuracy_macro"
        case criticalValueDocuments = "critical_value_documents"
        case ocrRoutingF1Macro = "ocr_routing_f1_macro"
        case ocrRoutingDocuments = "ocr_routing_documents"
    }

    init(_ records: [DocumentResultRecord]) {
        let locked = records.compactMap(\.quality).filter(\.requiredForPass)
        expectedLockedDocuments = records.count(where: { $0.groundTruthState == .locked })
        scoredLockedDocuments = locked.count
        failedLockedDocuments = expectedLockedDocuments - scoredLockedDocuments
        contentF1Macro = mean(locked.map(\.tokenF1))
        wordOrderBigramF1Macro = mean(locked.map(\.wordOrderBigramF1))
        structureF1Macro = mean(locked.map(\.structureF1))
        let tableScores = locked.compactMap(\.tableCellF1)
        tableDocuments = tableScores.count
        tableCellF1Macro = mean(tableScores)
        let criticalScores = locked.compactMap(\.criticalValueAccuracy)
        criticalValueDocuments = criticalScores.count
        criticalValueAccuracyMacro = mean(criticalScores)
        let ocrScores = locked.compactMap { $0.ocrRouting?.f1 }
        ocrRoutingDocuments = ocrScores.count
        ocrRoutingF1Macro = mean(ocrScores)
    }
}

private struct BenchmarkEnvironment: Codable, Sendable {
    let buildConfiguration: String
    let operatingSystem: String
    let architecture: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let sourceRevision: String?
    let developerDirectory: String?
    let xcodeVersion: String?
    let swiftVersion: String?
    let engineVersions: [String]

    enum CodingKeys: String, CodingKey {
        case buildConfiguration = "build_configuration"
        case operatingSystem = "operating_system"
        case architecture
        case processorCount = "processor_count"
        case physicalMemoryBytes = "physical_memory_bytes"
        case sourceRevision = "source_revision"
        case developerDirectory = "developer_directory"
        case xcodeVersion = "xcode_version"
        case swiftVersion = "swift_version"
        case engineVersions = "engine_versions"
    }

    init(records: [DocumentResultRecord]) {
        buildConfiguration = benchmarkBuildConfiguration
        operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        architecture = executableArchitecture
        processorCount = ProcessInfo.processInfo.processorCount
        physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        sourceRevision = ProcessInfo.processInfo.environment["DOCUMENTKIT_BENCHMARK_SOURCE_REVISION"]
        developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        xcodeVersion = commandOutput("/usr/bin/xcodebuild", ["-version"])
        swiftVersion = commandOutput("/usr/bin/xcrun", ["swift", "--version"])
        engineVersions = Array(
            Set(
                records.flatMap { record in
                    record.inspectRuns.compactMap { $0.inspection?.engineVersion }
                }
            )
        ).sorted()
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
    let wordOrderBigramF1: Double?
    let tableCellF1: Double?
    let criticalValueAccuracy: Double?
    let ocrRoutingF1: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case passed
        case resultPath = "result_path"
        case markdownSHA256 = "markdown_sha256"
        case baselineMatches = "baseline_matches"
        case qualityPasses = "quality_passes"
        case tokenF1 = "token_f1"
        case structureF1 = "structure_f1"
        case wordOrderBigramF1 = "word_order_bigram_f1"
        case tableCellF1 = "table_cell_f1"
        case criticalValueAccuracy = "critical_value_accuracy"
        case ocrRoutingF1 = "ocr_routing_f1"
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
        wordOrderBigramF1 = record.quality?.wordOrderBigramF1
        tableCellF1 = record.quality?.tableCellF1
        criticalValueAccuracy = record.quality?.criticalValueAccuracy
        ocrRoutingF1 = record.quality?.ocrRouting?.f1
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

    let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    let candidate = root
        .appendingPathComponent(path)
        .standardizedFileURL
        .resolvingSymlinksInPath()
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

private var benchmarkBuildConfiguration: String {
    #if DOCUMENTKIT_BENCHMARK_RELEASE
    "release"
    #else
    "debug"
    #endif
}

private var executableArchitecture: String {
    #if arch(arm64)
    "arm64"
    #elseif arch(x86_64)
    "x86_64"
    #else
    "unknown"
    #endif
}

private func isISODate(_ value: String) -> Bool {
    guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
        return false
    }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: value) else { return false }
    return formatter.string(from: date) == value
}

private func validateCanonicalMarkdown(_ markdown: String, documentID: String) throws {
    let hasTrailingWhitespace = markdown
        .split(separator: "\n", omittingEmptySubsequences: false)
        .contains { $0.last == " " || $0.last == "\t" }
    guard !markdown.contains("\r"),
          !markdown.contains("\0"),
          !markdown.contains("\t"),
          !hasTrailingWhitespace,
          !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          markdown == markdown.precomposedStringWithCanonicalMapping,
          markdown.hasSuffix("\n"),
          !markdown.hasSuffix("\n\n") else {
        throw BenchmarkError.invalidManifest(
            "\(documentID) ground truth violates the canonical Markdown file-normalization rules."
        )
    }
}

private enum PDFKitBaselineError: Error, LocalizedError {
    case invalidPDF

    var errorDescription: String? { "PDFKit could not open the PDF." }
}

private func pdfKitText(from data: Data) throws -> (text: String, pageCount: Int) {
    guard let document = PDFDocument(data: data) else {
        throw PDFKitBaselineError.invalidPDF
    }
    let pages = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    return (pages.joined(separator: "\n\n"), document.pageCount)
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

private func bigrams(_ values: [String]) -> [String] {
    guard values.count >= 2 else { return [] }
    return zip(values, values.dropFirst()).map { "\($0)\u{001F}\($1)" }
}

private func markdownTableCells(_ markdown: String) -> [String] {
    let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var cells: [String] = []
    var index = 0
    while index + 1 < lines.count {
        let header = splitMarkdownTableRow(lines[index])
        let delimiter = splitMarkdownTableRow(lines[index + 1])
        guard !header.isEmpty,
              header.count == delimiter.count,
              delimiter.allSatisfy(isTableDelimiter) else {
            index += 1
            continue
        }
        cells.append(contentsOf: header.map(normalizedCell))
        index += 2
        while index < lines.count {
            let row = splitMarkdownTableRow(lines[index])
            guard row.count == header.count else { break }
            cells.append(contentsOf: row.map(normalizedCell))
            index += 1
        }
    }
    return cells
}

private func splitMarkdownTableRow(_ line: String) -> [String] {
    guard line.contains("|") else { return [] }
    var cells: [String] = []
    var current = ""
    var escaped = false
    for character in line {
        if escaped {
            current.append(character)
            escaped = false
        } else if character == "\\" {
            escaped = true
            current.append(character)
        } else if character == "|" {
            cells.append(current)
            current = ""
        } else {
            current.append(character)
        }
    }
    cells.append(current)
    if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") { cells.removeFirst() }
    if line.trimmingCharacters(in: .whitespaces).hasSuffix("|") { cells.removeLast() }
    return cells.map { $0.trimmingCharacters(in: .whitespaces) }
}

private func isTableDelimiter(_ cell: String) -> Bool {
    cell.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
}

private func normalizedCell(_ cell: String) -> String {
    cell.precomposedStringWithCanonicalMapping
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
}

private struct MatchScore {
    let precision: Double
    let recall: Double
    let f1: Double
}

private func multisetScore<T: Hashable>(_ observed: [T], _ expected: [T]) -> MatchScore {
    if observed.isEmpty && expected.isEmpty {
        return MatchScore(precision: 1, recall: 1, f1: 1)
    }
    guard !observed.isEmpty, !expected.isEmpty else {
        return MatchScore(precision: 0, recall: 0, f1: 0)
    }
    var remaining = Dictionary(grouping: expected, by: { $0 }).mapValues(\.count)
    var matches = 0
    for value in observed where remaining[value, default: 0] > 0 {
        matches += 1
        remaining[value, default: 0] -= 1
    }
    let precision = Double(matches) / Double(observed.count)
    let recall = Double(matches) / Double(expected.count)
    return MatchScore(precision: precision, recall: recall, f1: harmonicMean(precision, recall))
}

private func multisetF1(_ observed: [String], _ expected: [String]) -> Double {
    multisetScore(observed, expected).f1
}

private func harmonicMean(_ precision: Double, _ recall: Double) -> Double {
    guard precision + recall > 0 else { return 0 }
    return 2 * precision * recall / (precision + recall)
}

private func literalOccurrenceCount(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var range = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, range: range) {
        count += 1
        range = found.upperBound..<haystack.endIndex
    }
    return count
}

private func thresholdPasses(_ value: Double?, minimum: Double?) -> Bool {
    guard let minimum else { return true }
    guard let value else { return false }
    return value >= minimum
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let position = fraction * Double(sorted.count - 1)
    let lower = Int(floor(position))
    let upper = Int(ceil(position))
    if lower == upper { return sorted[lower] }
    let weight = position - Double(lower)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
}

private func mean(_ values: [Double]) -> Double? {
    values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
}

private func commandOutput(_ executable: String, _ arguments: [String]) -> String? {
    #if os(macOS)
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    } catch {
        return nil
    }
    #else
    return nil
    #endif
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
