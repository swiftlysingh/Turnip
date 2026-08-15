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
    #expect(result.inspection.engineVersion == "1.14.2@\(DocumentKit.engineRevision)")
    #expect(result.inspection.layout != nil)
}

@Test func packagedEngineIdentityMatchesThePinnedSource() async throws {
    let revision = "2322bcce4cd9458d24399bf8fee42f1aa201c8c1"
    let inspection = try await DocumentKit.inspect(makeTextPDF("Engine provenance"))

    #expect(DocumentKit.engineRevision == revision)
    #expect(inspection.engineVersion == "1.14.2@\(revision)")
}

@Test func inspectionDoesNotExtractMarkdown() async throws {
    let inspection = try await DocumentKit.inspect(makeTextPDF("Inspect me"))

    #expect(inspection.kind == .textBased)
    #expect(inspection.pageCount == 1)
    #expect(inspection.layout == nil)
    #expect(inspection.hasEncodingIssues == nil)
}

@Test func selectedPagesApplyToInspectionAndExtractionInDocumentOrder() async throws {
    let pdf = makeTextPDF([
        "First selected page",
        "Middle excluded page",
        "Last selected page",
    ])
    let options = DocumentOptions(pageIndexes: [0, 2])

    let inspection = try await DocumentKit.inspect(pdf, options: options)
    #expect(inspection.pageCount == 3)

    let extraction = try await DocumentKit.extract(pdf, options: options)
    #expect(extraction.inspection.pageCount == 3)
    #expect(extraction.markdown.contains("First selected page"))
    #expect(!extraction.markdown.contains("Middle excluded page"))
    #expect(extraction.markdown.contains("Last selected page"))
    #expect(
        extraction.warnings.flatMap(\.pageIndexes).allSatisfy { [0, 2].contains($0) }
    )
    #expect(
        extraction.markdown.range(of: "First selected page")!.lowerBound
            < extraction.markdown.range(of: "Last selected page")!.lowerBound
    )
}

@Test func selectedPageInspectionReflectsSelectedContent() async throws {
    let pdf = makeMixedTextAndImagePDF()

    let wholeDocument = try await DocumentKit.inspect(pdf)
    #expect(wholeDocument.pageCount == 2)
    #expect(wholeDocument.kind == .mixed)
    #expect(wholeDocument.pagesNeedingOCR == [1])

    let textPage = try await DocumentKit.inspect(
        pdf,
        options: DocumentOptions(pageIndexes: [0])
    )
    #expect(textPage.pageCount == 2)
    #expect(textPage.kind == .textBased)
    #expect(textPage.pagesNeedingOCR.isEmpty)

    let imagePage = try await DocumentKit.inspect(
        pdf,
        options: DocumentOptions(pageIndexes: [1])
    )
    #expect(imagePage.pageCount == 2)
    #expect(imagePage.kind == .scanned)
    #expect(imagePage.pagesNeedingOCR == [1])
    #expect(imagePage.ocrReasonsByPage.map(\.pageIndex) == [1])
}

@Test func pageSelectionValidationIsTypedAndConsistent() async {
    let pdf = makeTextPDF(["First", "Second"])

    await #expect(throws: DocumentKitError.invalidPageSelection(.empty)) {
        try await DocumentKit.inspect(pdf, options: DocumentOptions(pageIndexes: []))
    }
    await #expect(throws: DocumentKitError.invalidPageSelection(.negative(pageIndex: -1))) {
        try await DocumentKit.extract(pdf, options: DocumentOptions(pageIndexes: [-1]))
    }
    await #expect(throws: DocumentKitError.invalidPageSelection(.duplicate(pageIndex: 0))) {
        try await DocumentKit.inspect(pdf, options: DocumentOptions(pageIndexes: [0, 0]))
    }
    await #expect(throws: DocumentKitError.invalidPageSelection(.notAscending)) {
        try await DocumentKit.extract(pdf, options: DocumentOptions(pageIndexes: [1, 0]))
    }
    await #expect(
        throws: DocumentKitError.invalidPageSelection(
            .exceedsEngineLimit(pageIndex: Int(UInt32.max))
        )
    ) {
        try await DocumentKit.inspect(
            pdf,
            options: DocumentOptions(pageIndexes: [Int(UInt32.max)])
        )
    }
}

@Test func outOfRangePageIsReportedForInspectionAndExtraction() async {
    let pdf = makeTextPDF(["Only page"])
    let expected = DocumentKitError.pageOutOfRange(pageIndex: 1, pageCount: 1)

    await #expect(throws: expected) {
        try await DocumentKit.inspect(pdf, options: DocumentOptions(pageIndexes: [1]))
    }
    await #expect(throws: expected) {
        try await DocumentKit.extract(pdf, options: DocumentOptions(pageIndexes: [1]))
    }
    await #expect(throws: expected) {
        try await DocumentKit.extract(pdf, options: DocumentOptions(pageIndexes: [0, 1]))
    }
}

@Test func encryptedPDFRequiresTheCorrectPasswordForInspectionAndExtraction() async throws {
    let pdf = try encryptedFixture()

    await #expect(throws: DocumentKitError.encryptedPDF) {
        try await DocumentKit.inspect(pdf)
    }
    await #expect(throws: DocumentKitError.encryptedPDF) {
        try await DocumentKit.inspect(
            pdf,
            options: DocumentOptions(password: "wrong-password")
        )
    }
    let correctOptions = DocumentOptions(
        pageIndexes: [0],
        password: "documentkit-test-password"
    )
    let inspection = try await DocumentKit.inspect(pdf, options: correctOptions)
    #expect(inspection.pageCount == 1)

    await #expect(throws: DocumentKitError.encryptedPDF) {
        try await DocumentKit.extract(pdf)
    }
    await #expect(throws: DocumentKitError.encryptedPDF) {
        try await DocumentKit.extract(
            pdf,
            options: DocumentOptions(password: "wrong-password")
        )
    }
    let extraction = try await DocumentKit.extract(pdf, options: correctOptions)
    #expect(extraction.markdown.contains("DocumentKit Fixture"))
}

@Test func optionsDescriptionsRedactPasswords() {
    let secret = "never-print-this-password"
    let options = DocumentOptions(pageIndexes: [0, 2], password: secret)

    #expect(!String(describing: options).contains(secret))
    #expect(!String(reflecting: options).contains(secret))
    #expect(String(describing: options).contains("REDACTED"))

    var dumpOutput = ""
    dump(options, to: &dumpOutput)
    #expect(!dumpOutput.contains(secret))
    #expect(!Mirror(reflecting: options).children.contains { child in
        String(reflecting: child.value).contains(secret)
    })
}

private func makeTextPDF(_ text: String) -> Data {
    makeTextPDF([text])
}

private func makeTextPDF(_ pageTexts: [String]) -> Data {
    let pageCount = pageTexts.count
    let firstContentObject = 3 + pageCount
    let fontObject = 3 + (2 * pageCount)
    let kids = (0..<pageCount).map { "\($0 + 3) 0 R" }.joined(separator: " ")
    var objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [\(kids)] /Count \(pageCount) >>",
    ]

    for page in 0..<pageCount {
        objects.append(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 \(fontObject) 0 R >> >> /Contents \(firstContentObject + page) 0 R >>"
        )
    }
    for text in pageTexts {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
        let content = "BT /F1 24 Tf 72 720 Td (\(escaped)) Tj 0 -30 Td (Native Swift package) Tj 0 -30 Td (Rust PDF engine) Tj ET"
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
    }
    objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    return makePDF(objects)
}

private func makeMixedTextAndImagePDF() -> Data {
    let text = "BT /F1 24 Tf 72 720 Td (Embedded text page) Tj 0 -30 Td (Native Swift package) Tj 0 -30 Td (Rust PDF engine) Tj ET"
    let imageDrawing = "q 612 0 0 792 0 0 cm /Im1 Do Q"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 7 0 R >> >> /Contents 5 0 R >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Im1 8 0 R >> >> /Contents 6 0 R >>",
        "<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream",
        "<< /Length \(imageDrawing.utf8.count) >>\nstream\n\(imageDrawing)\nendstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length 7 >>\nstream\n000000>\nendstream",
    ]
    return makePDF(objects)
}

private func makePDF(_ objects: [String]) -> Data {
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

private func encryptedFixture() throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/encrypted-secret.pdf")
    return try Data(contentsOf: url)
}
