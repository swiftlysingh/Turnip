import Combine
import Turnip
import Foundation
import PDFKit

@MainActor
final class DemoModel: ObservableObject {
    @Published private(set) var pdfDocument: PDFDocument?
    @Published private(set) var fileName: String = "Untitled.pdf"
    @Published private(set) var document: ExtractedDocument?
    @Published private(set) var documentJSON: String?
    @Published private(set) var isExtracting = false
    @Published private(set) var errorMessage: String?

    private var extractionTask: Task<Void, Never>?
    private var pdfData: Data?

    func load(url: URL, options: DocumentOptions, previewPassword: String?) {
        cancel()

        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        let name = url.lastPathComponent
        fileName = name.isEmpty ? "Untitled.pdf" : name
        pdfDocument = nil
        document = nil
        documentJSON = nil
        errorMessage = nil
        isExtracting = true

        extractionTask = Task { [weak self] in
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let readTask = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    if values.isRegularFile == true,
                       let fileSize = values.fileSize,
                       fileSize > Turnip.maximumInputSize
                    {
                        throw TurnipError.inputTooLarge(maximumBytes: Turnip.maximumInputSize)
                    }
                    return try Data(contentsOf: url, options: [.mappedIfSafe])
                }
                let data = try await readTask.value
                try Task.checkCancellation()
                self?.beginExtraction(
                    data: data,
                    fileName: name,
                    options: options,
                    previewPassword: previewPassword
                )
            } catch is CancellationError {
                // Replacing a document intentionally cancels the old task.
            } catch {
                guard !Task.isCancelled else { return }
                self?.presentErrorMessage(error.localizedDescription)
            }
        }
    }

    func load(
        data: Data,
        fileName: String,
        options: DocumentOptions,
        previewPassword: String?
    ) {
        cancel()
        beginExtraction(
            data: data,
            fileName: fileName,
            options: options,
            previewPassword: previewPassword
        )
    }

    func extract(options: DocumentOptions, previewPassword: String?) {
        guard let pdfData else { return }
        cancel()
        beginExtraction(
            data: pdfData,
            fileName: fileName,
            options: options,
            previewPassword: previewPassword
        )
    }

    func cancel() {
        extractionTask?.cancel()
        extractionTask = nil
        isExtracting = false
    }

    func dismissError() {
        errorMessage = nil
    }

    func presentError(_ error: Error) {
        presentErrorMessage(error.localizedDescription)
    }

    func presentErrorMessage(_ message: String) {
        errorMessage = message
        isExtracting = false
        extractionTask = nil
    }

    var jsonFileName: String {
        let baseName = (fileName as NSString).deletingPathExtension
        return (baseName.isEmpty ? "document" : baseName) + ".json"
    }

    private func beginExtraction(
        data: Data,
        fileName: String,
        options: DocumentOptions,
        previewPassword: String?
    ) {
        extractionTask?.cancel()
        let resolvedFileName = fileName.isEmpty ? "Untitled.pdf" : fileName
        self.fileName = resolvedFileName
        pdfData = data
        let document = PDFDocument(data: data)
        if let previewPassword {
            document?.unlock(withPassword: previewPassword)
        }
        pdfDocument = document
        self.document = nil
        documentJSON = nil
        errorMessage = nil
        isExtracting = true

        extractionTask = Task { [weak self] in
            do {
                let result = try await Turnip.extractDocument(data, options: options)
                try Task.checkCancellation()
                let json = try await Task.detached(priority: .userInitiated) {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    return String(decoding: try encoder.encode(result), as: UTF8.self)
                }.value
                try Task.checkCancellation()
                self?.finishExtraction(result, json: json)
            } catch is CancellationError {
                // Replacing a document intentionally cancels the old task.
            } catch {
                guard !Task.isCancelled else { return }
                self?.presentError(error)
            }
        }
    }

    private func finishExtraction(_ result: ExtractedDocument, json: String) {
        document = result
        documentJSON = json
        isExtracting = false
        extractionTask = nil
    }
}
