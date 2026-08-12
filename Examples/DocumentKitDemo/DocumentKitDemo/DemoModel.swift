import Combine
import DocumentKit
import Foundation
import PDFKit

@MainActor
final class DemoModel: ObservableObject {
    @Published private(set) var pdfDocument: PDFDocument?
    @Published private(set) var fileName: String = "Untitled.pdf"
    @Published private(set) var extraction: DocumentExtraction?
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
        extraction = nil
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

    var markdownFileName: String {
        let baseName = (fileName as NSString).deletingPathExtension
        return (baseName.isEmpty ? "document" : baseName) + ".md"
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
        extraction = nil
        errorMessage = nil
        isExtracting = true

        extractionTask = Task { [weak self] in
            do {
                let result = try await DocumentKit.extract(data, options: options)
                try Task.checkCancellation()
                self?.finishExtraction(result)
            } catch is CancellationError {
                // Replacing a document intentionally cancels the old task.
            } catch {
                guard !Task.isCancelled else { return }
                self?.presentError(error)
            }
        }
    }

    private func finishExtraction(_ result: DocumentExtraction) {
        extraction = result
        isExtracting = false
        extractionTask = nil
    }
}
