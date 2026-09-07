import Foundation
import Testing
@testable import Turnip

@Test func singleDataRowGridRetainsEveryCellAndSourceAddress() async throws {
    let document = try await Turnip.extractDocument(singleDataRowGridPDF())
    let page = try #require(document.page(at: 0))
    let tableBlock = try #require(page.blocks.first { block in
        if case .table = block.content { return true }
        return false
    })
    let table = try #require(tableBlock.table)

    #expect(table.rowCount == 2)
    #expect(table.columnCount == 3)
    #expect(table.rows.allSatisfy { $0.cells.count == table.columnCount })
    #expect(table.rows.flatMap(\.cells).count == 6)
    #expect(tableRows(table) == [
        ["Code", "Label", "Value"],
        ["Q-1", "ONE", "17.25"],
    ])
    #expect(table.rows.flatMap(\.cells).allSatisfy { $0.state == .text })

    let valueCell = try #require(table.cell(row: 1, column: 2))
    let source = DocumentSourceReference(
        pageIndex: page.pageIndex,
        blockID: tableBlock.id,
        row: 1,
        column: 2,
        lineIndex: 0
    )
    #expect(document.cell(for: source) == valueCell)
    #expect(document.line(for: source)?.text == "17.25")
    #expect(document.text(for: source) == "17.25")

    let textLines = page.blocks.compactMap(\.text).flatMap(\.lines).map(\.text)
    #expect(!textLines.contains("Q-1"))
    #expect(!textLines.contains("17.25"))
}

@Test func croppedLandscapeTableKeepsVisiblePageGeometryAndSourceReferences() async throws {
    let document = try await Turnip.extractDocument(croppedLandscapeTablePDF())
    let page = try #require(document.page(at: 0))
    let tableBlock = try #require(page.blocks.first { block in
        if case .table = block.content { return true }
        return false
    })
    let table = try #require(tableBlock.table)

    #expect(page.size.width == 840)
    #expect(page.size.height == 620)
    #expect(tableRows(table) == [
        ["Field", "Value"],
        ["LEFT", "ALPHA"],
        ["RIGHT", "BETA"],
    ])

    let betaCell = try #require(table.cell(row: 2, column: 1))
    let source = DocumentSourceReference(
        pageIndex: page.pageIndex,
        blockID: tableBlock.id,
        row: 2,
        column: 1,
        lineIndex: 0
    )
    #expect(document.cell(for: source) == betaCell)
    #expect(document.line(for: source)?.text == "BETA")
    #expect(document.text(for: source) == "BETA")

    let bounds = try #require(betaCell.bounds)
    #expect(bounds.x > 0.35 && bounds.x < 0.45)
    #expect(bounds.y > 0.30 && bounds.y < 0.40)
    #expect(bounds.x + bounds.width <= 1)
    #expect(bounds.y + bounds.height <= 1)

    let surroundingText = page.blocks.compactMap(\.text).flatMap(\.lines).map(\.text)
    #expect(surroundingText.contains("Landscape preface"))
    #expect(surroundingText.contains("Landscape note"))
}

@Test func proseImmediatelyAfterAlignedTableRemainsASeparateTextBlock() async throws {
    let document = try await Turnip.extractDocument(tableFollowedByAlignedProsePDF())
    let page = try #require(document.page(at: 0))
    let tableIndex = try #require(page.blocks.firstIndex { block in
        if case .table = block.content { return true }
        return false
    })
    let table = try #require(page.blocks[tableIndex].table)

    #expect(tableRows(table) == [
        ["Field", "Label", "Value"],
        ["A-1", "ALPHA", "17"],
    ])

    // These lines intentionally use the same font and the same x origin as
    // the last row's middle cell. They follow the table's bottom rule and
    // must stay ordinary page text instead of becoming a wrapped cell value.
    let textBlocks = page.blocks.enumerated().filter { index, block in
        index > tableIndex && block.text != nil
    }
    let prose = textBlocks.flatMap { $0.element.text?.lines.map(\.text) ?? [] }
    #expect(prose.contains("This note begins after the grid."))
    #expect(prose.contains("It remains ordinary page text."))
    let tableText = tableRows(table).flatMap { $0 }.joined(separator: " ")
    #expect(!tableText.contains("This note begins after the grid."))
}

private func tableRows(_ table: TableBlock) -> [[String]] {
    table.rows.map { row in
        row.cells.map { $0.joinedText ?? "<unresolved>" }
    }
}

private func singleDataRowGridPDF() -> Data {
    let content = """
    0.8 w
    40 690 m 520 690 l
    40 640 m 520 640 l
    40 590 m 520 590 l
    40 690 m 40 590 l
    160 690 m 160 590 l
    420 690 m 420 590 l
    520 690 m 520 590 l
    S
    BT
    /F1 11 Tf
    1 0 0 1 50 672 Tm (Code) Tj
    1 0 0 1 170 672 Tm (Label) Tj
    1 0 0 1 430 672 Tm (Value) Tj
    1 0 0 1 50 622 Tm (Q-1) Tj
    1 0 0 1 170 622 Tm (ONE) Tj
    1 0 0 1 430 622 Tm (17.25) Tj
    ET
    """
    return singlePagePDF(content: content, mediaBox: (612, 792))
}

private func croppedLandscapeTablePDF() -> Data {
    let content = """
    0.8 w
    140 560 m 860 560 l
    140 510 m 860 510 l
    140 460 m 860 460 l
    140 410 m 860 410 l
    140 560 m 140 410 l
    400 560 m 400 410 l
    860 560 m 860 410 l
    S
    BT
    /F1 11 Tf
    1 0 0 1 110 620 Tm (Landscape preface) Tj
    1 0 0 1 150 542 Tm (Field) Tj
    1 0 0 1 410 542 Tm (Value) Tj
    1 0 0 1 150 492 Tm (LEFT) Tj
    1 0 0 1 410 492 Tm (ALPHA) Tj
    1 0 0 1 150 442 Tm (RIGHT) Tj
    1 0 0 1 410 442 Tm (BETA) Tj
    1 0 0 1 110 350 Tm (Landscape note) Tj
    ET
    """
    return singlePagePDF(
        content: content,
        mediaBox: (1000, 700),
        cropBox: (80, 40, 920, 660)
    )
}

private func tableFollowedByAlignedProsePDF() -> Data {
    let content = """
    0.8 w
    40 700 m 520 700 l
    40 650 m 520 650 l
    40 625 m 520 625 l
    40 700 m 40 625 l
    160 700 m 160 625 l
    420 700 m 420 625 l
    520 700 m 520 625 l
    S
    BT
    /F1 11 Tf
    1 0 0 1 50 682 Tm (Field) Tj
    1 0 0 1 170 682 Tm (Label) Tj
    1 0 0 1 430 682 Tm (Value) Tj
    1 0 0 1 50 632 Tm (A-1) Tj
    1 0 0 1 170 632 Tm (ALPHA) Tj
    1 0 0 1 430 632 Tm (17) Tj
    1 0 0 1 170 612 Tm (This note begins after the grid.) Tj
    1 0 0 1 170 597 Tm (It remains ordinary page text.) Tj
    ET
    """
    return singlePagePDF(content: content, mediaBox: (612, 792))
}

private func singlePagePDF(
    content: String,
    mediaBox: (width: Int, height: Int),
    cropBox: (xMin: Int, yMin: Int, xMax: Int, yMax: Int)? = nil
) -> Data {
    let crop = cropBox.map {
        " /CropBox [\($0.xMin) \($0.yMin) \($0.xMax) \($0.yMax)]"
    } ?? ""
    let page = """
    << /Type /Page /Parent 2 0 R /MediaBox [0 0 \(mediaBox.width) \(mediaBox.height)]\(crop) /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>
    """
    return makePDF([
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        page,
        "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ])
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

private extension DocumentBlock {
    var table: TableBlock? {
        guard case let .table(value) = content else { return nil }
        return value
    }

    var text: TextBlock? {
        guard case let .text(value) = content else { return nil }
        return value
    }
}
