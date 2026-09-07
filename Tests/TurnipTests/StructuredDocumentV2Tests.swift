import Foundation
import Testing
@testable import Turnip

@Test func tableRowsExposeLiteralCoveredSlotsAndExplicitResolution() throws {
    let document = v2Document()
    let reference = DocumentSourceReference(
        pageIndex: 0,
        blockID: "opaque-table",
        row: 1,
        column: 0
    )

    let literal = try #require(document.cell(for: reference))
    #expect(literal.state == .covered)
    #expect(literal.joinedText == nil)
    #expect(document.text(for: reference) == nil)

    let resolved = try #require(document.resolvedCell(for: reference))
    #expect(resolved.state == .text)
    #expect(resolved.joinedText == "North\nCampus")

    let resolvedReference = try #require(document.resolvedSourceReference(for: reference))
    #expect(resolvedReference.row == 0)
    #expect(resolvedReference.column == 0)
    #expect(resolvedReference.lineIndex == nil)

    let coveredLine = DocumentSourceReference(
        pageIndex: 0,
        blockID: "opaque-table",
        row: 1,
        column: 0,
        lineIndex: 0
    )
    #expect(document.line(for: coveredLine) == nil)
    #expect(document.text(for: coveredLine) == nil)
    #expect(document.resolvedSourceReference(for: coveredLine) == nil)
    #expect(document.resolvedCell(for: coveredLine) == nil)
}

@Test func unresolvedEvidenceNeverBecomesConfirmedCellText() throws {
    let document = v2Document()
    let reference = DocumentSourceReference(
        pageIndex: 0,
        blockID: "opaque-table",
        row: 0,
        column: 2
    )

    let cell = try #require(document.cell(for: reference))
    #expect(cell.state == .unresolved)
    #expect(cell.joinedText == nil)
    #expect(cell.lines.map(\.text) == ["Observed source"])
    #expect(cell.unresolvedCandidateText == "Detector value")
    #expect(document.text(for: reference) == nil)

    let lineReference = DocumentSourceReference(
        pageIndex: 0,
        blockID: "opaque-table",
        row: 0,
        column: 2,
        lineIndex: 0
    )
    #expect(document.line(for: lineReference)?.text == "Observed source")
    #expect(document.text(for: lineReference) == nil)
}

@Test func v2JSONUsesRowsAndRoundTripsWithoutFlattenedCoordinates() throws {
    let document = v2Document()
    let encoded = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(ExtractedDocument.self, from: encoded)
    #expect(decoded == document)

    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 2)
    let pages = try #require(object["pages"] as? [[String: Any]])
    let blocks = try #require(pages[0]["blocks"] as? [[String: Any]])
    let tableContent = try #require(
        blocks.first(where: { ($0["content"] as? [String: Any])?["type"] as? String == "table" })?[
            "content"
        ] as? [String: Any]
    )
    #expect(tableContent["rowCount"] == nil)
    #expect(tableContent["columnCount"] == nil)
    let rows = try #require(tableContent["rows"] as? [[String: Any]])
    let firstCell = try #require(rows[0]["cells"] as? [[String: Any]]).first
    #expect(firstCell?["state"] as? String == "text")
    #expect(firstCell?["row"] == nil)
    #expect(firstCell?["column"] == nil)

    let invalid = Data(#"{"state":"empty","lines":[{"text":"unexpected"}]}"#.utf8)
    #expect(throws: Error.self) {
        _ = try JSONDecoder().decode(TableCell.self, from: invalid)
    }
}

private func v2Document() -> ExtractedDocument {
    let heading = TableCell(
        content: .text([
            TextLine(text: "North"),
            TextLine(text: "Campus"),
        ]),
        role: .header,
        span: TableCellSpan(rows: 2, columns: 2)
    )
    let unresolved = TableCell(
        content: .unresolved(
            lines: [TextLine(text: "Observed source")],
            candidateText: "Detector value"
        )
    )
    let covered = TableCell(content: .covered(by: TableCellAddress(row: 0, column: 0)))
    let table = TableBlock(rows: [
        TableRow(cells: [heading, covered, unresolved]),
        TableRow(cells: [covered, covered, TableCell(content: .empty)]),
    ])
    let block = DocumentBlock(id: "opaque-table", content: .table(table))
    return ExtractedDocument(
        inspection: DocumentInspection(
            kind: .textBased,
            pageCount: 1,
            title: nil,
            confidence: 1,
            processingTime: .zero,
            pagesNeedingOCR: [],
            ocrReasonsByPage: [],
            layout: nil,
            hasEncodingIssues: false,
            engineVersion: "test"
        ),
        pages: [
            DocumentPage(
                pageIndex: 0,
                size: PageSize(width: 612, height: 792),
                status: .extracted,
                blocks: [block]
            ),
        ],
        warnings: []
    )
}
