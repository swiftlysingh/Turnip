#if os(iOS)
import DocumentKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct IOSContentView: View {
    @StateObject private var model = DemoModel()
    @State private var isImporterPresented = false
    @State private var selectedPages = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    options

                    if model.isExtracting {
                        ProgressView("Extracting Markdown…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if let extraction = model.extraction {
                        result(extraction)
                    } else {
                        emptyState
                    }
                }
                .padding()
            }
            .navigationTitle("DocumentKit Demo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open PDF", systemImage: "folder") {
                        isImporterPresented = true
                    }
                }

                if model.isExtracting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") {
                            model.cancel()
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false,
            onCompletion: handleImport
        )
        .alert(
            "Couldn’t process PDF",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        model.dismissError()
                    }
                }
            )
        ) {
            Button("OK") {
                model.dismissError()
            }
        } message: {
            Text(model.errorMessage ?? "An unknown error occurred.")
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Pages, such as 1, 3, 5", text: $selectedPages)
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Selected pages, one-based and comma-separated")

            SecureField("PDF password, if needed", text: $password)
                .textFieldStyle(.roundedBorder)

            Text("Leave pages empty to process the entire PDF.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                extractAgain()
            } label: {
                Label("Extract Markdown", systemImage: "text.page")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.pdfDocument == nil || model.isExtracting)
        }
        .padding()
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)

            Text("Open a PDF")
                .font(.title2.weight(.semibold))

            Text("Inspect embedded text and extract the document as Markdown, entirely on device.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Choose from Files", systemImage: "folder") {
                isImporterPresented = true
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func result(_ extraction: DocumentExtraction) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("\(extraction.inspection.pageCount) pages", systemImage: "doc.on.doc")
                Spacer()
                Text(extraction.inspection.kind.rawValue)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if !extraction.inspection.pagesNeedingOCR.isEmpty {
                Label(
                    "OCR recommended for \(extraction.inspection.pagesNeedingOCR.count) page(s)",
                    systemImage: "text.viewfinder"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            Text(extraction.markdown)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Extracted Markdown")
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            do {
                model.load(
                    url: url,
                    options: try extractionOptions(),
                    previewPassword: previewPassword
                )
            } catch {
                model.presentError(error)
            }
        case let .failure(error):
            let nsError = error as NSError
            guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) else {
                return
            }
            model.presentError(error)
        }
    }

    private func extractAgain() {
        do {
            model.extract(options: try extractionOptions(), previewPassword: previewPassword)
        } catch {
            model.presentError(error)
        }
    }

    private func extractionOptions() throws -> DocumentOptions {
        let pageIndexes = try IOSPageSelectionParser.parse(selectedPages)
        return DocumentOptions(
            pageIndexes: pageIndexes,
            password: password.isEmpty ? nil : password
        )
    }

    private var previewPassword: String? {
        password.isEmpty ? nil : password
    }
}

private enum IOSPageSelectionParser {
    static func parse(_ text: String) throws -> [Int]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pageIndexes = try trimmed.split(separator: ",", omittingEmptySubsequences: false).map { value in
            let value = value.trimmingCharacters(in: .whitespaces)
            guard let page = Int(value), page > 0 else {
                throw IOSPageSelectionInputError()
            }
            return page - 1
        }

        guard Set(pageIndexes).count == pageIndexes.count,
              zip(pageIndexes, pageIndexes.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
            throw IOSPageSelectionInputError()
        }
        return pageIndexes
    }
}

private struct IOSPageSelectionInputError: LocalizedError {
    var errorDescription: String? {
        "Enter unique, ascending page numbers separated by commas, such as 1, 3, 5."
    }
}
#endif
