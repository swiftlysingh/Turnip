import Foundation
import Testing
@testable import Turnip

@Test func structuredDocumentPreservesInventedStatementStructureAndEvidence() async throws {
    let document = try await Turnip.extractDocument(inventedStatementPDF())

    #expect(document.schemaVersion == ExtractedDocument.currentSchemaVersion)
    #expect(document.inspection.pageCount == 2)
    #expect(document.pages.map(\.pageIndex) == [0, 1])
    #expect(document.pages.allSatisfy { $0.status == .extracted })

    let firstPage = try #require(document.page(at: 0))
    let secondPage = try #require(document.page(at: 1))
    let firstTable = try #require(firstPage.blocks.compactMap(\.table).first)
    let secondTable = try #require(secondPage.blocks.compactMap(\.table).first)

    // The fixture deliberately puts prose before and after each table. The
    // prose must remain in the block stream and table items must not be
    // duplicated in a separate text block.
    let firstText = firstPage.blocks.compactMap(\.text).flatMap(\.lines).map(\.text)
    #expect(firstText.contains("INVENTED COMMUNITY BANK"))
    #expect(firstText.contains("Statement period: 01 Jan - 31 Jan"))
    #expect(firstText.contains("Currency: USD"))
    #expect(firstText.contains("Statement summary"))
    #expect(!firstText.contains("03 Jan"))
    #expect(!firstText.contains("5.00 CR"))

    let firstRows = tableRows(firstTable)
    #expect(firstRows.contains(["Date", "Description", "Amount", "Balance"]))
    #expect(firstRows.contains(["03 Jan", "COFFEE HOUSE", "12.34", "987.66"]))
    #expect(firstRows.contains(["04 Jan", "REFUND SHOP", "5.00 CR", ""]))

    let duplicateRows = firstRows.filter {
        Array($0.prefix(3)) == ["05 Jan", "BOOKSTORE", "20.00"]
    }
    #expect(duplicateRows.count == 2)
    #expect(duplicateRows.map { $0[3] } == ["972.66", "952.66"])
    let duplicateSourceRows = tableSlots(firstTable).filter {
        $0.column == 1 && $0.cell.joinedText == "BOOKSTORE"
    }.map(\.row)
    #expect(duplicateSourceRows.count == 2)
    #expect(Set(duplicateSourceRows).count == 2)

    let wrappedCell = tableSlots(firstTable).first {
        $0.cell.lines.map(\.text).contains("LONG MERCHANT")
    }?.cell
    #expect(wrappedCell?.lines.map(\.text) == ["LONG MERCHANT", "DESCRIPTION | CONTINUED"])

    // Every ordinary slot is represented, including the intentionally blank
    // balance cell. This is what keeps a blank from shifting later columns.
    #expect(firstTable.rows.count == firstTable.rowCount)
    #expect(firstTable.rows.allSatisfy { $0.cells.count == firstTable.columnCount })
    for row in 0..<firstTable.rowCount {
        for column in 0..<firstTable.columnCount {
            #expect(firstTable.cell(row: row, column: column) != nil)
        }
    }
    let emptyCells = tableSlots(firstTable).map(\.cell).filter { $0.state == .empty }
    #expect(emptyCells.count == 1)
    #expect(emptyCells.first?.joinedText == "")

    // The next page is a separate page-local fragment. Repeated headers and
    // continuation rows remain visible to the downstream layout interpreter.
    let secondRows = tableRows(secondTable)
    #expect(secondRows.contains(["Date", "Description", "Amount", "Balance"]))
    #expect(secondRows.contains(["08 Jan", "GROCER", "10.00", "932.66"]))
    #expect(secondRows.contains(["09 Jan", "TRANSFER", "15.00 CR", "947.66"]))
    let secondText = secondPage.blocks.compactMap(\.text).flatMap(\.lines).map(\.text)
    #expect(secondText.contains("Printed purchases: 72.34"))
    #expect(secondText.contains("Printed credits: 20.00"))
    #expect(secondText.contains("Closing balance: 947.66"))

    let firstTableIndex = try #require(firstPage.blocks.firstIndex { block in
        if case .table = block.content { return true }
        return false
    })
    let summaryIndex = try #require(firstPage.blocks.firstIndex { block in
        block.contentText.contains("Statement summary")
    })
    #expect(firstPage.blocks.first?.contentText.contains("INVENTED COMMUNITY BANK") == true)
    #expect(firstTableIndex < summaryIndex)

    // A source reference resolves the original cell and its extracted line;
    // it does not reinterpret the amount or its credit convention.
    let creditSlot = try #require(tableSlots(firstTable).first {
        $0.cell.lines.map(\.text) == ["5.00 CR"]
    })
    let reference = DocumentSourceReference(
        pageIndex: 0,
        blockID: firstPage.blocks[firstTableIndex].id,
        row: creditSlot.row,
        column: creditSlot.column,
        lineIndex: 0
    )
    #expect(document.cell(for: reference) == creditSlot.cell)
    #expect(document.line(for: reference)?.text == "5.00 CR")
    #expect(document.text(for: reference) == "5.00 CR")
    if let bounds = creditSlot.cell.bounds {
        assertNormalized(bounds)
    } else {
        Issue.record("The extracted credit cell did not retain source geometry")
    }
}

@Test func inventedStatementMatchesTheExpectedStructuredDocument() async throws {
    let document = try await Turnip.extractDocument(inventedStatementPDF())
    let expectedURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures/invented-statement-structured.json")
    let expected = try Data(contentsOf: expectedURL)

    #expect(
        try normalizedSemanticJSON(JSONEncoder().encode(document))
            == normalizedSemanticJSON(expected)
    )
}

@Test func structuredDocumentPreservesBorderlessTableCellsWithoutFinancialInterpretation() async throws {
    let document = try await Turnip.extractDocument(borderlessRegisterPDF())
    let page = try #require(document.pages.first)
    let table = try #require(page.blocks.compactMap(\.table).first)
    let rows = tableRows(table)

    // The detector's table grid keeps blank slots, repeated source rows, and
    // surrounding prose. Turnip does not assign any financial meaning to the
    // two numeric columns.
    #expect(rows.contains(["Code", "Label", "Out", "In"]))
    #expect(rows.filter { $0 == ["R-03", "REPEAT", "", "4.50"] }.count == 2)
    #expect(rows.contains(["R-05", "SINGLE", "7.00", ""]))

    let repeatCells = tableSlots(table).filter {
        $0.column == 1 && $0.cell.joinedText == "REPEAT"
    }
    #expect(repeatCells.count == 2)
    #expect(Set(repeatCells.map(\.row)).count == 2)

    let blankOut = try #require(tableSlots(table).first { slot in
        slot.column == 2 && slot.cell.state == .empty
    }).cell
    let blankIn = try #require(tableSlots(table).first { slot in
        slot.column == 3 && slot.cell.state == .empty
    }).cell
    #expect(blankOut.joinedText == "")
    #expect(blankIn.joinedText == "")

    let text = page.blocks.compactMap(\.text).flatMap(\.lines).map(\.text)
    #expect(text.contains("Before borderless table"))
    #expect(text.contains("After borderless table"))
}

@Test func structuredDocumentKeepsContinuationPageTableFragmentsInSourceOrder() async throws {
    let document = try await Turnip.extractDocument(continuationTablesPDF())
    #expect(document.pages.map(\.pageIndex) == [0, 1])

    let firstPage = try #require(document.page(at: 0))
    let secondPage = try #require(document.page(at: 1))
    let firstTable = try #require(firstPage.blocks.compactMap(\.table).first)
    let secondTable = try #require(secondPage.blocks.compactMap(\.table).first)

    // Each physical source page remains a separate table fragment. Repeated
    // headers are source evidence, so no cross-page merge guesses are made.
    #expect(tableRows(firstTable).contains(["Key", "Detail", "Out", "In"]))
    #expect(tableRows(firstTable).contains(["A-1", "ALPHA", "2.00", ""]))
    #expect(tableRows(secondTable).contains(["Key", "Detail", "Out", "In"]))
    #expect(tableRows(secondTable).contains(["B-1", "BETA", "", "2.00"]))

    #expect(firstPage.blocks.first?.contentText.contains("Page one introduction") == true)
    #expect(secondPage.blocks.first?.contentText.contains("Page two introduction") == true)
    #expect(firstPage.blocks.last?.contentText.contains("Page one note") == true)
    #expect(secondPage.blocks.last?.contentText.contains("Page two note") == true)
}

@Test func structuredDocumentRetainsSelectedOriginalPageIndexes() async throws {
    let document = try await Turnip.extractDocument(
        inventedStatementPDF(),
        options: DocumentOptions(pageIndexes: [1])
    )

    #expect(document.inspection.pageCount == 2)
    #expect(document.pages.map(\.pageIndex) == [1])
    #expect(document.pages.first?.blocks.map(\.contentText).joined().contains("08 Jan") == true)
    #expect(document.pages.first?.blocks.map(\.contentText).joined().contains("03 Jan") == false)
}

@Test func structuredDocumentKeepsSparseSelectedIndexesInSourceOrder() async throws {
    let pdf = makeTextAndGridPDF([
        textContent("First selected page has enough embedded text for native extraction."),
        textContent("Middle excluded page has enough embedded text for native extraction."),
        textContent("Last selected page has enough embedded text for native extraction."),
    ])
    let document = try await Turnip.extractDocument(
        pdf,
        options: DocumentOptions(pageIndexes: [0, 2])
    )

    #expect(document.inspection.pageCount == 3)
    #expect(document.pages.map(\.pageIndex) == [0, 2])
    let extractedText = document.pages.flatMap(\.blocks).map(\.contentText).joined()
    #expect(extractedText.contains("First selected page"))
    #expect(!extractedText.contains("Middle excluded page"))
    #expect(extractedText.contains("Last selected page"))
}

@Test func structuredDocumentValidatesEveryPageSelectionError() async {
    let pdf = textOnlyPDF()

    await #expect(throws: TurnipError.invalidPageSelection(.empty)) {
        try await Turnip.extractDocument(pdf, options: DocumentOptions(pageIndexes: []))
    }
    await #expect(throws: TurnipError.invalidPageSelection(.negative(pageIndex: -1))) {
        try await Turnip.extractDocument(pdf, options: DocumentOptions(pageIndexes: [-1]))
    }
    await #expect(throws: TurnipError.invalidPageSelection(.duplicate(pageIndex: 0))) {
        try await Turnip.extractDocument(pdf, options: DocumentOptions(pageIndexes: [0, 0]))
    }
    await #expect(
        throws: TurnipError.invalidPageSelection(
            .exceedsEngineLimit(pageIndex: Int(UInt32.max))
        )
    ) {
        try await Turnip.extractDocument(
            pdf,
            options: DocumentOptions(pageIndexes: [Int(UInt32.max)])
        )
    }
}

@Test func encodingWarningAttributionRequiresTheGarbledTextReason() {
    let reasons = [
        PageOCRReasons(pageIndex: 0, reasons: ["scanned"]),
        PageOCRReasons(pageIndex: 1, reasons: ["suspected_garbled_text"]),
        PageOCRReasons(
            pageIndex: 2,
            reasons: ["suspected_garbled_text", "vector_text"]
        ),
    ]

    #expect(encodingIssuePageIndexes(from: reasons) == [1, 2])
    #expect(encodingIssuePageIndexes(from: []) == [])
}

@Test func retroBudgetConsumerCanValidateAnInterpretedValueAgainstItsSourceCell() async throws {
    let document = try await Turnip.extractDocument(inventedStatementPDF())
    let page = try #require(document.page(at: 0))
    let tableBlock = try #require(page.blocks.first { block in
        if case .table = block.content { return true }
        return false
    })
    let table = try #require(tableBlock.table)
    let creditSlot = try #require(tableSlots(table).first {
        $0.cell.joinedText == "5.00 CR"
    })
    let source = DocumentSourceReference(
        pageIndex: 0,
        blockID: tableBlock.id,
        row: creditSlot.row,
        column: creditSlot.column
    )

    // This conversion is deliberately consumer-owned. Turnip supplies the
    // source string and address but never decides that CR means a negative USD
    // amount.
    let interpreted = RetroBudgetInterpretedValue(
        amountMinor: -500,
        currency: "USD",
        source: source,
        expectedSourceText: "5.00 CR"
    )
    #expect(interpreted.amountMinor == -500)
    #expect(interpreted.currency == "USD")
    #expect(interpreted.matchesSource(in: document))

    let encoded = try JSONEncoder().encode(interpreted)
    #expect(try JSONDecoder().decode(RetroBudgetInterpretedValue.self, from: encoded) == interpreted)
}

@Test func structuredDocumentTextOnlyPagesKeepLineBoundaries() async throws {
    let document = try await Turnip.extractDocument(textOnlyPDF())

    let page = try #require(document.pages.first)
    #expect(page.status == .extracted)
    let textBlock = try #require(page.blocks.compactMap(\.text).first)
    #expect(textBlock.lines.map(\.text) == [
        "Statement details",
        "No detected table here",
        "Keep this line separate",
    ])
    #expect(textBlock.joinedText == "Statement details\nNo detected table here\nKeep this line separate")
    #expect(page.blocks.allSatisfy { block in
        if case .text = block.content { return true }
        return false
    })
}

@Test func structuredDocumentLeavesAmbiguousFinancialTextAsStrings() async throws {
    let document = try await Turnip.extractDocument(financialStringFormsPDF())
    let text = try #require(document.pages.first).blocks
        .compactMap(\.text)
        .flatMap(\.lines)
        .map(\.text)

    #expect(text == ["03 Jan", "01/02", "5.00 CR", "(12.34)", "1.234,56"])
}

@Test func structuredDocumentCanRepresentMultipleTablesAndSurroundingText() async throws {
    let document = try await Turnip.extractDocument(multipleTablesPDF())
    let page = try #require(document.pages.first)
    let tables = page.blocks.compactMap(\.table)

    #expect(tables.count == 2)
    #expect(page.blocks.map(\.contentText).joined().contains("Two independent tables") == true)
    #expect(page.blocks.map(\.contentText).joined().contains("After both tables") == true)
    #expect(tableRows(tables[0]).contains(["A1", "B1"]))
    #expect(tableRows(tables[1]).contains(["C1", "D1"]))
}

@Test func structuredDocumentMixedPagesHaveExplicitOCRCoverage() async throws {
    let document = try await Turnip.extractDocument(mixedTextAndImagePDF())

    #expect(document.inspection.kind == .mixed)
    #expect(document.pages.map(\.pageIndex) == [0, 1])
    #expect(document.pages[0].status == .extracted)
    #expect(document.pages[1].status == .needsOCR)
    #expect(document.inspection.pagesNeedingOCR == [1])
    #expect(document.pages[1].blocks.isEmpty)
    #expect(document.warnings.contains { warning in
        if case .ocrRequired = warning.kind {
            return warning.pageIndexes == [1]
        }
        return false
    })
}

@Test func structuredDocumentRetainsSparseTextOCRRoutingWithoutRenderingMarkdown() async throws {
    let document = try await Turnip.extractDocument(
        makeTextAndGridPDF([textContent("Short")])
    )

    let page = try #require(document.pages.first)
    #expect(page.status == .needsOCR)
    #expect(page.blocks.map(\.contentText).joined().contains("Short"))
    #expect(document.inspection.pagesNeedingOCR == [0])
    #expect(document.warnings.contains { warning in
        warning.kind == .ocrRequired && warning.pageIndexes == [0]
    })
}

@Test func structuredDocumentHandlesPasswordProtectedInput() async throws {
    let document = try await Turnip.extractDocument(
        encryptedFixture(),
        options: DocumentOptions(
            pageIndexes: [0],
            password: "documentkit-test-password"
        )
    )

    #expect(document.pages.map(\.pageIndex) == [0])
    #expect(document.pages.flatMap(\.blocks).map(\.contentText).joined().contains("DocumentKit Fixture"))
}

@Test func structuredDocumentTreatsAnEmptyPasswordAsSupplied() async throws {
    let encrypted = try encryptedFixture()

    await #expect(throws: TurnipError.encryptedPDF) {
        try await Turnip.extractDocument(
            encrypted,
            options: DocumentOptions(password: "")
        )
    }

    #expect(!String(describing: DocumentOptions()).contains("REDACTED"))
    #expect(String(describing: DocumentOptions(password: "")).contains("REDACTED"))
}

@Test func structuredDocumentPreservesTypedFatalErrors() async throws {
    await #expect(throws: TurnipError.invalidPDF) {
        try await Turnip.extractDocument(Data("not a PDF".utf8))
    }

    let encrypted = try encryptedFixture()
    await #expect(throws: TurnipError.encryptedPDF) {
        try await Turnip.extractDocument(encrypted)
    }
    await #expect(throws: TurnipError.encryptedPDF) {
        try await Turnip.extractDocument(
            encrypted,
            options: DocumentOptions(password: "wrong-password")
        )
    }

    let pageError = TurnipError.pageOutOfRange(pageIndex: 2, pageCount: 2)
    await #expect(throws: pageError) {
        try await Turnip.extractDocument(
            inventedStatementPDF(),
            options: DocumentOptions(pageIndexes: [2])
        )
    }
    await #expect(throws: TurnipError.invalidPageSelection(.notAscending)) {
        try await Turnip.extractDocument(
            inventedStatementPDF(),
            options: DocumentOptions(pageIndexes: [1, 0])
        )
    }
}

@Test func structuredDocumentPreservesCancellationBehavior() async {
    let task = Task {
        withUnsafeCurrentTask { currentTask in
            currentTask?.cancel()
        }
        return try await Turnip.extractDocument(textOnlyPDF())
    }

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
}

@Test func structuredDocumentFileURLOverloadUsesTheSamePipeline() async throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "turnip-structured-fixture-\(UUID().uuidString).pdf")
    try inventedStatementPDF().write(to: url, options: .atomic)
    defer { try? FileManager.default.removeItem(at: url) }

    let document = try await Turnip.extractDocument(contentsOf: url)
    #expect(document.pages.map(\.pageIndex) == [0, 1])
    #expect(document.pages.first?.blocks.map(\.contentText).joined().contains("INVENTED COMMUNITY BANK") == true)
}

@Test func structuredDocumentCoordinatesAreNormalizedForOffsetCropAndRotation() async throws {
    let document = try await Turnip.extractDocument(rotatedOffsetCropPDF())
    let page = try #require(document.pages.first)

    // CropBox is [20, 30, 180, 270] (160 x 240 points), then /Rotate 90
    // makes the upright visible page 240 x 160 points.
    #expect(page.size.width == 240)
    #expect(page.size.height == 160)
    let line = try #require(page.blocks.compactMap(\.text).flatMap(\.lines).first)
    let bounds = try #require(line.bounds)
    assertNormalized(bounds)
    #expect(abs(bounds.x - 0.375) < 0.000_001)
    #expect(abs(bounds.y - 0.25) < 0.000_001)
    #expect(abs(bounds.width - 0.05) < 0.000_001)
    #expect(abs(bounds.height - 0.696_225) < 0.000_001)
}

@Test func structuredDocumentJSONIsTaggedRoundTrippableAndOmitsIncidentalFields() async throws {
    let document = try await Turnip.extractDocument(inventedStatementPDF())
    let data = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(ExtractedDocument.self, from: data)
    #expect(decoded == document)

    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(object["schemaVersion"] as? Int == ExtractedDocument.currentSchemaVersion)
    #expect(object["markdown"] == nil)
    #expect(object["password"] == nil)
    #expect(object["path"] == nil)

    let pages = try #require(object["pages"] as? [[String: Any]])
    let blocks = try #require(pages[0]["blocks"] as? [[String: Any]])
    let tableBlock = try #require(blocks.first { block in
        (block["content"] as? [String: Any])?["type"] as? String == "table"
    })
    let content = try #require(tableBlock["content"] as? [String: Any])
    #expect(content["type"] as? String == "table")
    #expect(content["rowCount"] == nil)
    #expect(content["columnCount"] == nil)
    #expect(content["cells"] == nil)
    let rows = try #require(content["rows"] as? [[String: Any]])
    #expect(!rows.isEmpty)
    let firstRow = try #require(rows.first?["cells"] as? [[String: Any]])
    #expect(!firstRow.isEmpty)

    let firstLine = try #require(
        firstRow.first?["lines"] as? [[String: Any]]
    )
    #expect(firstLine.first?["text"] is String)

    // A future warning code remains data, rather than being discarded by the
    // decoder that knows only the current warning cases.
    let warning = try JSONDecoder().decode(
        DocumentWarning.self,
        from: Data(#"{"code":"futureEngineWarning","pageIndexes":[1]}"#.utf8)
    )
    if case .unknown("futureEngineWarning") = warning.kind {
        // expected
    } else {
        Issue.record("Unknown warning code was not preserved")
    }
    let warningData = try JSONEncoder().encode(warning)
    #expect(try JSONDecoder().decode(DocumentWarning.self, from: warningData) == warning)
}

@Test func extractionFailedPageStatusIsPubliclyCodable() throws {
    let inspection = DocumentInspection(
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
    )
    let document = ExtractedDocument(
        inspection: inspection,
        pages: [DocumentPage(
            pageIndex: 0,
            size: PageSize(width: 1, height: 1),
            status: .extractionFailed,
            blocks: []
        )],
        warnings: []
    )

    let encoded = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(ExtractedDocument.self, from: encoded)
    #expect(decoded == document)
    let object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    let pages = try #require(object["pages"] as? [[String: Any]])
    #expect(
        pages.first?["status"] as? String == "extractionFailed"
    )
}

@Test func structuredDocumentResultsAreSemanticallyDeterministic() async throws {
    let first = try await Turnip.extractDocument(inventedStatementPDF())
    let second = try await Turnip.extractDocument(inventedStatementPDF())

    #expect(first.schemaVersion == second.schemaVersion)
    #expect(first.pages == second.pages)
    #expect(first.warnings == second.warnings)
    #expect(first.inspection.kind == second.inspection.kind)
    #expect(first.inspection.pageCount == second.inspection.pageCount)
    #expect(first.inspection.title == second.inspection.title)
    #expect(first.inspection.confidence == second.inspection.confidence)
    #expect(first.inspection.pagesNeedingOCR == second.inspection.pagesNeedingOCR)
    #expect(first.inspection.ocrReasonsByPage == second.inspection.ocrReasonsByPage)
    #expect(first.inspection.layout == second.inspection.layout)
    #expect(first.inspection.hasEncodingIssues == second.inspection.hasEncodingIssues)
    #expect(first.inspection.engineVersion == second.inspection.engineVersion)
}

@Test func tableSpansPreserveGridLookupAndSourceMeaning() throws {
    let merged = TableCell(
        content: .text([
            TextLine(text: "Merchant | Detail"),
            TextLine(text: "wrapped continuation"),
        ]),
        role: .header,
        span: TableCellSpan(rows: 2, columns: 2)
    )
    let body = TableCell(
        content: .text([TextLine(text: "A")]),
        role: .body,
    )
    let coveredByMerged = TableCell(
        content: .covered(by: TableCellAddress(row: 0, column: 0))
    )
    let empty = TableCell(content: .empty)
    let table = TableBlock(rows: [
        TableRow(cells: [merged, coveredByMerged]),
        TableRow(cells: [coveredByMerged, coveredByMerged]),
        TableRow(cells: [body, empty]),
    ])

    #expect(table.cell(row: 0, column: 0) == merged)
    #expect(table.cell(row: 0, column: 1) == coveredByMerged)
    #expect(table.cell(row: 1, column: 0) == coveredByMerged)
    #expect(table.cell(row: 1, column: 1) == coveredByMerged)
    #expect(table.cell(row: 2, column: 0) == body)
    #expect(table.cell(row: 2, column: 1) == empty)
    #expect(table.resolvedCell(row: 0, column: 0) == merged)
    #expect(table.resolvedCell(row: 0, column: 1) == merged)
    #expect(table.resolvedCell(row: 1, column: 0) == merged)
    #expect(table.resolvedCell(row: 1, column: 1) == merged)
    #expect(table.resolvedCellAddress(row: 0, column: 1) == TableCellAddress(row: 0, column: 0))
    #expect(table.resolvedCellAddress(row: 1, column: 0) == TableCellAddress(row: 0, column: 0))
    #expect(table.resolvedCellAddress(row: 1, column: 1) == TableCellAddress(row: 0, column: 0))

    let block = DocumentBlock(id: "p0-b0", content: .table(table))
    let inspection = DocumentInspection(
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
    )
    let document = ExtractedDocument(
        inspection: inspection,
        pages: [DocumentPage(
            pageIndex: 0,
            size: PageSize(width: 1, height: 1),
            status: .extracted,
            blocks: [block]
        )],
        warnings: []
    )
    let reference = DocumentSourceReference(pageIndex: 0, blockID: "p0-b0", row: 1, column: 1)
    #expect(document.cell(for: reference) == coveredByMerged)
    #expect(document.resolvedCell(for: reference) == merged)
    let resolvedReference = DocumentSourceReference(
        pageIndex: 0,
        blockID: "p0-b0",
        row: 0,
        column: 0
    )
    #expect(document.resolvedSourceReference(for: reference) == resolvedReference)
    #expect(document.text(for: reference) == nil)
    #expect(document.text(for: resolvedReference) == "Merchant | Detail\nwrapped continuation")

    let encodedReference = try JSONEncoder().encode(reference)
    #expect(try JSONDecoder().decode(DocumentSourceReference.self, from: encodedReference) == reference)
    let referenceObject = try #require(
        JSONSerialization.jsonObject(with: encodedReference) as? [String: Any]
    )
    #expect(referenceObject["lineIndex"] == nil)

    let encoded = try JSONEncoder().encode(document)
    #expect(try JSONDecoder().decode(ExtractedDocument.self, from: encoded) == document)
    let encodedObject = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    let encodedPages = try #require(encodedObject["pages"] as? [[String: Any]])
    let encodedBlocks = try #require(encodedPages[0]["blocks"] as? [[String: Any]])
    let encodedContent = try #require(encodedBlocks[0]["content"] as? [String: Any])
    let encodedRows = try #require(encodedContent["rows"] as? [[String: Any]])
    let encodedCells = try #require(encodedRows[0]["cells"] as? [[String: Any]])
    let encodedLines = try #require(encodedCells[0]["lines"] as? [[String: Any]])
    #expect(encodedLines.map { $0["text"] as? String } == [
        "Merchant | Detail",
        "wrapped continuation",
    ])

    var invalidSchema = encodedObject
    invalidSchema["schemaVersion"] = 99
    expectStructuredDecodeFailure(try JSONSerialization.data(withJSONObject: invalidSchema))

    var invalidStatus = encodedObject
    var statusPages = encodedPages
    statusPages[0]["status"] = "future_status"
    invalidStatus["pages"] = statusPages
    expectStructuredDecodeFailure(try JSONSerialization.data(withJSONObject: invalidStatus))

    var invalidGrid = encodedObject
    var gridPages = encodedPages
    var gridBlocks = try #require(gridPages[0]["blocks"] as? [[String: Any]])
    var gridContent = try #require(gridBlocks[0]["content"] as? [String: Any])
    var gridRows = try #require(gridContent["rows"] as? [[String: Any]])
    var gridCells = try #require(gridRows[0]["cells"] as? [[String: Any]])
    gridCells.removeLast()
    gridRows[0]["cells"] = gridCells
    gridContent["rows"] = gridRows
    gridBlocks[0]["content"] = gridContent
    gridPages[0]["blocks"] = gridBlocks
    invalidGrid["pages"] = gridPages
    expectStructuredDecodeFailure(try JSONSerialization.data(withJSONObject: invalidGrid))
}

@Test func unresolvedCellKeepsPositionedLinesAndDifferentDetectorText() throws {
    let cell = TableCell(
        content: .unresolved(
            lines: [
                TextLine(
                    text: "Positioned source",
                    bounds: DocumentBounds(x: 0.1, y: 0.2, width: 0.3, height: 0.04)
                ),
            ],
            candidateText: "Detector joined value"
        )
    )
    let encoded = try JSONEncoder().encode(
        TableBlock(rows: [TableRow(cells: [cell])])
    )
    let decoded = try JSONDecoder().decode(TableBlock.self, from: encoded)
    let decodedCell = try #require(decoded.rows.first?.cells.first)

    #expect(decodedCell.lines.map(\.text) == ["Positioned source"])
    #expect(decodedCell.unresolvedCandidateText == "Detector joined value")
    #expect(decodedCell.joinedText == nil)
}

@Test func unresolvedCellWithoutEvidenceDoesNotLookLikeConfirmedEmptyText() {
    let unresolved = TableCell(content: .unresolved(lines: [], candidateText: nil))
    let empty = TableCell(content: .empty)

    #expect(unresolved.joinedText == nil)
    #expect(empty.joinedText == "")

    let block = DocumentBlock(
        id: "p0-b0",
        content: .table(TableBlock(rows: [TableRow(cells: [unresolved])]))
    )
    let document = ExtractedDocument(
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
        pages: [DocumentPage(
            pageIndex: 0,
            size: PageSize(width: 1, height: 1),
            status: .extracted,
            blocks: [block]
        )],
        warnings: []
    )
    let source = DocumentSourceReference(
        pageIndex: 0,
        blockID: "p0-b0",
        row: 0,
        column: 0
    )
    #expect(document.text(for: source) == nil)
}

@Test func structuredJSONHandlesNullsAndRejectsEmptyBoundsOrInvalidIdentity() throws {
    let lineWithNull = try JSONDecoder().decode(
        TextLine.self,
        from: Data(#"{"text":"Source","bounds":null}"#.utf8)
    )
    let reencodedLine = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(lineWithNull)) as? [String: Any]
    )
    #expect(reencodedLine["bounds"] == nil)

    do {
        _ = try JSONDecoder().decode(
            DocumentBounds.self,
            from: Data(#"{"x":0,"y":0,"width":0,"height":0.1}"#.utf8)
        )
        Issue.record("Zero-area source bounds unexpectedly decoded")
    } catch {
        // Unknown locations must be omitted, not encoded as empty rectangles.
    }

    let block = DocumentBlock(
        id: "p0-b0",
        content: .text(TextBlock(lines: [TextLine(text: "Source")]))
    )
    let inspection = DocumentInspection(
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
    )
    let document = ExtractedDocument(
        inspection: inspection,
        pages: [DocumentPage(
            pageIndex: 0,
            size: PageSize(width: 612, height: 792),
            status: .extracted,
            blocks: [block]
        )],
        warnings: []
    )
    let encoded = try JSONEncoder().encode(document)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var invalidInspection = try #require(object["inspection"] as? [String: Any])
    invalidInspection["engineVersion"] = ""
    object["inspection"] = invalidInspection
    expectStructuredDecodeFailure(try JSONSerialization.data(withJSONObject: object))

    invalidInspection["engineVersion"] = "test"
    invalidInspection["processingTimeMilliseconds"] = -1
    object["inspection"] = invalidInspection
    expectStructuredDecodeFailure(try JSONSerialization.data(withJSONObject: object))
}

// MARK: - Fixture helpers

private func tableRows(_ table: TableBlock) -> [[String]] {
    table.rows.map { row in
        row.cells.map { $0.joinedText ?? "<unresolved>" }
    }
}

private func tableSlots(_ table: TableBlock) -> [(row: Int, column: Int, cell: TableCell)] {
    table.rows.enumerated().flatMap { row, tableRow in
        tableRow.cells.enumerated().map { column, cell in
            (row: row, column: column, cell: cell)
        }
    }
}

private struct RetroBudgetInterpretedValue: Codable, Equatable {
    let amountMinor: Int
    let currency: String
    let source: DocumentSourceReference
    let expectedSourceText: String

    func matchesSource(in document: ExtractedDocument) -> Bool {
        document.text(for: source) == expectedSourceText
    }
}

private func assertNormalized(_ bounds: DocumentBounds) {
    #expect(bounds.x.isFinite)
    #expect(bounds.y.isFinite)
    #expect(bounds.width.isFinite)
    #expect(bounds.height.isFinite)
    #expect(bounds.x >= 0 && bounds.x <= 1)
    #expect(bounds.y >= 0 && bounds.y <= 1)
    #expect(bounds.width > 0 && bounds.width <= 1)
    #expect(bounds.height > 0 && bounds.height <= 1)
    #expect(bounds.x + bounds.width <= 1.000_001)
    #expect(bounds.y + bounds.height <= 1.000_001)
}

private func expectStructuredDecodeFailure(_ data: Data) {
    do {
        _ = try JSONDecoder().decode(ExtractedDocument.self, from: data)
        Issue.record("Invalid structured-document JSON unexpectedly decoded")
    } catch {
        // Expected for unsupported schema, enum, and grid values.
    }
}

private func normalizedSemanticJSON(_ data: Data) throws -> Data {
    var object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    var inspection = try #require(object["inspection"] as? [String: Any])
    inspection["processingTimeMilliseconds"] = 0
    object["inspection"] = inspection
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func borderlessRegisterPDF() -> Data {
    let content = """
    BT
    /F1 10 Tf
    1 0 0 1 40 760 Tm (Before borderless table) Tj
    1 0 0 1 50 700 Tm (Code) Tj
    1 0 0 1 145 700 Tm (Label) Tj
    1 0 0 1 360 700 Tm (Out) Tj
    1 0 0 1 450 700 Tm (In) Tj
    1 0 0 1 50 678 Tm (R-01) Tj
    1 0 0 1 145 678 Tm (ALPHA) Tj
    1 0 0 1 360 678 Tm (1.00) Tj
    1 0 0 1 50 656 Tm (R-02) Tj
    1 0 0 1 145 656 Tm (BETA) Tj
    1 0 0 1 450 656 Tm (1.00) Tj
    1 0 0 1 50 634 Tm (R-03) Tj
    1 0 0 1 145 634 Tm (REPEAT) Tj
    1 0 0 1 450 634 Tm (4.50) Tj
    1 0 0 1 50 612 Tm (R-03) Tj
    1 0 0 1 145 612 Tm (REPEAT) Tj
    1 0 0 1 450 612 Tm (4.50) Tj
    1 0 0 1 50 590 Tm (R-05) Tj
    1 0 0 1 145 590 Tm (SINGLE) Tj
    1 0 0 1 360 590 Tm (7.00) Tj
    1 0 0 1 50 568 Tm (R-06) Tj
    1 0 0 1 145 568 Tm (GAMMA) Tj
    1 0 0 1 450 568 Tm (8.00) Tj
    1 0 0 1 50 546 Tm (R-07) Tj
    1 0 0 1 145 546 Tm (DELTA) Tj
    1 0 0 1 360 546 Tm (9.00) Tj
    1 0 0 1 50 524 Tm (R-08) Tj
    1 0 0 1 145 524 Tm (OMEGA) Tj
    1 0 0 1 450 524 Tm (10.00) Tj
    1 0 0 1 40 450 Tm (After borderless table) Tj
    ET
    """
    return makeTextAndGridPDF([content])
}

private func continuationTablesPDF() -> Data {
    let pageOne = continuationTablePage(
        introduction: "Page one introduction",
        firstRow: ("A-1", "ALPHA", "2.00", ""),
        secondRow: ("A-2", "REPEAT", "", "2.00"),
        note: "Page one note"
    )
    let pageTwo = continuationTablePage(
        introduction: "Page two introduction",
        firstRow: ("B-1", "BETA", "", "2.00"),
        secondRow: ("B-2", "REPEAT", "2.00", ""),
        note: "Page two note"
    )
    return makeTextAndGridPDF([pageOne, pageTwo])
}

private func continuationTablePage(
    introduction: String,
    firstRow: (String, String, String, String),
    secondRow: (String, String, String, String),
    note: String
) -> String {
    """
    0.7 w
    40 700 m 500 700 l
    40 670 m 500 670 l
    40 640 m 500 640 l
    40 610 m 500 610 l
    40 700 m 40 610 l
    120 700 m 120 610 l
    330 700 m 330 610 l
    420 700 m 420 610 l
    500 700 m 500 610 l
    S
    BT
    /F1 10 Tf
    1 0 0 1 40 760 Tm (\(introduction)) Tj
    1 0 0 1 50 684 Tm (Key) Tj
    1 0 0 1 130 684 Tm (Detail) Tj
    1 0 0 1 340 684 Tm (Out) Tj
    1 0 0 1 430 684 Tm (In) Tj
    1 0 0 1 50 654 Tm (\(firstRow.0)) Tj
    1 0 0 1 130 654 Tm (\(firstRow.1)) Tj
    1 0 0 1 340 654 Tm (\(firstRow.2)) Tj
    1 0 0 1 430 654 Tm (\(firstRow.3)) Tj
    1 0 0 1 50 624 Tm (\(secondRow.0)) Tj
    1 0 0 1 130 624 Tm (\(secondRow.1)) Tj
    1 0 0 1 340 624 Tm (\(secondRow.2)) Tj
    1 0 0 1 430 624 Tm (\(secondRow.3)) Tj
    1 0 0 1 40 540 Tm (\(note)) Tj
    ET
    """
}

private func inventedStatementPDF() -> Data {
    let pageZeroContent = """
    0.7 w
    40 690 m 520 690 l
    40 655 m 520 655 l
    40 620 m 520 620 l
    40 585 m 520 585 l
    40 550 m 520 550 l
    40 515 m 520 515 l
    40 445 m 520 445 l
    40 690 m 40 445 l
    120 690 m 120 445 l
    360 690 m 360 445 l
    445 690 m 445 445 l
    520 690 m 520 445 l
    S
    BT
    /F1 9 Tf
    1 0 0 1 40 760 Tm (INVENTED COMMUNITY BANK) Tj
    1 0 0 1 40 742 Tm (Statement period: 01 Jan - 31 Jan) Tj
    1 0 0 1 40 724 Tm (Currency: USD) Tj
    1 0 0 1 40 706 Tm (Account ending 4242) Tj
    1 0 0 1 50 674 Tm (Date) Tj
    1 0 0 1 130 674 Tm (Description) Tj
    1 0 0 1 370 674 Tm (Amount) Tj
    1 0 0 1 455 674 Tm (Balance) Tj
    1 0 0 1 50 639 Tm (03 Jan) Tj
    1 0 0 1 130 639 Tm (COFFEE HOUSE) Tj
    1 0 0 1 370 639 Tm (12.34) Tj
    1 0 0 1 455 639 Tm (987.66) Tj
    1 0 0 1 50 604 Tm (04 Jan) Tj
    1 0 0 1 130 604 Tm (REFUND SHOP) Tj
    1 0 0 1 370 604 Tm (5.00 CR) Tj
    1 0 0 1 50 569 Tm (05 Jan) Tj
    1 0 0 1 130 569 Tm (BOOKSTORE) Tj
    1 0 0 1 370 569 Tm (20.00) Tj
    1 0 0 1 455 569 Tm (972.66) Tj
    1 0 0 1 50 534 Tm (05 Jan) Tj
    1 0 0 1 130 534 Tm (BOOKSTORE) Tj
    1 0 0 1 370 534 Tm (20.00) Tj
    1 0 0 1 455 534 Tm (952.66) Tj
    1 0 0 1 50 499 Tm (06 Jan) Tj
    1 0 0 1 130 499 Tm (LONG MERCHANT) Tj
    1 0 0 1 130 484 Tm (DESCRIPTION | CONTINUED) Tj
    1 0 0 1 370 499 Tm (10.00) Tj
    1 0 0 1 455 499 Tm (942.66) Tj
    1 0 0 1 40 370 Tm (Statement summary) Tj
    1 0 0 1 40 352 Tm (Purchases: 4) Tj
    1 0 0 1 40 334 Tm (Credits: 1) Tj
    ET
    """

    let pageOneContent = """
    0.7 w
    40 690 m 520 690 l
    40 655 m 520 655 l
    40 620 m 520 620 l
    40 585 m 520 585 l
    40 550 m 520 550 l
    40 690 m 40 550 l
    120 690 m 120 550 l
    360 690 m 360 550 l
    445 690 m 445 550 l
    520 690 m 520 550 l
    S
    BT
    /F1 9 Tf
    1 0 0 1 40 760 Tm (INVENTED COMMUNITY BANK) Tj
    1 0 0 1 40 742 Tm (Statement period continues) Tj
    1 0 0 1 50 674 Tm (Date) Tj
    1 0 0 1 130 674 Tm (Description) Tj
    1 0 0 1 370 674 Tm (Amount) Tj
    1 0 0 1 455 674 Tm (Balance) Tj
    1 0 0 1 50 639 Tm (08 Jan) Tj
    1 0 0 1 130 639 Tm (GROCER) Tj
    1 0 0 1 370 639 Tm (10.00) Tj
    1 0 0 1 455 639 Tm (932.66) Tj
    1 0 0 1 50 604 Tm (09 Jan) Tj
    1 0 0 1 130 604 Tm (TRANSFER) Tj
    1 0 0 1 370 604 Tm (15.00 CR) Tj
    1 0 0 1 455 604 Tm (947.66) Tj
    1 0 0 1 40 480 Tm (Page two summary) Tj
    1 0 0 1 40 462 Tm (Printed purchases: 72.34) Tj
    1 0 0 1 40 444 Tm (Printed credits: 20.00) Tj
    1 0 0 1 40 426 Tm (Closing balance: 947.66) Tj
    ET
    """

    return makeTextAndGridPDF([pageZeroContent, pageOneContent])
}

private func textOnlyPDF() -> Data {
    let content = """
    BT
    /F1 12 Tf
    1 0 0 1 60 720 Tm (Statement details) Tj
    1 0 0 1 60 690 Tm (No detected table here) Tj
    1 0 0 1 60 660 Tm (Keep this line separate) Tj
    ET
    """
    return makeTextAndGridPDF([content])
}

private func financialStringFormsPDF() -> Data {
    let content = """
    BT
    /F1 12 Tf
    1 0 0 1 60 720 Tm (03 Jan) Tj
    1 0 0 1 60 690 Tm (01/02) Tj
    1 0 0 1 60 660 Tm (5.00 CR) Tj
    1 0 0 1 60 630 Tm (\\(12.34\\)) Tj
    1 0 0 1 60 600 Tm (1.234,56) Tj
    ET
    """
    return makeTextAndGridPDF([content])
}

private func multipleTablesPDF() -> Data {
    let content = """
    0.7 w
    40 670 100 30 re
    140 670 100 30 re
    40 640 100 30 re
    140 640 100 30 re
    40 610 100 30 re
    140 610 100 30 re
    330 510 100 30 re
    430 510 100 30 re
    330 480 100 30 re
    430 480 100 30 re
    330 450 100 30 re
    430 450 100 30 re
    S
    BT
    /F1 10 Tf
    1 0 0 1 40 760 Tm (Two independent tables) Tj
    1 0 0 1 50 684 Tm (A1) Tj
    1 0 0 1 150 684 Tm (B1) Tj
    1 0 0 1 50 654 Tm (A2) Tj
    1 0 0 1 150 654 Tm (B2) Tj
    1 0 0 1 50 624 Tm (A3) Tj
    1 0 0 1 150 624 Tm (B3) Tj
    1 0 0 1 340 524 Tm (C1) Tj
    1 0 0 1 440 524 Tm (D1) Tj
    1 0 0 1 340 494 Tm (C2) Tj
    1 0 0 1 440 494 Tm (D2) Tj
    1 0 0 1 340 464 Tm (C3) Tj
    1 0 0 1 440 464 Tm (D3) Tj
    1 0 0 1 40 410 Tm (After both tables) Tj
    ET
    """
    return makeTextAndGridPDF([content])
}

private func textContent(_ text: String) -> String {
    "BT /F1 12 Tf 1 0 0 1 60 720 Tm (\(text)) Tj ET"
}

private func mixedTextAndImagePDF() -> Data {
    let text = """
    BT /F1 12 Tf
    1 0 0 1 60 720 Tm (Embedded text page) Tj
    1 0 0 1 60 690 Tm (Native Swift package) Tj
    1 0 0 1 60 660 Tm (Enough embedded text for extraction) Tj
    ET
    """
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

private func rotatedOffsetCropPDF() -> Data {
    let content = "BT /F1 12 Tf 1 0 0 1 60 120 Tm (Rotated cropped text) Tj ET"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /CropBox [20 30 180 270] /Rotate 90 /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    return makePDF(objects)
}

private func makeTextAndGridPDF(
    _ pageContents: [String],
    pageSize: (width: Int, height: Int) = (612, 792)
) -> Data {
    let pageCount = pageContents.count
    let firstContentObject = 3 + pageCount
    let fontObject = 3 + (2 * pageCount)
    let kids = (0..<pageCount).map { "\($0 + 3) 0 R" }.joined(separator: " ")
    var objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [\(kids)] /Count \(pageCount) >>",
    ]
    for page in 0..<pageCount {
        objects.append(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(pageSize.width) \(pageSize.height)] /Resources << /Font << /F1 \(fontObject) 0 R >> >> /Contents \(firstContentObject + page) 0 R >>"
        )
    }
    for content in pageContents {
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
    }
    objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
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

private extension DocumentBlock {
    var text: TextBlock? {
        guard case let .text(value) = content else { return nil }
        return value
    }

    var table: TableBlock? {
        guard case let .table(value) = content else { return nil }
        return value
    }

    var contentText: String {
        switch content {
        case let .text(value): value.joinedText
        case let .table(value):
            value.rows.flatMap(\.cells).compactMap(\.joinedText).joined(separator: "\n")
        }
    }
}
