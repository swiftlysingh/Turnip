import Foundation
import Testing
@testable import DocumentKit

@Test func emptyInputFailsBeforeCallingTheEngine() async {
    await #expect(throws: DocumentKitError.emptyInput) {
        try await DocumentKit.inspect(Data())
    }
}

@Test func nonPDFFailsWithThePublicError() async {
    await #expect(throws: DocumentKitError.invalidPDF) {
        try await DocumentKit.inspect(Data("not a PDF".utf8))
    }
}

@Test func extractsMarkdownAndIncludesInspection() async throws {
    let result = try await DocumentKit.extract(makeTextPDF("DocumentKit works"))

    #expect(result.markdown.contains("DocumentKit works"))
    #expect(result.inspection.kind == .textBased)
    #expect(result.inspection.pageCount == 1)
    #expect(result.inspection.pagesNeedingOCR.isEmpty)
    #expect(result.inspection.engineVersion == "1.14.1@\(DocumentKit.engineRevision)")
    #expect(result.inspection.layout != nil)
}

@Test func inspectionDoesNotExtractMarkdown() async throws {
    let inspection = try await DocumentKit.inspect(makeTextPDF("Inspect me"))

    #expect(inspection.kind == .textBased)
    #expect(inspection.pageCount == 1)
    #expect(inspection.layout == nil)
    #expect(inspection.hasEncodingIssues == nil)
}

private func makeTextPDF(_ text: String) -> Data {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "(", with: "\\(")
        .replacingOccurrences(of: ")", with: "\\)")
    let content = "BT /F1 24 Tf 72 720 Td (\(escaped)) Tj 0 -30 Td (Native Swift package) Tj 0 -30 Td (Rust PDF engine) Tj ET"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]

    var data = Data("%PDF-1.4\n".utf8)
    var offsets = [0]
    for (index, object) in objects.enumerated() {
        offsets.append(data.count)
        data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
    }

    let xrefOffset = data.count
    data.append(Data("xref\n0 \(objects.count + 1)\n".utf8))
    data.append(Data("0000000000 65535 f \n".utf8))
    for offset in offsets.dropFirst() {
        data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
    }
    data.append(
        Data(
            "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8
        )
    )
    return data
}
