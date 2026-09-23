import DocumentKitCore
import Foundation

/// Inspects local PDFs and extracts their embedded text as Markdown or a
/// structured document.
///
/// Turnip does not upload documents or perform OCR. Use ``inspect(_:)``
/// to decide how to route a PDF, or ``extract(_:)`` when the app needs
/// Markdown, or ``extractDocument(_:)`` when the app needs source structure.
public enum Turnip {
    /// The largest PDF input accepted by the public API, in bytes.
    ///
    /// Inputs larger than this limit throw ``TurnipError/inputTooLarge(maximumBytes:)``.
    public static let maximumInputSize = 100 * 1024 * 1024

    /// The pinned upstream engine source revision embedded in the packaged binary.
    ///
    /// This identifies the upstream source commit. It does not include the
    /// hash of Turnip's tracked Apple patch.
    public static let engineRevision = String(cString: documentkit_engine_revision())

    /// Inspects PDF data without producing Markdown.
    ///
    /// - Parameter data: The complete PDF data to inspect.
    /// - Returns: Classification and OCR-routing information for the PDF.
    /// - Throws: A ``TurnipError`` when the input cannot be inspected.
    public static func inspect(_ data: Data) async throws -> DocumentInspection {
        try await inspect(data, options: DocumentOptions())
    }

    /// Inspects selected pages of PDF data without producing Markdown.
    ///
    /// - Parameters:
    ///   - data: The complete PDF data to inspect.
    ///   - options: Page-selection and password options.
    /// - Returns: Classification and OCR-routing information for the PDF.
    /// - Throws: A ``TurnipError`` when the input or options are invalid.
    public static func inspect(
        _ data: Data,
        options: DocumentOptions
    ) async throws -> DocumentInspection {
        let payload = try await Engine.run(.inspect, data: data, options: options)
        return payload.inspection
    }

    /// Inspects a PDF at a file URL without producing Markdown.
    ///
    /// Turnip checks available file-size metadata before reading and enforces
    /// the input limit after loading.
    ///
    /// - Parameter url: The URL of a local PDF file.
    /// - Returns: Classification and OCR-routing information for the PDF.
    /// - Throws: A ``TurnipError`` for validation or inspection failures,
    ///   file or resource-loading errors, or `CancellationError` if the task is cancelled.
    public static func inspect(contentsOf url: URL) async throws -> DocumentInspection {
        try await inspect(load(url))
    }

    /// Inspects selected pages of a PDF at a file URL without producing Markdown.
    ///
    /// - Parameters:
    ///   - url: The URL of a local PDF file.
    ///   - options: Page-selection and password options.
    /// - Returns: Classification and OCR-routing information for the PDF.
    /// - Throws: A ``TurnipError`` for validation or inspection failures,
    ///   file or resource-loading errors, or `CancellationError` if the task is cancelled.
    public static func inspect(
        contentsOf url: URL,
        options: DocumentOptions
    ) async throws -> DocumentInspection {
        try await inspect(load(url), options: options)
    }

    /// Extracts Markdown from PDF data.
    ///
    /// The result also contains inspection information and warnings from the
    /// same engine pass.
    ///
    /// - Parameter data: The complete PDF data to extract.
    /// - Returns: Markdown together with inspection information and warnings.
    /// - Throws: A ``TurnipError`` when the input is invalid or has no extractable text.
    public static func extract(_ data: Data) async throws -> DocumentExtraction {
        try await extract(data, options: DocumentOptions())
    }

    /// Extracts Markdown from selected pages of PDF data.
    ///
    /// - Parameters:
    ///   - data: The complete PDF data to extract.
    ///   - options: Page-selection and password options.
    /// - Returns: Markdown together with inspection information and warnings.
    /// - Throws: A ``TurnipError`` when the input or options are invalid,
    ///   or when the selection has no extractable text.
    public static func extract(
        _ data: Data,
        options: DocumentOptions
    ) async throws -> DocumentExtraction {
        let payload = try await Engine.run(.extract, data: data, options: options)
        guard let markdown = payload.markdown, !markdown.isEmpty else {
            throw TurnipError.noExtractableText(payload.inspection)
        }
        return DocumentExtraction(
            markdown: markdown,
            inspection: payload.inspection,
            warnings: payload.warnings
        )
    }

    /// Extracts Markdown from a PDF at a file URL.
    ///
    /// Turnip checks available file-size metadata before reading and enforces
    /// the input limit after loading.
    ///
    /// - Parameter url: The URL of a local PDF file.
    /// - Returns: Markdown together with inspection information and warnings.
    /// - Throws: A ``TurnipError`` for validation or extraction failures,
    ///   file or resource-loading errors, or `CancellationError` if the task is cancelled.
    public static func extract(contentsOf url: URL) async throws -> DocumentExtraction {
        try await extract(load(url))
    }

    /// Extracts Markdown from selected pages of a PDF at a file URL.
    ///
    /// - Parameters:
    ///   - url: The URL of a local PDF file.
    ///   - options: Page-selection and password options.
    /// - Returns: Markdown together with inspection information and warnings.
    /// - Throws: A ``TurnipError`` for validation or extraction failures,
    ///   file or resource-loading errors, or `CancellationError` if the task is cancelled.
    public static func extract(
        contentsOf url: URL,
        options: DocumentOptions
    ) async throws -> DocumentExtraction {
        try await extract(load(url), options: options)
    }

    /// Extracts a typed, versioned document from PDF data.
    ///
    /// The result preserves every requested page, text and table blocks in
    /// inferred reading order, source lines and available geometry. Pages that
    /// need OCR remain present with an explicit status; Turnip does not perform
    /// OCR.
    ///
    /// - Parameter data: The complete PDF data to extract.
    /// - Returns: A structured document together with inspection data and warnings.
    /// - Throws: A ``TurnipError`` when the input or document is invalid.
    public static func extractDocument(_ data: Data) async throws -> ExtractedDocument {
        try await extractDocument(data, options: DocumentOptions())
    }

    /// Extracts a typed, versioned document from selected pages of PDF data.
    ///
    /// - Parameters:
    ///   - data: The complete PDF data to extract.
    ///   - options: Page-selection and password options.
    /// - Returns: A structured document whose pages retain their original
    ///   zero-based PDF indexes.
    /// - Throws: A ``TurnipError`` when the input or options are invalid.
    public static func extractDocument(
        _ data: Data,
        options: DocumentOptions
    ) async throws -> ExtractedDocument {
        let payload = try await Engine.run(.document, data: data, options: options)
        guard let document = payload.document else {
            throw TurnipError.engineFailure(
                code: "invalid_response",
                message: "The PDF engine returned no structured document."
            )
        }
        return document
    }

    /// Extracts a typed, versioned document from a PDF at a file URL.
    ///
    /// Turnip checks available file-size metadata before reading and enforces
    /// the input limit after loading.
    ///
    /// - Parameter url: The URL of a local PDF file.
    /// - Returns: A structured document together with inspection data and warnings.
    /// - Throws: A ``TurnipError`` for validation or extraction failures,
    ///   file or resource-loading errors, or `CancellationError` if the task is cancelled.
    public static func extractDocument(contentsOf url: URL) async throws -> ExtractedDocument {
        try await extractDocument(load(url))
    }

    /// Extracts a typed, versioned document from selected pages of a PDF at a file URL.
    ///
    /// - Parameters:
    ///   - url: The URL of a local PDF file.
    ///   - options: Page-selection and password options.
    /// - Returns: A structured document whose pages retain their original
    ///   zero-based PDF indexes.
    /// - Throws: A ``TurnipError`` for validation or extraction failures,
    ///   file or resource-loading errors, or `CancellationError` if the task is cancelled.
    public static func extractDocument(
        contentsOf url: URL,
        options: DocumentOptions
    ) async throws -> ExtractedDocument {
        try await extractDocument(load(url), options: options)
    }

    private static func load(_ url: URL) async throws -> Data {
        let task = Task.detached(priority: nil) {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values.fileSize, fileSize > maximumInputSize {
                throw TurnipError.inputTooLarge(maximumBytes: maximumInputSize)
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            try Task.checkCancellation()
            return data
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }
}

/// Options shared by PDF inspection, Markdown extraction, and structured extraction.
///
/// `pageIndexes` are zero-based, strictly ascending, unique, and nonempty.
/// `nil` processes the entire PDF; selected pages are emitted in document order.
/// Passwords are passed to the engine and redacted from descriptions and
/// reflection.
public struct DocumentOptions: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// Zero-based PDF page indexes to process, or `nil` for the entire document.
    public let pageIndexes: [Int]?
    private let passwordStorage: String?

    /// Creates options for inspection or either extraction API.
    ///
    /// - Parameters:
    ///   - pageIndexes: Zero-based, unique, nonempty indexes in strictly
    ///     ascending document order. Pass `nil` to process every page.
    ///   - password: A password for an encrypted PDF. Turnip passes it to the
    ///     native call and redacts it from public descriptions.
    public init(pageIndexes: [Int]? = nil, password: String? = nil) {
        self.pageIndexes = pageIndexes
        passwordStorage = password
    }

    /// A diagnostic description that redacts any supplied password.
    public var description: String {
        "DocumentOptions(pageIndexes: \(pageIndexes.map { String(describing: $0) } ?? "all"), password: \(passwordStorage == nil ? "nil" : "[REDACTED]"))"
    }

    /// A diagnostic description that redacts any supplied password.
    public var debugDescription: String { description }

    /// A reflection mirror that redacts any supplied password.
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "pageIndexes": pageIndexes as Any,
                "password": passwordStorage == nil ? "nil" : "[REDACTED]",
            ],
            displayStyle: .struct
        )
    }

    fileprivate var enginePassword: String? { passwordStorage }

    fileprivate func validatedPageIndexes() throws -> [UInt32]? {
        guard let pageIndexes else { return nil }
        guard !pageIndexes.isEmpty else {
            throw TurnipError.invalidPageSelection(.empty)
        }

        var seen = Set<Int>()
        for pageIndex in pageIndexes {
            guard pageIndex >= 0 else {
                throw TurnipError.invalidPageSelection(.negative(pageIndex: pageIndex))
            }
            guard let value = UInt32(exactly: pageIndex), value < UInt32.max else {
                throw TurnipError.invalidPageSelection(.exceedsEngineLimit(pageIndex: pageIndex))
            }
            guard seen.insert(pageIndex).inserted else {
                throw TurnipError.invalidPageSelection(.duplicate(pageIndex: pageIndex))
            }
        }
        guard zip(pageIndexes, pageIndexes.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
            throw TurnipError.invalidPageSelection(.notAscending)
        }
        return pageIndexes.map { UInt32($0) }
    }
}

/// Markdown produced from a PDF together with its inspection data and warnings.
public struct DocumentExtraction: Sendable, Hashable {
    /// The extracted Markdown in source-document order.
    public let markdown: String

    /// Information collected during the same extraction pass.
    public let inspection: DocumentInspection

    /// Extraction-quality warnings that callers should preserve with the result.
    public let warnings: [DocumentWarning]
}

/// Classification, routing, and quality information reported for a PDF.
///
/// ``Turnip/inspect(_:)`` returns the detect-only subset. Its ``layout``
/// and ``hasEncodingIssues`` values are `nil` because full extraction is not run.
public struct DocumentInspection: Sendable, Hashable {
    /// The engine's classification of the source PDF.
    public let kind: DocumentKind

    /// Total pages in the source PDF, including pages outside a selection.
    public let pageCount: Int

    /// The PDF title metadata, when present.
    public let title: String?

    /// The engine's classification confidence. It is not a correctness guarantee.
    public let confidence: Float

    /// The duration reported by the engine for this operation.
    public let processingTime: Duration

    /// Zero-based pages the engine recommends routing through OCR.
    public let pagesNeedingOCR: [Int]

    /// The zero-based pages and signals that led the engine to recommend OCR.
    public let ocrReasonsByPage: [PageOCRReasons]

    /// Layout analysis from a full extraction, or `nil` for detect-only inspection.
    public let layout: DocumentLayout?

    /// Whether extraction found encoding issues, or `nil` for a detect-only inspection.
    public let hasEncodingIssues: Bool?

    /// The engine version and embedded upstream source revision used for this result.
    public let engineVersion: String
}

/// The engine's classification of a PDF's content.
public enum DocumentKind: String, Codable, Sendable, Hashable {
    /// The engine classified the PDF as text-based.
    case textBased = "text_based"

    /// The engine classified the PDF as scanned.
    case scanned

    /// The engine classified the PDF as image-based.
    case imageBased = "image_based"

    /// The engine classified the PDF as mixed.
    case mixed
}

/// Layout information found during a full extraction pass.
public struct DocumentLayout: Sendable, Hashable {
    /// Whether the engine identified a complex layout.
    public let isComplex: Bool

    /// Zero-based pages that contain tables.
    public let pagesWithTables: [Int]

    /// Zero-based pages that contain columns.
    public let pagesWithColumns: [Int]
}

/// The signals that made the engine recommend OCR for one page.
public struct PageOCRReasons: Sendable, Hashable {
    /// The zero-based page index.
    public let pageIndex: Int

    /// Engine-provided reasons for the OCR recommendation.
    public let reasons: [String]
}

/// A quality warning returned with an extraction.
public struct DocumentWarning: Sendable, Hashable {
    /// The category of extraction-quality warning.
    public enum Kind: Codable, Sendable, Hashable {
        /// The engine recommends OCR for one or more pages.
        case ocrRequired

        /// The engine found text-encoding issues during extraction.
        case encodingIssues

        /// A warning code added by a newer encoder.
        ///
        /// Unknown codes remain available during JSON round-tripping so a
        /// consumer does not silently discard advisory extraction evidence.
        case unknown(String)
    }

    /// The warning category.
    public let kind: Kind

    /// Zero-based pages with page-local warning evidence.
    ///
    /// An empty list means the engine could not localize a document-level
    /// warning. It does not mean every requested page.
    public let pageIndexes: [Int]
}

/// Returns the pages whose OCR metadata explicitly identifies garbled text.
///
/// Encoding warnings do not have a native page list of their own. Keep the
/// association empty when the engine only reports a document-level encoding
/// problem rather than attributing it to a page-local OCR reason.
internal func encodingIssuePageIndexes(from reasonsByPage: [PageOCRReasons]) -> [Int] {
    reasonsByPage
        .filter { $0.reasons.contains("suspected_garbled_text") }
        .map(\.pageIndex)
}

/// Errors returned by PDF inspection and extraction.
public enum TurnipError: Error, Sendable, Hashable {
    /// The input data is empty.
    case emptyInput

    /// The input exceeds ``Turnip/maximumInputSize``.
    case inputTooLarge(maximumBytes: Int)

    /// The PDF is encrypted and the password is missing or incorrect.
    case encryptedPDF

    /// The requested page selection is invalid.
    case invalidPageSelection(PageSelectionError)

    /// A selected page is outside the source PDF's page range.
    case pageOutOfRange(pageIndex: Int, pageCount: Int)

    /// The input cannot be parsed as a PDF.
    case invalidPDF

    /// The PDF has no embedded text to extract. The associated inspection explains why.
    case noExtractableText(DocumentInspection)

    /// The underlying engine returned an unexpected failure.
    case engineFailure(code: String, message: String)
}

extension TurnipError: LocalizedError {
    /// A user-readable description of this error.
    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            "The PDF is empty."
        case let .inputTooLarge(maximumBytes):
            "The PDF exceeds the \(maximumBytes / 1024 / 1024) MiB limit."
        case .encryptedPDF:
            "The PDF requires a password, or the supplied password is incorrect."
        case let .invalidPageSelection(reason):
            reason.errorDescription
        case let .pageOutOfRange(pageIndex, pageCount):
            "Page index \(pageIndex) is outside the PDF's \(pageCount) pages."
        case .invalidPDF:
            "The file is not a valid PDF."
        case .noExtractableText:
            "The PDF has no extractable text. OCR may be required."
        case let .engineFailure(_, message):
            message
        }
    }
}

/// Errors in a ``DocumentOptions/pageIndexes`` selection.
public enum PageSelectionError: Sendable, Hashable {
    /// The selection contains no pages.
    case empty

    /// The selection contains a negative zero-based page index.
    case negative(pageIndex: Int)

    /// The selection contains the same zero-based page index more than once.
    case duplicate(pageIndex: Int)

    /// The selection is not in strictly ascending document order.
    case notAscending

    /// The selection contains a page index the native engine cannot represent.
    case exceedsEngineLimit(pageIndex: Int)

    fileprivate var errorDescription: String {
        switch self {
        case .empty:
            "Select at least one page, or use nil to process the entire PDF."
        case let .negative(pageIndex):
            "Page index \(pageIndex) is negative. Page indexes are zero-based."
        case let .duplicate(pageIndex):
            "Page index \(pageIndex) is selected more than once."
        case .notAscending:
            "Page indexes must be in strictly ascending document order."
        case let .exceedsEngineLimit(pageIndex):
            "Page index \(pageIndex) exceeds the supported page-index range."
        }
    }
}

private enum EngineOperation: Sendable, Equatable {
    case inspect
    case extract
    case document
}

private enum Engine {
    static func run(
        _ operation: EngineOperation,
        data: Data,
        options: DocumentOptions
    ) async throws -> Payload {
        guard !data.isEmpty else { throw TurnipError.emptyInput }
        guard data.count <= Turnip.maximumInputSize else {
            throw TurnipError.inputTooLarge(maximumBytes: Turnip.maximumInputSize)
        }

        let pageIndexes = try options.validatedPageIndexes()
        let task = Task.detached(priority: nil) {
            try Task.checkCancellation()
            let response: WireResponse = try call(
                operation,
                data: data,
                pageIndexes: pageIndexes,
                password: options.enginePassword
            )
            try Task.checkCancellation()
            return try Payload(
                response: response,
                operation: operation,
                selectedPageIndexes: pageIndexes?.map(Int.init)
            )
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    private static func call(
        _ operation: EngineOperation,
        data: Data,
        pageIndexes: [UInt32]?,
        password: String?
    ) throws -> WireResponse {
        let pages = pageIndexes ?? []
        let passwordBytes = password.map { Array($0.utf8) } ?? []
        let buffer = data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return pages.withUnsafeBufferPointer { pageBuffer in
                passwordBytes.withUnsafeBufferPointer { passwordBuffer in
                    switch operation {
                    case .inspect:
                        documentkit_inspect_with_options(
                            bytes.baseAddress,
                            bytes.count,
                            pageBuffer.baseAddress,
                            pageBuffer.count,
                            pageIndexes == nil ? 0 : 1,
                            passwordBuffer.baseAddress,
                            passwordBuffer.count,
                            password == nil ? 0 : 1
                        )
                    case .extract:
                        documentkit_extract_with_options(
                            bytes.baseAddress,
                            bytes.count,
                            pageBuffer.baseAddress,
                            pageBuffer.count,
                            pageIndexes == nil ? 0 : 1,
                            passwordBuffer.baseAddress,
                            passwordBuffer.count,
                            password == nil ? 0 : 1
                        )
                    case .document:
                        documentkit_extract_document_with_options(
                            bytes.baseAddress,
                            bytes.count,
                            pageBuffer.baseAddress,
                            pageBuffer.count,
                            pageIndexes == nil ? 0 : 1,
                            passwordBuffer.baseAddress,
                            passwordBuffer.count,
                            password == nil ? 0 : 1
                        )
                    }
                }
            }
        }
        guard let pointer = buffer.data, buffer.length > 0 else {
            documentkit_buffer_free(buffer)
            throw TurnipError.engineFailure(
                code: "empty_response",
                message: "The PDF engine returned no response."
            )
        }
        defer { documentkit_buffer_free(buffer) }

        let data = Data(bytes: pointer, count: buffer.length)
        do {
            return try JSONDecoder().decode(WireResponse.self, from: data)
        } catch {
            throw TurnipError.engineFailure(
                code: "invalid_response",
                message: "The PDF engine returned an unreadable response."
            )
        }
    }
}

private struct Payload: Sendable {
    let markdown: String?
    let document: ExtractedDocument?
    let inspection: DocumentInspection
    let warnings: [DocumentWarning]

    init(
        response: WireResponse,
        operation: EngineOperation,
        selectedPageIndexes: [Int]?
    ) throws {
        guard response.schemaVersion == 3
            || (response.schemaVersion == 2 && operation != .document)
        else {
            throw TurnipError.engineFailure(
                code: "unsupported_schema",
                message: "The PDF engine returned an unsupported response."
            )
        }
        guard response.ok, response.error == nil, let result = response.result else {
            throw response.error?.turnipError
                ?? TurnipError.engineFailure(
                    code: "invalid_response",
                    message: "The PDF engine returned an invalid response."
                )
        }
        guard let kind = DocumentKind(wireValue: result.pdfType) else {
            throw TurnipError.engineFailure(
                code: "unknown_pdf_type",
                message: "The PDF engine returned an unknown document type."
            )
        }
        guard result.pageCount > 0 else {
            throw TurnipError.engineFailure(
                code: "invalid_page_count",
                message: "The PDF engine returned an invalid page count."
            )
        }
        let pageRange = 0..<result.pageCount
        let pageCollections = [
            result.pagesNeedingOcr,
            result.ocrReasonsByPage.map(\.page),
            result.pagesWithTables,
            result.pagesWithColumns,
        ]
        guard pageCollections.joined().allSatisfy(pageRange.contains) else {
            throw TurnipError.engineFailure(
                code: "invalid_page_index",
                message: "The PDF engine returned an out-of-range page index."
            )
        }
        let selectedPages = Set(selectedPageIndexes ?? Array(pageRange))
        guard pageCollections.allSatisfy({ pages in
            zip(pages, pages.dropFirst()).allSatisfy { $0.0 < $0.1 }
                && pages.allSatisfy(selectedPages.contains)
        }), result.confidence.isFinite, result.processingTimeMs >= 0,
            !result.engineVersion.isEmpty
        else {
            throw TurnipError.engineFailure(
                code: "invalid_metadata",
                message: "The PDF engine returned invalid or unordered extraction metadata."
            )
        }

        markdown = result.markdown
        let hasExtractionMetadata = operation != .inspect
        let inspection = DocumentInspection(
            kind: kind,
            pageCount: result.pageCount,
            title: result.title,
            confidence: result.confidence,
            processingTime: .milliseconds(result.processingTimeMs),
            pagesNeedingOCR: result.pagesNeedingOcr,
            ocrReasonsByPage: result.ocrReasonsByPage.map {
                PageOCRReasons(pageIndex: $0.page, reasons: $0.reasons)
            },
            layout: hasExtractionMetadata
                ? DocumentLayout(
                    isComplex: result.isComplex,
                    pagesWithTables: result.pagesWithTables,
                    pagesWithColumns: result.pagesWithColumns
                )
                : nil,
            hasEncodingIssues: hasExtractionMetadata ? result.hasEncodingIssues : nil,
            engineVersion: "\(result.engineVersion)@\(Turnip.engineRevision)"
        )

        var warnings: [DocumentWarning] = []
        if !result.pagesNeedingOcr.isEmpty {
            warnings.append(
                DocumentWarning(
                    kind: .ocrRequired,
                    pageIndexes: result.pagesNeedingOcr
                )
            )
        }
        if hasExtractionMetadata && result.hasEncodingIssues {
            let pages = encodingIssuePageIndexes(
                from: result.ocrReasonsByPage.map {
                    PageOCRReasons(pageIndex: $0.page, reasons: $0.reasons)
                }
            )
            warnings.append(
                DocumentWarning(
                    kind: .encodingIssues,
                    pageIndexes: pages
                )
            )
        }
        self.inspection = inspection
        self.warnings = warnings

        if operation == .document {
            guard let wireDocument = result.document else {
                throw TurnipError.engineFailure(
                    code: "missing_document",
                    message: "The PDF engine omitted the structured document."
                )
            }
            let expectedPages = selectedPageIndexes ?? Array(pageRange)
            let pages = try wireDocument.publicPages(
                expectedPageIndexes: expectedPages,
                sourcePageCount: result.pageCount
            )
            guard pages.filter({ $0.status == .needsOCR }).map(\.pageIndex)
                == result.pagesNeedingOcr
            else {
                throw TurnipError.engineFailure(
                    code: "inconsistent_page_status",
                    message: "The PDF engine returned inconsistent OCR page coverage."
                )
            }
            document = ExtractedDocument(
                inspection: inspection,
                pages: pages,
                warnings: warnings
            )
        } else {
            guard result.document == nil else {
                throw TurnipError.engineFailure(
                    code: "unexpected_document",
                    message: "The PDF engine returned structured data for the wrong operation."
                )
            }
            document = nil
        }
    }
}

private extension DocumentKind {
    init?(wireValue: String) {
        self.init(rawValue: wireValue)
    }
}

private struct WireResponse: Decodable {
    let schemaVersion: Int
    let ok: Bool
    let result: WireResult?
    let error: WireError?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case ok
        case result
        case error
    }
}

private struct WireResult: Decodable {
    let engineVersion: String
    let pdfType: String
    let markdown: String?
    let pageCount: Int
    let processingTimeMs: Int64
    let pagesNeedingOcr: [Int]
    let ocrReasonsByPage: [WireOCRReasons]
    let title: String?
    let confidence: Float
    let isComplex: Bool
    let pagesWithTables: [Int]
    let pagesWithColumns: [Int]
    let hasEncodingIssues: Bool
    let document: WireDocument?

    enum CodingKeys: String, CodingKey {
        case engineVersion = "engine_version"
        case pdfType = "pdf_type"
        case markdown
        case pageCount = "page_count"
        case processingTimeMs = "processing_time_ms"
        case pagesNeedingOcr = "pages_needing_ocr"
        case ocrReasonsByPage = "ocr_reasons_by_page"
        case title
        case confidence
        case isComplex = "is_complex"
        case pagesWithTables = "pages_with_tables"
        case pagesWithColumns = "pages_with_columns"
        case hasEncodingIssues = "has_encoding_issues"
        case document
    }
}

private struct WireDocument: Decodable {
    let pages: [WireDocumentPage]

    func publicPages(
        expectedPageIndexes: [Int],
        sourcePageCount: Int
    ) throws -> [DocumentPage] {
        guard pages.map(\.pageIndex) == expectedPageIndexes else {
            throw TurnipError.engineFailure(
                code: "invalid_page_coverage",
                message: "The PDF engine did not return every requested page in source order."
            )
        }

        var blockIDs = Set<String>()
        return try pages.map { page in
            try page.publicPage(sourcePageCount: sourcePageCount, blockIDs: &blockIDs)
        }
    }
}

private struct WireDocumentPage: Decodable {
    let pageIndex: Int
    let size: WirePageSize
    let status: String
    let blocks: [WireDocumentBlock]

    enum CodingKeys: String, CodingKey {
        case pageIndex = "page_index"
        case size
        case status
        case blocks
    }

    func publicPage(sourcePageCount: Int, blockIDs: inout Set<String>) throws -> DocumentPage {
        guard (0..<sourcePageCount).contains(pageIndex) else {
            throw TurnipError.engineFailure(
                code: "invalid_page_index",
                message: "The PDF engine returned an out-of-range structured page index."
            )
        }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw TurnipError.engineFailure(
                code: "invalid_page_size",
                message: "The PDF engine returned an invalid page size."
            )
        }
        guard let pageStatus = DocumentPageStatus(wireValue: status) else {
            throw TurnipError.engineFailure(
                code: "unknown_page_status",
                message: "The PDF engine returned an unknown page status."
            )
        }

        let publicBlocks = try blocks.enumerated().map { index, block in
            let expectedID = "p\(pageIndex)-b\(index)"
            guard block.id == expectedID, blockIDs.insert(block.id).inserted else {
                throw TurnipError.engineFailure(
                    code: "invalid_block_id",
                    message: "The PDF engine returned an invalid or duplicate block ID."
                )
            }
            return try block.publicBlock()
        }
        return DocumentPage(
            pageIndex: pageIndex,
            size: PageSize(width: size.width, height: size.height),
            status: pageStatus,
            blocks: publicBlocks
        )
    }
}

private struct WirePageSize: Decodable {
    let width: Double
    let height: Double
}

private struct WireDocumentBlock: Decodable {
    let id: String
    let bounds: WireBounds?
    let content: WireBlockContent

    func publicBlock() throws -> DocumentBlock {
        let publicContent: DocumentBlock.Content
        switch content {
        case let .text(lines):
            publicContent = .text(
                TextBlock(lines: try lines.enumerated().map { index, line in
                    try line.publicLine(id: "\(id)-l\(index)")
                })
            )
        case let .table(rowCount, columnCount, cells, continuationRows, unassignedLines):
            publicContent = .table(
                try publicTable(
                    blockID: id,
                    rows: rowCount,
                    columns: columnCount,
                    wireCells: cells,
                    continuationRows: continuationRows,
                    unassignedLines: unassignedLines
                )
            )
        }
        return DocumentBlock(id: id, bounds: try bounds?.publicBounds(), content: publicContent)
    }
}

private func publicTable(
    blockID: String,
    rows rowCount: Int,
    columns columnCount: Int,
    wireCells: [WireTableCell],
    continuationRows: [WireTableContinuation],
    unassignedLines: [WireTextLine]
) throws -> TableBlock {
    guard rowCount > 0, columnCount > 0,
        !rowCount.multipliedReportingOverflow(by: columnCount).overflow
    else {
        throw TurnipError.engineFailure(
            code: "invalid_table_grid",
            message: "The PDF engine returned invalid table dimensions."
        )
    }

    let slotCount = rowCount * columnCount
    var slots = Array<TableCell?>(repeating: nil, count: slotCount)
    for wireCell in wireCells {
        guard wireCell.row >= 0, wireCell.column >= 0,
            wireCell.row < rowCount, wireCell.column < columnCount,
            wireCell.rowSpan > 0, wireCell.columnSpan > 0,
            wireCell.rowSpan <= rowCount - wireCell.row,
            wireCell.columnSpan <= columnCount - wireCell.column
        else {
            throw TurnipError.engineFailure(
                code: "invalid_table_grid",
                message: "The PDF engine returned a cell outside its table grid."
            )
        }

        let anchor = TableCellAddress(row: wireCell.row, column: wireCell.column)
        let publicCell = try wireCell.publicCell(blockID: blockID)
        for row in wireCell.row..<(wireCell.row + wireCell.rowSpan) {
            for column in wireCell.column..<(wireCell.column + wireCell.columnSpan) {
                let index = row * columnCount + column
                guard slots[index] == nil else {
                    throw TurnipError.engineFailure(
                        code: "invalid_table_grid",
                        message: "The PDF engine returned overlapping table cells."
                    )
                }
                slots[index] = if row == wireCell.row && column == wireCell.column {
                    publicCell
                } else {
                    TableCell(content: .covered(by: anchor))
                }
            }
        }
    }

    guard !slots.contains(where: { $0 == nil }) else {
        throw TurnipError.engineFailure(
            code: "invalid_table_grid",
            message: "The PDF engine did not cover every table slot."
        )
    }
    let continuationTargets = Dictionary(
        continuationRows.map { ($0.row, $0.continuationOf) },
        uniquingKeysWith: { first, _ in first }
    )
    guard continuationTargets.count == continuationRows.count,
        continuationRows.allSatisfy({
            (0..<rowCount).contains($0.row) && (0..<$0.row).contains($0.continuationOf)
        })
    else {
        throw TurnipError.engineFailure(
            code: "invalid_table_layout",
            message: "The PDF engine returned invalid continuation-row layout."
        )
    }
    let tableRows = (0..<rowCount).map { row in
        TableRow(
            id: "\(blockID)-r\(row)",
            cells: (0..<columnCount).map { column in
                slots[row * columnCount + column]!
            },
            continuationOfRowID: continuationTargets[row].map { "\(blockID)-r\($0)" }
        )
    }
    do {
        return try TableBlock(
            validating: tableRows,
            unassignedLines: unassignedLines.enumerated().map { index, line in
                try line.publicLine(id: "\(blockID)-unassigned-l\(index)")
            }
        )
    } catch {
        throw TurnipError.engineFailure(
            code: "invalid_table_grid",
            message: "The PDF engine returned an invalid table grid."
        )
    }
}

private enum WireBlockContent: Decodable {
    case text(lines: [WireTextLine])
    case table(
        rowCount: Int,
        columnCount: Int,
        cells: [WireTableCell],
        continuationRows: [WireTableContinuation],
        unassignedLines: [WireTextLine]
    )

    private enum CodingKeys: String, CodingKey {
        case type
        case lines
        case rowCount = "row_count"
        case columnCount = "column_count"
        case cells
        case continuationRows = "continuation_rows"
        case unassignedLines = "unassigned_lines"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text":
            self = .text(lines: try container.decode([WireTextLine].self, forKey: .lines))
        case "table":
            self = .table(
                rowCount: try container.decode(Int.self, forKey: .rowCount),
                columnCount: try container.decode(Int.self, forKey: .columnCount),
                cells: try container.decode([WireTableCell].self, forKey: .cells),
                continuationRows: try container.decode(
                    [WireTableContinuation].self,
                    forKey: .continuationRows
                ),
                unassignedLines: try container.decode(
                    [WireTextLine].self,
                    forKey: .unassignedLines
                )
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown structured block type"
            )
        }
    }
}

private struct WireTableContinuation: Decodable {
    let row: Int
    let continuationOf: Int

    enum CodingKeys: String, CodingKey {
        case row
        case continuationOf = "continuation_of"
    }
}

private struct WireTableCell: Decodable {
    let row: Int
    let column: Int
    let rowSpan: Int
    let columnSpan: Int
    let role: String
    let state: String
    let detectedText: String?
    let lines: [WireTextLine]
    let bounds: WireBounds?

    enum CodingKeys: String, CodingKey {
        case row
        case column
        case rowSpan = "row_span"
        case columnSpan = "column_span"
        case role
        case state
        case detectedText = "detected_text"
        case lines
        case bounds
    }

    func publicCell(blockID: String) throws -> TableCell {
        guard row >= 0, column >= 0, rowSpan > 0, columnSpan > 0 else {
            throw TurnipError.engineFailure(
                code: "invalid_table_cell",
                message: "The PDF engine returned an invalid table cell."
            )
        }
        let publicRole: TableCellRole?
        switch role {
        case "header":
            publicRole = .header
        case "body":
            publicRole = .body
        case "unknown":
            publicRole = nil
        default:
            throw TurnipError.engineFailure(
                code: "unknown_table_cell_value",
                message: "The PDF engine returned an unknown table cell role."
            )
        }

        let publicLines = try lines.enumerated().map { index, line in
            try line.publicLine(id: "\(blockID)-r\(row)-c\(column)-l\(index)")
        }
        let content: TableCell.Content
        switch state {
        case "extracted":
            guard !publicLines.isEmpty, detectedText == nil else {
                throw TurnipError.engineFailure(
                    code: "inconsistent_table_cell_state",
                    message: "The PDF engine returned invalid extracted cell evidence."
                )
            }
            content = .text(publicLines)
        case "empty":
            guard publicLines.isEmpty, detectedText == nil else {
                throw TurnipError.engineFailure(
                    code: "inconsistent_table_cell_state",
                    message: "The PDF engine returned invalid empty cell evidence."
                )
            }
            content = .empty
        case "unresolved":
            guard detectedText.map({ !$0.isEmpty }) ?? true else {
                throw TurnipError.engineFailure(
                    code: "inconsistent_table_cell_state",
                    message: "The PDF engine returned invalid unresolved cell evidence."
                )
            }
            content = .unresolved(lines: publicLines, candidateText: detectedText)
        default:
            throw TurnipError.engineFailure(
                code: "unknown_table_cell_value",
                message: "The PDF engine returned an unknown table cell state."
            )
        }

        return TableCell(
            content: content,
            role: publicRole,
            span: rowSpan > 1 || columnSpan > 1
                ? TableCellSpan(rows: rowSpan, columns: columnSpan)
                : nil,
            bounds: try bounds?.publicBounds()
        )
    }
}

private struct WireTextLine: Decodable {
    let text: String
    let bounds: WireBounds?

    func publicLine(id: String) throws -> TextLine {
        return TextLine(id: id, text: text, bounds: try bounds?.publicBounds())
    }
}

private struct WireBounds: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    func publicBounds() throws -> DocumentBounds {
        let epsilon = 0.000_001
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
            x >= 0, y >= 0, width > 0, height > 0,
            x <= 1, y <= 1, width <= 1, height <= 1,
            x + width <= 1 + epsilon, y + height <= 1 + epsilon
        else {
            throw TurnipError.engineFailure(
                code: "invalid_bounds",
                message: "The PDF engine returned invalid normalized bounds."
            )
        }
        let clippedWidth = min(width, 1 - x)
        let clippedHeight = min(height, 1 - y)
        guard clippedWidth > 0, clippedHeight > 0 else {
            throw TurnipError.engineFailure(
                code: "invalid_bounds",
                message: "The PDF engine returned empty normalized bounds."
            )
        }
        return DocumentBounds(
            x: x,
            y: y,
            width: clippedWidth,
            height: clippedHeight
        )
    }
}

private extension DocumentPageStatus {
    init?(wireValue: String) {
        switch wireValue {
        case "extracted": self = .extracted
        case "needs_ocr": self = .needsOCR
        case "extraction_failed": self = .extractionFailed
        default: return nil
        }
    }
}

private struct WireOCRReasons: Decodable {
    let page: Int
    let reasons: [String]
}

private struct WireError: Decodable {
    let code: String
    let message: String
    let pageIndex: Int?
    let pageCount: Int?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case pageIndex = "page_index"
        case pageCount = "page_count"
    }

    var turnipError: TurnipError {
        switch code {
        case "empty_input": .emptyInput
        case "input_too_large": .inputTooLarge(maximumBytes: Turnip.maximumInputSize)
        case "encrypted_pdf": .encryptedPDF
        case "empty_page_selection": .invalidPageSelection(.empty)
        case "invalid_page_order": .invalidPageSelection(.notAscending)
        case "invalid_page_index":
            if let pageIndex {
                .invalidPageSelection(.exceedsEngineLimit(pageIndex: pageIndex))
            } else {
                .engineFailure(code: code, message: message)
            }
        case "page_out_of_range":
            if let pageIndex, let pageCount {
                .pageOutOfRange(pageIndex: pageIndex, pageCount: pageCount)
            } else {
                .engineFailure(code: code, message: message)
            }
        case "not_a_pdf", "invalid_structure", "parse_error": .invalidPDF
        default: .engineFailure(code: code, message: message)
        }
    }
}
