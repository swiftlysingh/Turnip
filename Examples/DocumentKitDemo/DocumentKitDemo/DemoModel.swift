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

    func load(url: URL) {
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
                self?.beginExtraction(data: data, fileName: name)
            } catch is CancellationError {
                // Replacing a document intentionally cancels the old task.
            } catch {
                guard !Task.isCancelled else { return }
                self?.presentErrorMessage(error.localizedDescription)
            }
        }
    }

    func load(data: Data, fileName: String) {
        cancel()
        beginExtraction(data: data, fileName: fileName)
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
    }

    var markdownFileName: String {
        let baseName = (fileName as NSString).deletingPathExtension
        return (baseName.isEmpty ? "document" : baseName) + ".md"
    }

    private func beginExtraction(data: Data, fileName: String) {
        extractionTask?.cancel()
        let resolvedFileName = fileName.isEmpty ? "Untitled.pdf" : fileName
        self.fileName = resolvedFileName
        pdfDocument = PDFDocument(data: data)
        extraction = nil
        errorMessage = nil
        isExtracting = true

        extractionTask = Task { [weak self] in
            do {
                let result = try await DocumentKit.extract(data)
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
