import Foundation

/// A structured representation of a locally extracted PDF.
public struct ExtractedDocument: Codable, Sendable, Hashable {
    /// The current structured-document schema version.
    public static let currentSchemaVersion = 1

    /// The schema version used for this document.
    public let schemaVersion: Int

    /// Inspection information collected during extraction.
    public let inspection: DocumentInspection

    /// Requested pages in their original document order.
    public let pages: [DocumentPage]

    /// Quality warnings collected during extraction.
    public let warnings: [DocumentWarning]

    /// Zero-based pages the engine recommends routing through OCR.
    public var pagesNeedingOCR: [Int] {
        inspection.pagesNeedingOCR
    }

    /// Creates a structured document.
    public init(
        schemaVersion: Int = ExtractedDocument.currentSchemaVersion,
        inspection: DocumentInspection,
        pages: [DocumentPage],
        warnings: [DocumentWarning]
    ) {
        precondition(schemaVersion == Self.currentSchemaVersion, "Unsupported document schema version")
        precondition(
            !pages.isEmpty
                && isValidStructuredDocument(inspection: inspection, pages: pages, warnings: warnings),
            "Structured document metadata and page coverage are invalid"
        )
        self.schemaVersion = schemaVersion
        self.inspection = inspection
        self.pages = pages
        self.warnings = warnings
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case inspection
        case pages
        case warnings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw StructuredDocumentCodingError.invalidValue(
                "Unsupported structured-document schema version \(schemaVersion)"
            )
        }

        let inspection = try container.decode(DocumentInspection.self, forKey: .inspection)
        let pages = try container.decode([DocumentPage].self, forKey: .pages)
        let warnings = try container.decode([DocumentWarning].self, forKey: .warnings)

        guard !pages.isEmpty,
            isValidStructuredDocument(inspection: inspection, pages: pages, warnings: warnings)
        else {
            throw StructuredDocumentCodingError.invalidValue(
                "Structured document metadata and page coverage are invalid"
            )
        }

        var pageIndexes = Set<Int>()
        var blockIDs = Set<String>()
        var previousPageIndex: Int?
        for page in pages {
            guard pageIndexes.insert(page.pageIndex).inserted else {
                throw StructuredDocumentCodingError.invalidValue(
                    "A structured document contains a duplicate page index"
                )
            }
            guard previousPageIndex.map({ $0 < page.pageIndex }) ?? true else {
                throw StructuredDocumentCodingError.invalidValue(
                    "Structured document pages must be in ascending page order"
                )
            }
            guard page.pageIndex < inspection.pageCount else {
                throw StructuredDocumentCodingError.invalidValue(
                    "A structured document page index is outside the source document"
                )
            }
            previousPageIndex = page.pageIndex
            for block in page.blocks {
                guard blockIDs.insert(block.id).inserted else {
                    throw StructuredDocumentCodingError.invalidValue(
                        "A structured document contains a duplicate block ID"
                    )
                }
            }
        }

        self.schemaVersion = schemaVersion
        self.inspection = inspection
        self.pages = pages
        self.warnings = warnings
    }

    /// Finds a block identified by a source reference.
    public func block(for reference: DocumentSourceReference) -> DocumentBlock? {
        guard let page = pages.first(where: { $0.pageIndex == reference.pageIndex }) else {
            return nil
        }
        return page.blocks.first(where: { $0.id == reference.blockID })
    }

    /// Finds a table cell identified by a source reference.
    public func cell(for reference: DocumentSourceReference) -> TableCell? {
        guard let row = reference.row, let column = reference.column,
            let block = block(for: reference),
            case let .table(table) = block.content
        else {
            return nil
        }
        return table.cell(row: row, column: column)
    }

    /// Finds a text line identified by a source reference.
    public func line(for reference: DocumentSourceReference) -> TextLine? {
        guard let lineIndex = reference.lineIndex, lineIndex >= 0,
            let block = block(for: reference)
        else {
            return nil
        }

        switch block.content {
        case let .text(text):
            guard reference.row == nil, reference.column == nil else { return nil }
            guard text.lines.indices.contains(lineIndex) else { return nil }
            return text.lines[lineIndex]
        case .table:
            guard let cell = cell(for: reference), cell.lines.indices.contains(lineIndex) else {
                return nil
            }
            return cell.lines[lineIndex]
        }
    }

    /// Resolves a source reference to its extracted text.
    public func text(for reference: DocumentSourceReference) -> String? {
        guard let block = block(for: reference) else { return nil }

        if reference.lineIndex != nil {
            return line(for: reference)?.text
        }

        switch block.content {
        case let .text(text):
            guard reference.row == nil, reference.column == nil else { return nil }
            return text.joinedText
        case .table:
            return cell(for: reference)?.joinedText
        }
    }

    /// Finds a page by its original zero-based PDF index.
    public func page(at pageIndex: Int) -> DocumentPage? {
        pages.first { $0.pageIndex == pageIndex }
    }
}

/// A page included in a structured extraction result.
public struct DocumentPage: Codable, Sendable, Hashable {
    /// The original zero-based PDF page index.
    public let pageIndex: Int

    /// The upright visible page size in points.
    public let size: PageSize

    /// The extraction status for this page.
    public let status: DocumentPageStatus

    /// Blocks in inferred reading order.
    public let blocks: [DocumentBlock]

    /// Creates a structured page.
    public init(
        pageIndex: Int,
        size: PageSize,
        status: DocumentPageStatus,
        blocks: [DocumentBlock]
    ) {
        precondition(pageIndex >= 0, "Page indexes are zero-based and cannot be negative")
        self.pageIndex = pageIndex
        self.size = size
        self.status = status
        self.blocks = blocks
    }

    private enum CodingKeys: String, CodingKey {
        case pageIndex
        case size
        case status
        case blocks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pageIndex = try container.decode(Int.self, forKey: .pageIndex)
        guard pageIndex >= 0 else {
            throw StructuredDocumentCodingError.invalidValue(
                "Page indexes are zero-based and cannot be negative"
            )
        }
        self.pageIndex = pageIndex
        self.size = try container.decode(PageSize.self, forKey: .size)
        self.status = try container.decode(DocumentPageStatus.self, forKey: .status)
        self.blocks = try container.decode([DocumentBlock].self, forKey: .blocks)
    }
}

/// The upright visible dimensions of a PDF page in points.
public struct PageSize: Codable, Sendable, Hashable {
    /// The page width in points.
    public let width: Double

    /// The page height in points.
    public let height: Double

    /// Creates a page size with positive finite dimensions.
    public init(width: Double, height: Double) {
        precondition(width.isFinite && height.isFinite, "Page dimensions must be finite")
        precondition(width > 0 && height > 0, "Page dimensions must be positive")
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let width = try container.decode(Double.self, forKey: .width)
        let height = try container.decode(Double.self, forKey: .height)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw StructuredDocumentCodingError.invalidValue(
                "Page dimensions must be positive finite values"
            )
        }
        self.width = width
        self.height = height
    }
}

/// A normalized source rectangle in top-left page coordinates.
public struct DocumentBounds: Codable, Sendable, Hashable {
    /// The normalized distance from the left edge of the visible page.
    public let x: Double

    /// The normalized distance from the top edge of the visible page.
    public let y: Double

    /// The normalized rectangle width.
    public let width: Double

    /// The normalized rectangle height.
    public let height: Double

    /// Creates normalized bounds.
    ///
    /// Values are relative to the upright visible page after crop and
    /// rotation. The native engine clips intersecting geometry to the visible
    /// page and omits geometry with no visible intersection. Consumers should
    /// treat `nil` as unavailable source location.
    public init(x: Double, y: Double, width: Double, height: Double) {
        precondition(
            x.isFinite && y.isFinite && width.isFinite && height.isFinite
                && x >= 0 && x <= 1 && y >= 0 && y <= 1
                && width > 0 && width <= 1 && height > 0 && height <= 1
                && x + width <= 1 && y + height <= 1,
            "Bounds must be finite and lie inside the visible page"
        )
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
        case width
        case height
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(Double.self, forKey: .x)
        let y = try container.decode(Double.self, forKey: .y)
        let width = try container.decode(Double.self, forKey: .width)
        let height = try container.decode(Double.self, forKey: .height)
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
            x >= 0, x <= 1, y >= 0, y <= 1,
            width > 0, width <= 1, height > 0, height <= 1,
            x + width <= 1, y + height <= 1
        else {
            throw StructuredDocumentCodingError.invalidValue(
                "Bounds must be finite and lie inside the visible page"
            )
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// The processing status of a requested page.
public enum DocumentPageStatus: String, Codable, Sendable, Hashable {
    /// The native engine processed the page, which can still have no blocks.
    case extracted

    /// The page needs OCR, which Turnip does not perform.
    case needsOCR

    /// The page could not be extracted but the document result remains usable.
    case extractionFailed
}

/// A reading-order block on a PDF page.
public struct DocumentBlock: Codable, Sendable, Hashable {
    /// The deterministic ID scoped to the extracted document.
    public let id: String

    /// The block's source bounds, when the engine reported them.
    public let bounds: DocumentBounds?

    /// The block's tagged content.
    public let content: Content

    /// Creates a document block.
    public init(id: String, bounds: DocumentBounds? = nil, content: Content) {
        precondition(!id.isEmpty, "Block IDs cannot be empty")
        self.id = id
        self.bounds = bounds
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case bounds
        case content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw StructuredDocumentCodingError.invalidValue("Block IDs cannot be empty")
        }
        self.id = id
        self.bounds = try container.decodeIfPresent(DocumentBounds.self, forKey: .bounds)
        self.content = try container.decode(Content.self, forKey: .content)
    }

    /// The content variants supported by the structured-document schema.
    public enum Content: Codable, Sendable, Hashable {
        /// A block of text outside detected tables.
        case text(TextBlock)

        /// A page-local table fragment.
        case table(TableBlock)

        /// Creates a text content value.
        public init(text: TextBlock) {
            self = .text(text)
        }

        /// Creates a table content value.
        public init(table: TableBlock) {
            self = .table(table)
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case lines
            case rowCount
            case columnCount
            case cells
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                let lines = try container.decode([TextLine].self, forKey: .lines)
                self = .text(TextBlock(lines: lines))
            case "table":
                let rowCount = try container.decode(Int.self, forKey: .rowCount)
                let columnCount = try container.decode(Int.self, forKey: .columnCount)
                let cells = try container.decode([TableCell].self, forKey: .cells)
                self = .table(
                    try TableBlock(validating: rowCount, columnCount: columnCount, cells: cells)
                )
            default:
                throw StructuredDocumentCodingError.invalidValue(
                    "Unknown document block content type \"\(type)\""
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case let .text(text):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("text", forKey: .type)
                try container.encode(text.lines, forKey: .lines)
            case let .table(table):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("table", forKey: .type)
                try container.encode(table.rowCount, forKey: .rowCount)
                try container.encode(table.columnCount, forKey: .columnCount)
                try container.encode(table.cells, forKey: .cells)
            }
        }
    }
}

/// Text outside a detected table.
public struct TextBlock: Codable, Sendable, Hashable {
    /// Extracted lines in source reading order.
    public let lines: [TextLine]

    /// Creates a text block.
    public init(lines: [TextLine]) {
        self.lines = lines
    }

    /// The lines joined with newline characters.
    public var joinedText: String {
        lines.map(\.text).joined(separator: "\n")
    }
}

/// A page-local table fragment.
public struct TableBlock: Codable, Sendable, Hashable {
    /// The number of logical rows in the table grid.
    public let rowCount: Int

    /// The number of logical columns in the table grid.
    public let columnCount: Int

    /// Explicit cells in source row and column order.
    ///
    /// A spanning cell appears once at its top-left anchor. Slots covered by
    /// that span are represented by its `rowSpan` and `columnSpan`, not by
    /// invented duplicate cells. Every other slot is represented explicitly;
    /// use `.unresolved` when content evidence is uncertain and `.empty` only
    /// when blankness is established.
    public let cells: [TableCell]

    /// Creates a table block.
    public init(rowCount: Int, columnCount: Int, cells: [TableCell]) {
        precondition(rowCount > 0 && columnCount > 0, "Table dimensions must be positive")
        precondition(
            Self.isValid(cells: cells, rowCount: rowCount, columnCount: columnCount),
            "Table cells must fit inside the table grid"
        )
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.cells = cells
    }

    fileprivate init(validating rowCount: Int, columnCount: Int, cells: [TableCell]) throws {
        guard rowCount > 0, columnCount > 0,
            Self.isValid(cells: cells, rowCount: rowCount, columnCount: columnCount)
        else {
            throw StructuredDocumentCodingError.invalidValue(
                "Table cells must cover a positive table grid without overlap"
            )
        }
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.cells = cells
    }

    private enum CodingKeys: String, CodingKey {
        case rowCount
        case columnCount
        case cells
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rowCount = try container.decode(Int.self, forKey: .rowCount)
        let columnCount = try container.decode(Int.self, forKey: .columnCount)
        let cells = try container.decode([TableCell].self, forKey: .cells)
        try self.init(validating: rowCount, columnCount: columnCount, cells: cells)
    }

    /// Returns the cell covering a zero-based grid slot, if one is present.
    public func cell(row: Int, column: Int) -> TableCell? {
        guard row >= 0, row < rowCount, column >= 0, column < columnCount else {
            return nil
        }
        return cells.first {
            row >= $0.row && row < $0.row + $0.rowSpan
                && column >= $0.column && column < $0.column + $0.columnSpan
        }
    }

    fileprivate static func isValid(cells: [TableCell], rowCount: Int, columnCount: Int) -> Bool {
        var coveredSlots = Set<TableSlot>()
        var previousRow = -1
        var previousColumn = -1

        for cell in cells {
            guard cell.row >= 0, cell.column >= 0,
                cell.rowSpan > 0, cell.columnSpan > 0,
                cell.rowSpan <= rowCount, cell.columnSpan <= columnCount,
                cell.row < rowCount, cell.column < columnCount,
                cell.row <= rowCount - cell.rowSpan,
                cell.column <= columnCount - cell.columnSpan,
                cell.row > previousRow
                    || (cell.row == previousRow && cell.column > previousColumn)
            else {
                return false
            }

            previousRow = cell.row
            previousColumn = cell.column
            for row in cell.row..<(cell.row + cell.rowSpan) {
                for column in cell.column..<(cell.column + cell.columnSpan) {
                    guard coveredSlots.insert(TableSlot(row: row, column: column)).inserted else {
                        return false
                    }
                }
            }
        }

        let slotCount = rowCount.multipliedReportingOverflow(by: columnCount)
        return !slotCount.overflow && coveredSlots.count == slotCount.partialValue
    }
}

private struct TableSlot: Hashable {
    let row: Int
    let column: Int
}

private func isValidTableCellEvidence(
    state: TableCellState,
    detectedText: String?,
    lines: [TextLine]
) -> Bool {
    guard detectedText.map({ !$0.isEmpty }) ?? true else { return false }
    return switch state {
    case .extracted:
        !lines.isEmpty && detectedText == nil
    case .empty:
        lines.isEmpty && detectedText == nil
    case .unresolved:
        true
    }
}

/// A cell in a page-local table grid.
public struct TableCell: Codable, Sendable, Hashable {
    /// The zero-based logical row of the cell's top-left anchor.
    public let row: Int

    /// The zero-based logical column of the cell's top-left anchor.
    public let column: Int

    /// The number of logical rows covered by this cell.
    public let rowSpan: Int

    /// The number of logical columns covered by this cell.
    public let columnSpan: Int

    /// The engine-supported semantic role of the cell.
    public let role: TableCellRole

    /// Whether the cell contains extracted, blank, or unresolved content.
    public let state: TableCellState

    /// The detector's raw cell text when it disagrees with positioned lines.
    ///
    /// This is present only for unresolved evidence. It preserves a detector
    /// association without pretending it has a reliable source line or bound.
    public let detectedText: String?

    /// Extracted lines in the cell.
    public let lines: [TextLine]

    /// The union of the cell's positioned text bounds, when available.
    ///
    /// This does not describe the full painted grid rectangle.
    public let bounds: DocumentBounds?

    /// Creates a table cell.
    public init(
        row: Int,
        column: Int,
        rowSpan: Int = 1,
        columnSpan: Int = 1,
        role: TableCellRole = .unknown,
        state: TableCellState = .unresolved,
        detectedText: String? = nil,
        lines: [TextLine] = [],
        bounds: DocumentBounds? = nil
    ) {
        precondition(row >= 0 && column >= 0, "Cell indexes cannot be negative")
        precondition(rowSpan > 0 && columnSpan > 0, "Cell spans must be positive")
        precondition(
            isValidTableCellEvidence(
                state: state,
                detectedText: detectedText,
                lines: lines
            ),
            "Cell state, detector text, and source lines are inconsistent"
        )
        self.row = row
        self.column = column
        self.rowSpan = rowSpan
        self.columnSpan = columnSpan
        self.role = role
        self.state = state
        self.detectedText = detectedText
        self.lines = lines
        self.bounds = bounds
    }

    /// The source lines joined with newlines, or detector text when no source
    /// line could be associated.
    ///
    /// This is an empty string for a confirmed empty cell and `nil` for an
    /// unresolved cell with no text evidence.
    public var joinedText: String? {
        if !lines.isEmpty {
            return lines.map(\.text).joined(separator: "\n")
        }
        if let detectedText {
            return detectedText
        }
        return state == .empty ? "" : nil
    }

    private enum CodingKeys: String, CodingKey {
        case row
        case column
        case rowSpan
        case columnSpan
        case role
        case state
        case detectedText
        case lines
        case bounds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let row = try container.decode(Int.self, forKey: .row)
        let column = try container.decode(Int.self, forKey: .column)
        let rowSpan = try container.decode(Int.self, forKey: .rowSpan)
        let columnSpan = try container.decode(Int.self, forKey: .columnSpan)
        guard row >= 0, column >= 0, rowSpan > 0, columnSpan > 0 else {
            throw StructuredDocumentCodingError.invalidValue(
                "Cell indexes cannot be negative and spans must be positive"
            )
        }
        self.row = row
        self.column = column
        self.rowSpan = rowSpan
        self.columnSpan = columnSpan
        let role = try container.decode(TableCellRole.self, forKey: .role)
        let state = try container.decode(TableCellState.self, forKey: .state)
        let detectedText = try container.decodeIfPresent(String.self, forKey: .detectedText)
        let lines = try container.decode([TextLine].self, forKey: .lines)
        guard isValidTableCellEvidence(
            state: state,
            detectedText: detectedText,
            lines: lines
        ) else {
            throw StructuredDocumentCodingError.invalidValue(
                "Cell state, detector text, and source lines are inconsistent"
            )
        }
        self.role = role
        self.state = state
        self.detectedText = detectedText
        self.lines = lines
        self.bounds = try container.decodeIfPresent(DocumentBounds.self, forKey: .bounds)
    }
}

/// The semantic role inferred for a table cell.
public enum TableCellRole: String, Codable, Sendable, Hashable {
    /// A header cell established by extraction evidence.
    case header

    /// A body cell established by extraction evidence.
    case body

    /// The engine could not establish a role.
    case unknown
}

/// The extraction state of a table cell.
public enum TableCellState: String, Codable, Sendable, Hashable {
    /// The cell contains decoded PDF text.
    case extracted

    /// The engine established that the cell is blank.
    case empty

    /// The cell or its contents could not be resolved reliably.
    case unresolved
}

/// One extracted line and its optional source bounds.
public struct TextLine: Codable, Sendable, Hashable {
    /// The decoded PDF text for this line.
    public let text: String

    /// The line's source bounds, when available.
    public let bounds: DocumentBounds?

    /// Creates an extracted text line.
    public init(text: String, bounds: DocumentBounds? = nil) {
        self.text = text
        self.bounds = bounds
    }
}

/// A source address for interpreted document data.
public struct DocumentSourceReference: Codable, Sendable, Hashable {
    /// The original zero-based PDF page index.
    public let pageIndex: Int

    /// The document-scoped block ID.
    public let blockID: String

    /// The zero-based table row, when the reference points into a table.
    public let row: Int?

    /// The zero-based table column, when the reference points into a table.
    public let column: Int?

    /// The zero-based line index within a text block or table cell.
    public let lineIndex: Int?

    /// Creates a source reference.
    public init(
        pageIndex: Int,
        blockID: String,
        row: Int? = nil,
        column: Int? = nil,
        lineIndex: Int? = nil
    ) {
        precondition(pageIndex >= 0, "Page indexes are zero-based and cannot be negative")
        precondition(!blockID.isEmpty, "Block IDs cannot be empty")
        precondition(
            (row == nil) == (column == nil),
            "Table source references must provide both row and column"
        )
        precondition(row.map { $0 >= 0 } ?? true, "Rows cannot be negative")
        precondition(column.map { $0 >= 0 } ?? true, "Columns cannot be negative")
        precondition(lineIndex.map { $0 >= 0 } ?? true, "Line indexes cannot be negative")
        self.pageIndex = pageIndex
        self.blockID = blockID
        self.row = row
        self.column = column
        self.lineIndex = lineIndex
    }

    private enum CodingKeys: String, CodingKey {
        case pageIndex
        case blockID
        case row
        case column
        case lineIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pageIndex = try container.decode(Int.self, forKey: .pageIndex)
        let blockID = try container.decode(String.self, forKey: .blockID)
        let row = try container.decodeIfPresent(Int.self, forKey: .row)
        let column = try container.decodeIfPresent(Int.self, forKey: .column)
        let lineIndex = try container.decodeIfPresent(Int.self, forKey: .lineIndex)
        guard pageIndex >= 0, !blockID.isEmpty,
            (row == nil) == (column == nil),
            row.map({ $0 >= 0 }) ?? true,
            column.map({ $0 >= 0 }) ?? true,
            lineIndex.map({ $0 >= 0 }) ?? true
        else {
            throw StructuredDocumentCodingError.invalidValue("Invalid document source reference")
        }
        self.pageIndex = pageIndex
        self.blockID = blockID
        self.row = row
        self.column = column
        self.lineIndex = lineIndex
    }
}

private enum StructuredDocumentCodingError: Error, CustomStringConvertible {
    case invalidValue(String)

    var description: String {
        switch self {
        case let .invalidValue(message): message
        }
    }
}

private func isStrictlyAscending(_ values: [Int]) -> Bool {
    zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
}

private func areValidPageIndexes(_ values: [Int], pageCount: Int) -> Bool {
    values.allSatisfy { $0 >= 0 && $0 < pageCount } && isStrictlyAscending(values)
}

private func isValidInspectionValues(
    pageCount: Int,
    confidence: Float,
    pagesNeedingOCR: [Int],
    ocrReasonsByPage: [PageOCRReasons],
    layout: DocumentLayout?
) -> Bool {
    guard pageCount > 0, confidence.isFinite,
        areValidPageIndexes(pagesNeedingOCR, pageCount: pageCount),
        areValidPageIndexes(ocrReasonsByPage.map(\.pageIndex), pageCount: pageCount)
    else {
        return false
    }
    guard let layout else { return true }
    return areValidPageIndexes(layout.pagesWithTables, pageCount: pageCount)
        && areValidPageIndexes(layout.pagesWithColumns, pageCount: pageCount)
}

private func isValidStructuredDocument(
    inspection: DocumentInspection,
    pages: [DocumentPage],
    warnings: [DocumentWarning]
) -> Bool {
    guard isValidInspectionValues(
        pageCount: inspection.pageCount,
        confidence: inspection.confidence,
        pagesNeedingOCR: inspection.pagesNeedingOCR,
        ocrReasonsByPage: inspection.ocrReasonsByPage,
        layout: inspection.layout
    ) else {
        return false
    }

    let pageIndexes = pages.map(\.pageIndex)
    let selectedPages = Set(pageIndexes)
    guard isStrictlyAscending(pageIndexes),
        pageIndexes.allSatisfy({ $0 >= 0 && $0 < inspection.pageCount }),
        pages.filter({ $0.status == .needsOCR }).map(\.pageIndex)
            == inspection.pagesNeedingOCR,
        warnings.allSatisfy({
            areValidPageIndexes($0.pageIndexes, pageCount: inspection.pageCount)
                && $0.pageIndexes.allSatisfy(selectedPages.contains)
        })
    else {
        return false
    }

    var blockIDs = Set<String>()
    for page in pages {
        for (index, block) in page.blocks.enumerated() {
            guard block.id == "p\(page.pageIndex)-b\(index)",
                blockIDs.insert(block.id).inserted
            else {
                return false
            }
        }
    }
    return true
}

// MARK: - Existing public result models

extension DocumentInspection: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case pageCount
        case title
        case confidence
        case processingTimeMilliseconds
        case pagesNeedingOCR
        case ocrReasonsByPage
        case layout
        case hasEncodingIssues
        case engineVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(DocumentKind.self, forKey: .kind)
        pageCount = try container.decode(Int.self, forKey: .pageCount)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        confidence = try container.decode(Float.self, forKey: .confidence)
        let milliseconds = try container.decode(Int64.self, forKey: .processingTimeMilliseconds)
        guard milliseconds >= 0 else {
            throw StructuredDocumentCodingError.invalidValue(
                "Processing time cannot be negative"
            )
        }
        processingTime = .milliseconds(milliseconds)
        let pagesNeedingOCR = try container.decode([Int].self, forKey: .pagesNeedingOCR)
        let ocrReasonsByPage = try container.decode(
            [PageOCRReasons].self,
            forKey: .ocrReasonsByPage
        )
        let layout = try container.decodeIfPresent(DocumentLayout.self, forKey: .layout)
        guard isValidInspectionValues(
            pageCount: pageCount,
            confidence: confidence,
            pagesNeedingOCR: pagesNeedingOCR,
            ocrReasonsByPage: ocrReasonsByPage,
            layout: layout
        ) else {
            throw StructuredDocumentCodingError.invalidValue(
                "Inspection metadata contains invalid page indexes"
            )
        }
        self.pagesNeedingOCR = pagesNeedingOCR
        self.ocrReasonsByPage = ocrReasonsByPage
        self.layout = layout
        self.hasEncodingIssues = try container.decodeIfPresent(Bool.self, forKey: .hasEncodingIssues)
        let engineVersion = try container.decode(String.self, forKey: .engineVersion)
        guard !engineVersion.isEmpty else {
            throw StructuredDocumentCodingError.invalidValue(
                "Engine version cannot be empty"
            )
        }
        self.engineVersion = engineVersion
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(pageCount, forKey: .pageCount)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(processingTime.millisecondsForStructuredDocument, forKey: .processingTimeMilliseconds)
        try container.encode(pagesNeedingOCR, forKey: .pagesNeedingOCR)
        try container.encode(ocrReasonsByPage, forKey: .ocrReasonsByPage)
        try container.encodeIfPresent(layout, forKey: .layout)
        try container.encodeIfPresent(hasEncodingIssues, forKey: .hasEncodingIssues)
        try container.encode(engineVersion, forKey: .engineVersion)
    }
}

extension DocumentKind: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = DocumentKind(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown document kind \"\(rawValue)\""
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension DocumentLayout: Codable {
    private enum CodingKeys: String, CodingKey {
        case isComplex
        case pagesWithTables
        case pagesWithColumns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pagesWithTables = try container.decode([Int].self, forKey: .pagesWithTables)
        let pagesWithColumns = try container.decode([Int].self, forKey: .pagesWithColumns)
        guard isStrictlyAscending(pagesWithTables), pagesWithTables.allSatisfy({ $0 >= 0 }),
            isStrictlyAscending(pagesWithColumns), pagesWithColumns.allSatisfy({ $0 >= 0 })
        else {
            throw StructuredDocumentCodingError.invalidValue(
                "Layout page indexes must be nonnegative and ascending"
            )
        }
        self.isComplex = try container.decode(Bool.self, forKey: .isComplex)
        self.pagesWithTables = pagesWithTables
        self.pagesWithColumns = pagesWithColumns
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isComplex, forKey: .isComplex)
        try container.encode(pagesWithTables, forKey: .pagesWithTables)
        try container.encode(pagesWithColumns, forKey: .pagesWithColumns)
    }
}

extension PageOCRReasons: Codable {
    private enum CodingKeys: String, CodingKey {
        case pageIndex
        case reasons
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pageIndex = try container.decode(Int.self, forKey: .pageIndex)
        guard pageIndex >= 0 else {
            throw StructuredDocumentCodingError.invalidValue(
                "Page indexes are zero-based and cannot be negative"
            )
        }
        self.pageIndex = pageIndex
        self.reasons = try container.decode([String].self, forKey: .reasons)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pageIndex, forKey: .pageIndex)
        try container.encode(reasons, forKey: .reasons)
    }
}

extension DocumentWarning: Codable {
    private enum CodingKeys: String, CodingKey {
        case code
        case pageIndexes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(String.self, forKey: .code)
        kind = DocumentWarning.Kind(warningCode: code)
        let pageIndexes = try container.decode([Int].self, forKey: .pageIndexes)
        guard !code.isEmpty, isStrictlyAscending(pageIndexes), pageIndexes.allSatisfy({ $0 >= 0 }) else {
            throw StructuredDocumentCodingError.invalidValue(
                "Warning codes must be nonempty and page indexes must be nonnegative and ascending"
            )
        }
        self.pageIndexes = pageIndexes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let code = kind.warningCode
        guard !code.isEmpty else {
            throw EncodingError.invalidValue(
                kind,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Warning codes cannot be empty"
                )
            )
        }
        try container.encode(code, forKey: .code)
        try container.encode(pageIndexes, forKey: .pageIndexes)
    }
}

extension DocumentWarning.Kind {
    fileprivate init(warningCode: String) {
        self = switch warningCode {
        case "ocrRequired": .ocrRequired
        case "encodingIssues": .encodingIssues
        default: .unknown(warningCode)
        }
    }

    fileprivate var warningCode: String {
        switch self {
        case .ocrRequired: "ocrRequired"
        case .encodingIssues: "encodingIssues"
        case let .unknown(code): code
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let code = try container.decode(String.self)
        guard !code.isEmpty else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Warning codes cannot be empty"
            )
        }
        self.init(warningCode: code)
    }

    public func encode(to encoder: Encoder) throws {
        let code = warningCode
        guard !code.isEmpty else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Warning codes cannot be empty"
                )
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}

private extension Duration {
    var millisecondsForStructuredDocument: Int64 {
        let components = self.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
        let fractional = components.attoseconds / 1_000_000_000_000_000
        let milliseconds = seconds.partialValue.addingReportingOverflow(fractional)
        precondition(!seconds.overflow && !milliseconds.overflow, "Duration is too large to encode as milliseconds")
        return milliseconds.partialValue
    }
}
