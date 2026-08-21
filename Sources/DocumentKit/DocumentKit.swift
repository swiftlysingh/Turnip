import DocumentKitCore
import Foundation

/// Inspects local PDFs and extracts their embedded text as Markdown.
///
/// DocumentKit does not upload documents or perform OCR. Use ``inspect(_:)``
/// to decide how to route a PDF, or ``extract(_:)`` when the app needs
/// Markdown.
public enum DocumentKit {
    /// The largest PDF input accepted by the public API, in bytes.
    ///
    /// Inputs larger than this limit throw ``DocumentKitError/inputTooLarge(maximumBytes:)``.
    public static let maximumInputSize = 100 * 1024 * 1024

    /// The pinned upstream engine source revision embedded in the packaged binary.
    ///
    /// This identifies the upstream source commit. It does not include the
    /// hash of DocumentKit's tracked Apple patch.
    public static let engineRevision = String(cString: documentkit_engine_revision())

    /// Inspects PDF data without producing Markdown.
    ///
    /// - Parameter data: The complete PDF data to inspect.
    /// - Returns: Classification and OCR-routing information for the PDF.
    /// - Throws: A ``DocumentKitError`` when the input cannot be inspected.
    public static func inspect(_ data: Data) async throws -> DocumentInspection {
        try await inspect(data, options: DocumentOptions())
    }

    /// Inspects selected pages of PDF data without producing Markdown.
    ///
    /// - Parameters:
    ///   - data: The complete PDF data to inspect.
    ///   - options: Page-selection and password options.
    /// - Returns: Classification and OCR-routing information for the PDF.
    /// - Throws: A ``DocumentKitError`` when the input or options are invalid.
    public static func inspect(
        _ data: Data,
        options: DocumentOptions
    ) async throws -> DocumentInspection {
        let payload = try await Engine.run(.inspect, data: data, options: options)
        return payload.inspection
    }

    /// Inspects a PDF at a file URL without producing Markdown.
    ///
    /// DocumentKit checks available file-size metadata before reading and enforces
    /// the input limit after loading.
    ///
    /// - Parameter url: The URL of a local PDF file.
    /// - Returns: Classification and OCR-routing information for the PDF.
    /// - Throws: A ``DocumentKitError`` when the file cannot be read or inspected.
    public static func inspect(contentsOf url: URL) async throws -> DocumentInspection {
        try await inspect(load(url))
    }

    /// Inspects selected pages of a PDF at a file URL without producing Markdown.
    ///
    /// - Parameters:
    ///   - url: The URL of a local PDF file.
    ///   - options: Page-selection and password options.
    /// - Returns: Classification and OCR-routing information for the PDF.
    /// - Throws: A ``DocumentKitError`` when the file, input, or options are invalid.
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
    /// - Throws: A ``DocumentKitError`` when the input is invalid or has no extractable text.
    public static func extract(_ data: Data) async throws -> DocumentExtraction {
        try await extract(data, options: DocumentOptions())
    }

    /// Extracts Markdown from selected pages of PDF data.
    ///
    /// - Parameters:
    ///   - data: The complete PDF data to extract.
    ///   - options: Page-selection and password options.
    /// - Returns: Markdown together with inspection information and warnings.
    /// - Throws: A ``DocumentKitError`` when the input or options are invalid,
    ///   or when the selection has no extractable text.
    public static func extract(
        _ data: Data,
        options: DocumentOptions
    ) async throws -> DocumentExtraction {
        let payload = try await Engine.run(.extract, data: data, options: options)
        guard let markdown = payload.markdown, !markdown.isEmpty else {
            throw DocumentKitError.noExtractableText(payload.inspection)
        }
        return DocumentExtraction(
            markdown: markdown,
            inspection: payload.inspection,
            warnings: payload.warnings
        )
    }

    /// Extracts Markdown from a PDF at a file URL.
    ///
    /// DocumentKit checks available file-size metadata before reading and enforces
    /// the input limit after loading.
    ///
    /// - Parameter url: The URL of a local PDF file.
    /// - Returns: Markdown together with inspection information and warnings.
    /// - Throws: A ``DocumentKitError`` when the file cannot be read or extracted.
    public static func extract(contentsOf url: URL) async throws -> DocumentExtraction {
        try await extract(load(url))
    }

    /// Extracts Markdown from selected pages of a PDF at a file URL.
    ///
    /// - Parameters:
    ///   - url: The URL of a local PDF file.
    ///   - options: Page-selection and password options.
    /// - Returns: Markdown together with inspection information and warnings.
    /// - Throws: A ``DocumentKitError`` when the file, input, or options are invalid,
    ///   or when the selection has no extractable text.
    public static func extract(
        contentsOf url: URL,
        options: DocumentOptions
    ) async throws -> DocumentExtraction {
        try await extract(load(url), options: options)
    }

    private static func load(_ url: URL) async throws -> Data {
        let task = Task.detached(priority: nil) {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values.fileSize, fileSize > maximumInputSize {
                throw DocumentKitError.inputTooLarge(maximumBytes: maximumInputSize)
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

/// Options shared by PDF inspection and Markdown extraction.
///
/// `pageIndexes` are zero-based, strictly ascending, and unique. `nil`
/// processes the entire PDF; selected pages are emitted in document order.
/// Passwords are passed to the engine and redacted from descriptions and
/// reflection.
public struct DocumentOptions: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    /// Zero-based PDF page indexes to process, or `nil` for the entire document.
    public let pageIndexes: [Int]?
    private let passwordStorage: String?

    /// Creates options for inspection or extraction.
    ///
    /// - Parameters:
    ///   - pageIndexes: Zero-based, unique indexes in strictly ascending document order.
    ///     Pass `nil` to process every page.
    ///   - password: A password for an encrypted PDF. DocumentKit passes it to the
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
            throw DocumentKitError.invalidPageSelection(.empty)
        }

        var seen = Set<Int>()
        for pageIndex in pageIndexes {
            guard pageIndex >= 0 else {
                throw DocumentKitError.invalidPageSelection(.negative(pageIndex: pageIndex))
            }
            guard let value = UInt32(exactly: pageIndex), value < UInt32.max else {
                throw DocumentKitError.invalidPageSelection(.exceedsEngineLimit(pageIndex: pageIndex))
            }
            guard seen.insert(pageIndex).inserted else {
                throw DocumentKitError.invalidPageSelection(.duplicate(pageIndex: pageIndex))
            }
        }
        guard zip(pageIndexes, pageIndexes.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
            throw DocumentKitError.invalidPageSelection(.notAscending)
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
/// ``DocumentKit/inspect(_:)`` returns the detect-only subset. Its ``layout``
/// and ``hasEncodingIssues`` values are `nil` because Markdown is not built.
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

    /// Layout analysis from extraction, or `nil` for a detect-only inspection.
    public let layout: DocumentLayout?

    /// Whether extraction found encoding issues, or `nil` for a detect-only inspection.
    public let hasEncodingIssues: Bool?

    /// The engine version and embedded upstream source revision used for this result.
    public let engineVersion: String
}

/// The engine's classification of a PDF's content.
public enum DocumentKind: String, Sendable, Hashable {
    /// The engine classified the PDF as text-based.
    case textBased = "text_based"

    /// The engine classified the PDF as scanned.
    case scanned

    /// The engine classified the PDF as image-based.
    case imageBased = "image_based"

    /// The engine classified the PDF as mixed.
    case mixed
}

/// Layout information found while extracting Markdown.
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

/// A quality warning returned with a Markdown extraction.
public struct DocumentWarning: Sendable, Hashable {
    /// The category of extraction-quality warning.
    public enum Kind: Sendable, Hashable {
        /// The engine recommends OCR for one or more pages.
        case ocrRequired

        /// The engine found text-encoding issues during extraction.
        case encodingIssues
    }

    /// The warning category.
    public let kind: Kind

    /// Zero-based pages affected by the warning.
    public let pageIndexes: [Int]
}

/// Errors returned by PDF inspection and Markdown extraction.
public enum DocumentKitError: Error, Sendable, Hashable {
    /// The input data is empty.
    case emptyInput

    /// The input exceeds ``DocumentKit/maximumInputSize``.
    case inputTooLarge(maximumBytes: Int)

    /// The PDF is encrypted and needs a valid password.
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

extension DocumentKitError: LocalizedError {
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
}

private enum Engine {
    static func run(
        _ operation: EngineOperation,
        data: Data,
        options: DocumentOptions
    ) async throws -> Payload {
        guard !data.isEmpty else { throw DocumentKitError.emptyInput }
        guard data.count <= DocumentKit.maximumInputSize else {
            throw DocumentKitError.inputTooLarge(maximumBytes: DocumentKit.maximumInputSize)
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
                    }
                }
            }
        }
        guard let pointer = buffer.data, buffer.length > 0 else {
            documentkit_buffer_free(buffer)
            throw DocumentKitError.engineFailure(
                code: "empty_response",
                message: "The PDF engine returned no response."
            )
        }
        defer { documentkit_buffer_free(buffer) }

        let data = Data(bytes: pointer, count: buffer.length)
        do {
            return try JSONDecoder().decode(WireResponse.self, from: data)
        } catch {
            throw DocumentKitError.engineFailure(
                code: "invalid_response",
                message: "The PDF engine returned an unreadable response."
            )
        }
    }
}

private struct Payload: Sendable {
    let markdown: String?
    let inspection: DocumentInspection
    let warnings: [DocumentWarning]

    init(
        response: WireResponse,
        operation: EngineOperation,
        selectedPageIndexes: [Int]?
    ) throws {
        guard response.schemaVersion == 1 else {
            throw DocumentKitError.engineFailure(
                code: "unsupported_schema",
                message: "The PDF engine returned an unsupported response."
            )
        }
        guard response.ok, let result = response.result else {
            throw response.error?.documentKitError
                ?? DocumentKitError.engineFailure(
                    code: "invalid_response",
                    message: "The PDF engine returned an invalid response."
                )
        }
        guard let kind = DocumentKind(wireValue: result.pdfType) else {
            throw DocumentKitError.engineFailure(
                code: "unknown_pdf_type",
                message: "The PDF engine returned an unknown document type."
            )
        }
        guard result.pageCount > 0 else {
            throw DocumentKitError.engineFailure(
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
            throw DocumentKitError.engineFailure(
                code: "invalid_page_index",
                message: "The PDF engine returned an out-of-range page index."
            )
        }

        markdown = result.markdown
        inspection = DocumentInspection(
            kind: kind,
            pageCount: result.pageCount,
            title: result.title,
            confidence: result.confidence,
            processingTime: .milliseconds(result.processingTimeMs),
            pagesNeedingOCR: result.pagesNeedingOcr,
            ocrReasonsByPage: result.ocrReasonsByPage.map {
                PageOCRReasons(pageIndex: $0.page, reasons: $0.reasons)
            },
            layout: operation == .extract
                ? DocumentLayout(
                    isComplex: result.isComplex,
                    pagesWithTables: result.pagesWithTables,
                    pagesWithColumns: result.pagesWithColumns
                )
                : nil,
            hasEncodingIssues: operation == .extract ? result.hasEncodingIssues : nil,
            engineVersion: "\(result.engineVersion)@\(DocumentKit.engineRevision)"
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
        if operation == .extract && result.hasEncodingIssues {
            let pages = Array(Set(result.ocrReasonsByPage.map(\.page))).sorted()
            warnings.append(
                DocumentWarning(
                    kind: .encodingIssues,
                    pageIndexes: pages.isEmpty
                        ? selectedPageIndexes ?? Array(0..<result.pageCount)
                        : pages
                )
            )
        }
        self.warnings = warnings
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

    var documentKitError: DocumentKitError {
        switch code {
        case "empty_input": .emptyInput
        case "input_too_large": .inputTooLarge(maximumBytes: DocumentKit.maximumInputSize)
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
