#if os(macOS)
import AppKit
import DocumentKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = DemoModel()
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false
    @State private var selectedPages = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 0) {
            ExtractionOptionsBar(
                selectedPages: $selectedPages,
                password: $password,
                canExtract: model.pdfDocument != nil && !model.isExtracting,
                extract: extractAgain
            )

            Divider()

            if model.pdfDocument != nil || model.extraction != nil || model.isExtracting {
                HSplitView {
                    PDFPreview(document: model.pdfDocument)
                        .frame(minWidth: 360, idealWidth: 520)

                    MarkdownPane(
                        extraction: model.extraction,
                        isExtracting: model.isExtracting
                    )
                    .frame(minWidth: 360)
                }
            } else {
                EmptyState {
                    isImporterPresented = true
                }
            }

            InspectionBar(
                extraction: model.extraction,
                isExtracting: model.isExtracting
            )
        }
        .frame(minWidth: 900, minHeight: 600)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.tint, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Open PDF", systemImage: "folder") {
                    isImporterPresented = true
                }
                .keyboardShortcut("o", modifiers: .command)

                if model.extraction != nil {
                    Button("Copy Markdown", systemImage: "doc.on.doc") {
                        copyMarkdown()
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])

                    Button("Save Markdown", systemImage: "square.and.arrow.down") {
                        saveMarkdown()
                    }
                }

                if model.isExtracting {
                    Button("Cancel", systemImage: "xmark.circle") {
                        model.cancel()
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
        .onDrop(
            of: [UTType.pdf],
            isTargeted: $isDropTargeted,
            perform: handleDrop
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

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, error in
            if let data {
                Task { @MainActor in
                    do {
                        model.load(
                            data: data,
                            fileName: "Dropped PDF.pdf",
                            options: try extractionOptions(),
                            previewPassword: previewPassword
                        )
                    } catch {
                        model.presentError(error)
                    }
                }
            } else if let error {
                let message = error.localizedDescription
                Task { @MainActor in
                    model.presentErrorMessage(message)
                }
            }
        }

        return true
    }

    private func extractAgain() {
        do {
            model.extract(options: try extractionOptions(), previewPassword: previewPassword)
        } catch {
            model.presentError(error)
        }
    }

    private func extractionOptions() throws -> DocumentOptions {
        let pageIndexes = try PageSelectionParser.parse(selectedPages)
        try PageSelectionParser.validate(pageIndexes)
        return DocumentOptions(
            pageIndexes: pageIndexes,
            password: password.isEmpty ? nil : password
        )
    }

    private var previewPassword: String? {
        password.isEmpty ? nil : password
    }

    private func copyMarkdown() {
        guard let markdown = model.extraction?.markdown else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
    }

    private func saveMarkdown() {
        guard let markdown = model.extraction?.markdown else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = model.markdownFileName
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in
                    model.presentErrorMessage(message)
                }
            }
        }
    }
}

private struct ExtractionOptionsBar: View {
    @Binding var selectedPages: String
    @Binding var password: String
    let canExtract: Bool
    let extract: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField("Pages (1, 3, 5)", text: $selectedPages)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
                .accessibilityLabel("Selected pages, one-based and comma-separated")

            SecureField("PDF password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)

            Text("Leave pages empty for the entire PDF.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Extract", systemImage: "text.page", action: extract)
                .disabled(!canExtract)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private enum PageSelectionParser {
    static func parse(_ text: String) throws -> [Int]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return try trimmed.split(separator: ",", omittingEmptySubsequences: false).map { value in
            let value = value.trimmingCharacters(in: .whitespaces)
            guard let page = Int(value), page > 0 else {
                throw PageSelectionInputError()
            }
            return page - 1
        }
    }

    static func validate(_ pageIndexes: [Int]?) throws {
        guard let pageIndexes else { return }
        guard Set(pageIndexes).count == pageIndexes.count,
              zip(pageIndexes, pageIndexes.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else {
            throw PageSelectionInputError()
        }
    }
}

private struct PageSelectionInputError: LocalizedError {
    var errorDescription: String? {
        "Enter unique, ascending, one-based page numbers separated by commas, such as 1, 3, 5."
    }
}

private struct EmptyState: View {
    let open: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)

            Text("Open a PDF")
                .font(.title2.weight(.semibold))

            Text("Choose a PDF or drop one anywhere in this window to inspect and extract it as Markdown.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button("Open PDF", systemImage: "folder", action: open)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct MarkdownPane: View {
    let extraction: DocumentExtraction?
    let isExtracting: Bool

    var body: some View {
        Group {
            if let extraction {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        InspectionSummary(inspection: extraction.inspection)

                        if !extraction.warnings.isEmpty {
                            WarningsView(warnings: extraction.warnings)
                        }

                        Text(extraction.markdown)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                }
                .accessibilityLabel("Extracted Markdown")
            } else if isExtracting {
                ProgressView("Extracting Markdown…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Markdown will appear here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
    }
}

private struct InspectionSummary: View {
    let inspection: DocumentInspection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if let title = inspection.title, !title.isEmpty {
                    Label(title, systemImage: "text.alignleft")
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("Confidence \(inspection.confidence.percentDescription)")
            }

            HStack(spacing: 12) {
                Label(inspection.ocrDescription, systemImage: "text.viewfinder")
                Label(inspection.layoutDescription, systemImage: "rectangle.3.group")
                Label(inspection.encodingDescription, systemImage: "character")
            }
            .lineLimit(1)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(inspection.accessibilityDescription)
    }
}

private struct WarningsView: View {
    let warnings: [DocumentWarning]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Warnings", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                Text("• \(warning.summary)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

private struct InspectionBar: View {
    let extraction: DocumentExtraction?
    let isExtracting: Bool

    var body: some View {
        HStack(spacing: 14) {
            if let extraction {
                let inspection = extraction.inspection
                Label("\(inspection.pageCount) pages", systemImage: "doc.on.doc")
                Text(inspection.kind.displayName)
                Text(inspection.processingTime.shortDescription)

                if !extraction.warnings.isEmpty {
                    Label(
                        "\(extraction.warnings.count) warning\(extraction.warnings.count == 1 ? "" : "s")",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }

                Spacer()

                Text("Engine \(inspection.engineVersion)")
                    .foregroundStyle(.secondary)
            } else if isExtracting {
                ProgressView()
                    .controlSize(.small)
                Text("Extracting…")
                    .foregroundStyle(.secondary)
            } else {
                Text("Ready")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusLabel)
    }

    private var statusLabel: String {
        guard let inspection = extraction?.inspection else {
            return isExtracting ? "Extracting Markdown" : "Ready"
        }
        return "\(inspection.pageCount) pages, \(inspection.kind.displayName), processed in \(inspection.processingTime.shortDescription)"
    }
}

private extension DocumentKind {
    var displayName: String {
        switch self {
        case .textBased: "Text-based"
        case .scanned: "Scanned"
        case .imageBased: "Image-based"
        case .mixed: "Mixed"
        }
    }
}

private extension DocumentInspection {
    var ocrDescription: String {
        let count = pagesNeedingOCR.count
        return count == 0 ? "OCR not needed" : "OCR \(count) page\(count == 1 ? "" : "s")"
    }

    var layoutDescription: String {
        guard let layout else { return "Layout not analyzed" }

        var details = [layout.isComplex ? "Complex layout" : "Simple layout"]
        if !layout.pagesWithTables.isEmpty {
            details.append("\(layout.pagesWithTables.count) table page\(layout.pagesWithTables.count == 1 ? "" : "s")")
        }
        if !layout.pagesWithColumns.isEmpty {
            details.append("\(layout.pagesWithColumns.count) column page\(layout.pagesWithColumns.count == 1 ? "" : "s")")
        }
        return details.joined(separator: ", ")
    }

    var encodingDescription: String {
        switch hasEncodingIssues {
        case .some(true): "Encoding issues"
        case .some(false): "Encoding clean"
        case nil: "Encoding not analyzed"
        }
    }

    var accessibilityDescription: String {
        let title = self.title.flatMap { $0.isEmpty ? nil : $0 }.map { "Title \($0). " } ?? ""
        return title + "Confidence \(confidence.percentDescription). \(ocrDescription). \(layoutDescription). \(encodingDescription)."
    }
}

private extension Float {
    var percentDescription: String {
        "\(Int((self * 100).rounded()))%"
    }
}

private extension DocumentWarning {
    var summary: String {
        let pages = pageIndexes.map { String($0 + 1) }.joined(separator: ", ")
        let pageDescription = pages.isEmpty ? "" : " (pages \(pages))"

        switch kind {
        case .ocrRequired:
            return "OCR may be required\(pageDescription)."
        case .encodingIssues:
            return "Text encoding issues were detected\(pageDescription)."
        }
    }
}

private extension Duration {
    var shortDescription: String {
        let components = self.components
        if components.seconds > 0 {
            return "\(components.seconds)s"
        }
        return "\(components.attoseconds / 1_000_000_000_000_000)ms"
    }
}
#endif
