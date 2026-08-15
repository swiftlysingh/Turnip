import DocumentKitCore
import Foundation

public enum DocumentKit {
    public static let maximumInputSize = 100 * 1024 * 1024
    public static let engineRevision = String(cString: documentkit_engine_revision())

    public static func inspect(_ data: Data) async throws -> DocumentInspection {
        try await inspect(data, options: DocumentOptions())
    }

    public static func inspect(
        _ data: Data,
        options: DocumentOptions
    ) async throws -> DocumentInspection {
        let payload = try await Engine.run(.inspect, data: data, options: options)
        return payload.inspection
    }

    public static func inspect(contentsOf url: URL) async throws -> DocumentInspection {
        try await inspect(load(url))
    }

    public static func inspect(
        contentsOf url: URL,
        options: DocumentOptions
    ) async throws -> DocumentInspection {
        try await inspect(load(url), options: options)
    }

    public static func extract(_ data: Data) async throws -> DocumentExtraction {
        try await extract(data, options: DocumentOptions())
    }

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

    public static func extract(contentsOf url: URL) async throws -> DocumentExtraction {
        try await extract(load(url))
    }

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
/// Passwords are passed directly to the engine for the duration of a call and
/// are redacted from string and debug descriptions.
public struct DocumentOptions: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public let pageIndexes: [Int]?
    private let passwordStorage: String?

    public init(pageIndexes: [Int]? = nil, password: String? = nil) {
        self.pageIndexes = pageIndexes
        passwordStorage = password
    }

    public var description: String {
        "DocumentOptions(pageIndexes: \(pageIndexes.map { String(describing: $0) } ?? "all"), password: \(passwordStorage == nil ? "nil" : "[REDACTED]"))"
    }

    public var debugDescription: String { description }

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

public struct DocumentExtraction: Sendable, Hashable {
    public let markdown: String
    public let inspection: DocumentInspection
    public let warnings: [DocumentWarning]
}

public struct DocumentInspection: Sendable, Hashable {
    public let kind: DocumentKind
    /// Total pages in the source PDF, including pages outside a selection.
    public let pageCount: Int
    public let title: String?
    public let confidence: Float
    public let processingTime: Duration
    public let pagesNeedingOCR: [Int]
    public let ocrReasonsByPage: [PageOCRReasons]
    public let layout: DocumentLayout?
    public let hasEncodingIssues: Bool?
    public let engineVersion: String
}

public enum DocumentKind: String, Sendable, Hashable {
    case textBased = "text_based"
    case scanned
    case imageBased = "image_based"
    case mixed
}

public struct DocumentLayout: Sendable, Hashable {
    public let isComplex: Bool
    public let pagesWithTables: [Int]
    public let pagesWithColumns: [Int]
}

public struct PageOCRReasons: Sendable, Hashable {
    public let pageIndex: Int
    public let reasons: [String]
}

public struct DocumentWarning: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case ocrRequired
        case encodingIssues
    }

    public let kind: Kind
    public let pageIndexes: [Int]
}

public enum DocumentKitError: Error, Sendable, Hashable {
    case emptyInput
    case inputTooLarge(maximumBytes: Int)
    case encryptedPDF
    case invalidPageSelection(PageSelectionError)
    case pageOutOfRange(pageIndex: Int, pageCount: Int)
    case invalidPDF
    case noExtractableText(DocumentInspection)
    case engineFailure(code: String, message: String)
}

extension DocumentKitError: LocalizedError {
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

public enum PageSelectionError: Sendable, Hashable {
    case empty
    case negative(pageIndex: Int)
    case duplicate(pageIndex: Int)
    case notAscending
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
