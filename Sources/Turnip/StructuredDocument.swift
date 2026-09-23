import Foundation

/// A structured representation of a locally extracted PDF.
public struct ExtractedDocument: Codable, Sendable, Hashable {
    /// The current structured-document schema version.
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let inspection: DocumentInspection
    public let pages: [DocumentPage]
    public let warnings: [DocumentWarning]

    /// Zero-based pages the engine recommends routing through OCR.
    public var pagesNeedingOCR: [Int] {
        inspection.pagesNeedingOCR
    }

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

    /// Finds the table addressed by a source reference.
    public func table(for reference: DocumentSourceReference) -> TableBlock? {
        guard let block = block(for: reference), case let .table(table) = block.content else {
            return nil
        }
        return table
    }

    /// Finds the literal table slot addressed by a source reference.
    ///
    /// This never follows a covered slot to its span anchor. Use
    /// resolvedCell(for:) only when that resolution is intentional.
    public func cell(for reference: DocumentSourceReference) -> TableCell? {
        guard let row = reference.row, let column = reference.column,
            let table = table(for: reference)
        else {
            return nil
        }
        return table.cell(row: row, column: column)
    }

    /// Resolves a covered table slot only when the caller explicitly asks.
    ///
    /// A reference with a line index must name a literal source line. It is not
    /// redirected through a covered slot.
    public func resolvedCell(for reference: DocumentSourceReference) -> TableCell? {
        guard reference.lineIndex == nil || line(for: reference) != nil,
            let resolved = resolvedSourceReference(for: reference)
        else {
            return nil
        }
        return cell(for: resolved)
    }

    /// Resolves a covered table slot to its anchor while keeping document identity.
    ///
    /// A line reference to a covered slot is invalid because that slot has no
    /// independent source line. This method returns nil instead of inventing an
    /// anchor-line reference.
    public func resolvedSourceReference(
        for reference: DocumentSourceReference
    ) -> DocumentSourceReference? {
        guard let row = reference.row, let column = reference.column,
            let table = table(for: reference),
            let literalCell = table.cell(row: row, column: column)
        else {
            return nil
        }
        if reference.lineIndex != nil, literalCell.state == .covered {
            return nil
        }
        guard reference.lineIndex == nil || line(for: reference) != nil,
            let address = table.resolvedCellAddress(row: row, column: column)
        else {
            return nil
        }
        return DocumentSourceReference(
            pageIndex: reference.pageIndex,
            blockID: reference.blockID,
            row: address.row,
            column: address.column,
            lineIndex: reference.lineIndex
        )
    }

    /// Finds a literal source line identified by a source reference.
    ///
    /// Unresolved cells can retain positioned source lines. This exposes those
    /// lines without treating the cell as confirmed text.
    public func line(for reference: DocumentSourceReference) -> TextLine? {
        guard let lineIndex = reference.lineIndex, lineIndex >= 0,
            let block = block(for: reference)
        else {
            return nil
        }
        switch block.content {
        case let .text(text):
            guard reference.row == nil, reference.column == nil,
                text.lines.indices.contains(lineIndex)
            else {
                return nil
            }
            return text.lines[lineIndex]
        case let .table(table):
            if reference.row == nil, reference.column == nil,
                table.unassignedLines.indices.contains(lineIndex)
            {
                return table.unassignedLines[lineIndex]
            }
            guard let cell = cell(for: reference), cell.lines.indices.contains(lineIndex) else {
                return nil
            }
            return cell.lines[lineIndex]
        }
    }

    /// Finds one original source-line occurrence by its extraction-scoped ID.
    public func line(id: String) -> TextLine? {
        guard let reference = sourceReference(forLineID: id) else { return nil }
        return line(for: reference)
    }

    /// Returns the existing source address for an original source-line ID.
    public func sourceReference(forLineID id: String) -> DocumentSourceReference? {
        for page in pages {
            for block in page.blocks {
                switch block.content {
                case let .text(text):
                    if let line = text.lines.firstIndex(where: { $0.id == id }) {
                        return DocumentSourceReference(
                            pageIndex: page.pageIndex,
                            blockID: block.id,
                            lineIndex: line
                        )
                    }
                case let .table(table):
                    if let line = table.unassignedLines.firstIndex(where: { $0.id == id }) {
                        return DocumentSourceReference(
                            pageIndex: page.pageIndex,
                            blockID: block.id,
                            lineIndex: line
                        )
                    }
                    for row in table.rows.indices {
                        for column in table.rows[row].cells.indices {
                            if let line = table.rows[row].cells[column].lines.firstIndex(
                                where: { $0.id == id }
                            ) {
                                return DocumentSourceReference(
                                    pageIndex: page.pageIndex,
                                    blockID: block.id,
                                    row: row,
                                    column: column,
                                    lineIndex: line
                                )
                            }
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Resolves a source reference to confirmed extracted text.
    ///
    /// Literal unresolved and covered table slots return nil. Read a cell's
    /// lines or unresolvedCandidateText explicitly when unresolved evidence is
    /// useful to the consuming application.
    public func text(for reference: DocumentSourceReference) -> String? {
        guard let block = block(for: reference) else { return nil }
        switch block.content {
        case let .text(text):
            guard reference.row == nil, reference.column == nil else { return nil }
            if let lineIndex = reference.lineIndex {
                guard text.lines.indices.contains(lineIndex) else { return nil }
                return text.lines[lineIndex].text
            }
            return text.joinedText
        case .table:
            if reference.row == nil, reference.column == nil,
                reference.lineIndex != nil
            {
                return line(for: reference)?.text
            }
            guard let cell = cell(for: reference), cell.state == .text || cell.state == .empty else {
                return nil
            }
            if reference.lineIndex != nil {
                guard cell.state == .text, let line = line(for: reference) else { return nil }
                return line.text
            }
            return cell.joinedText
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

    /// Text and table blocks in inferred reading order.
    public let blocks: [DocumentBlock]

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
    public let width: Double
    public let height: Double

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
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

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
    /// An opaque, document-scoped identifier for source references.
    public let id: String

    /// The block's source bounds, when the engine reported them.
    public let bounds: DocumentBounds?

    /// The block's text or table content.
    public let content: Content

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

    /// Text and table variants supported by the structured-document schema.
    public enum Content: Codable, Sendable, Hashable {
        case text(TextBlock)
        case table(TableBlock)

        private enum CodingKeys: String, CodingKey {
            case type
            case lines
            case rows
            case layoutRows
            case unassignedLines
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "text":
                self = .text(TextBlock(lines: try container.decode([TextLine].self, forKey: .lines)))
            case "table":
                let table = try TableBlock(
                    validating: container.decode([TableRow].self, forKey: .rows),
                    unassignedLines: container.decode(
                        [TextLine].self,
                        forKey: .unassignedLines
                    )
                )
                guard try container.decode([TableLayoutRow].self, forKey: .layoutRows)
                    == table.layoutRows
                else {
                    throw StructuredDocumentCodingError.invalidValue(
                        "Table layout rows do not match their source rows"
                    )
                }
                self = .table(table)
            default:
                throw StructuredDocumentCodingError.invalidValue("Unknown document block content type")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .text(text):
                try container.encode("text", forKey: .type)
                try container.encode(text.lines, forKey: .lines)
            case let .table(table):
                try container.encode("table", forKey: .type)
                try container.encode(table.rows, forKey: .rows)
                try container.encode(table.layoutRows, forKey: .layoutRows)
                try container.encode(table.unassignedLines, forKey: .unassignedLines)
            }
        }
    }
}

/// Text outside a detected table.
public struct TextBlock: Codable, Sendable, Hashable {
    /// Extracted lines in inferred reading order.
    public let lines: [TextLine]

    public init(lines: [TextLine]) {
        self.lines = lines
    }

    /// The lines joined with newline characters.
    public var joinedText: String {
        lines.map(\.text).joined(separator: "\n")
    }
}

/// A page-local table fragment with directly indexable rows and cells.
public struct TableBlock: Codable, Sendable, Hashable {
    /// Rows in the detector's table order.
    public let rows: [TableRow]

    /// Positioned source lines claimed by the detector but not safely
    /// associated with a logical cell.
    public let unassignedLines: [TextLine]

    /// The number of logical rows, derived from rows.
    public var rowCount: Int {
        rows.count
    }

    /// The number of logical columns, derived from the rectangular rows.
    public var columnCount: Int {
        rows.first?.cells.count ?? 0
    }

    /// Rows after shared continuation and wrapped-content joining.
    ///
    /// Physical source rows remain available in `rows`. Each layout row names
    /// every physical row and source-line occurrence that contributed to it.
    public var layoutRows: [TableLayoutRow] {
        rows.indices.compactMap { row in
            guard rows[row].continuationOfRowID == nil else { return nil }
            let sourceRows = [row] + rows.indices.filter {
                rows[$0].continuationOfRowID == rows[row].id
            }
            return TableLayoutRow(
                id: rows[row].id,
                sourceRowIDs: sourceRows.map { rows[$0].id },
                cells: (0..<columnCount).map { column in
                    TableLayoutCell(sourceCells: sourceRows.map { rows[$0].cells[column] })
                }
            )
        }
    }

    public init(rows: [TableRow], unassignedLines: [TextLine] = []) {
        precondition(Self.isValid(rows: rows), "Table rows must form a complete rectangular grid")
        self.rows = rows
        self.unassignedLines = unassignedLines
    }

    init(validating rows: [TableRow], unassignedLines: [TextLine] = []) throws {
        guard Self.isValid(rows: rows) else {
            throw StructuredDocumentCodingError.invalidValue(
                "Table rows must form a complete rectangular grid"
            )
        }
        self.rows = rows
        self.unassignedLines = unassignedLines
    }

    private enum CodingKeys: String, CodingKey {
        case rows
        case layoutRows
        case unassignedLines
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            validating: try container.decode([TableRow].self, forKey: .rows),
            unassignedLines: container.decode([TextLine].self, forKey: .unassignedLines)
        )
        guard try container.decode([TableLayoutRow].self, forKey: .layoutRows) == layoutRows else {
            throw StructuredDocumentCodingError.invalidValue(
                "Table layout rows do not match their source rows"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rows, forKey: .rows)
        try container.encode(layoutRows, forKey: .layoutRows)
        try container.encode(unassignedLines, forKey: .unassignedLines)
    }

    /// Returns the literal table slot at a zero-based row and column.
    public func cell(row: Int, column: Int) -> TableCell? {
        guard rows.indices.contains(row), rows[row].cells.indices.contains(column) else {
            return nil
        }
        return rows[row].cells[column]
    }

    /// Returns the anchor address for a literal slot.
    ///
    /// A non-covered slot resolves to its own address. A covered slot resolves
    /// only because the caller asks this method explicitly.
    public func resolvedCellAddress(row: Int, column: Int) -> TableCellAddress? {
        guard let cell = cell(row: row, column: column) else { return nil }
        if case let .covered(by: address) = cell.content {
            return address
        }
        return TableCellAddress(row: row, column: column)
    }

    /// Returns the cell at an explicitly resolved anchor.
    public func resolvedCell(row: Int, column: Int) -> TableCell? {
        guard let address = resolvedCellAddress(row: row, column: column) else { return nil }
        return cell(row: address.row, column: address.column)
    }

    private static func isValid(rows: [TableRow]) -> Bool {
        guard let firstRow = rows.first, !firstRow.cells.isEmpty else { return false }
        let rowCount = rows.count
        let columnCount = firstRow.cells.count
        guard rows.allSatisfy({ $0.cells.count == columnCount }) else { return false }
        let rowIndexes = Dictionary(
            rows.indices.map { (rows[$0].id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard rowIndexes.count == rowCount,
            rows.indices.allSatisfy({ row in
                guard let target = rows[row].continuationOfRowID else { return true }
                return rowIndexes[target].map {
                    $0 < row && rows[$0].continuationOfRowID == nil
                } ?? false
            })
        else {
            return false
        }

        var coverage = Array(
            repeating: Array<TableCellAddress?>(repeating: nil, count: columnCount),
            count: rowCount
        )
        for row in rows.indices {
            for column in rows[row].cells.indices {
                let cell = rows[row].cells[column]
                if case .covered = cell.content {
                    guard cell.role == nil, cell.span == nil, cell.bounds == nil else {
                        return false
                    }
                    continue
                }
                let rowSpan = cell.span?.rows ?? 1
                let columnSpan = cell.span?.columns ?? 1
                guard rowSpan <= rowCount - row, columnSpan <= columnCount - column else {
                    return false
                }
                let anchor = TableCellAddress(row: row, column: column)
                for coveredRow in row..<(row + rowSpan) {
                    for coveredColumn in column..<(column + columnSpan) {
                        guard coverage[coveredRow][coveredColumn] == nil else { return false }
                        coverage[coveredRow][coveredColumn] = anchor
                    }
                }
            }
        }

        for row in rows.indices {
            for column in rows[row].cells.indices {
                guard let anchor = coverage[row][column] else { return false }
                let cell = rows[row].cells[column]
                if anchor.row == row && anchor.column == column {
                    guard cell.state != .covered else { return false }
                } else {
                    guard case let .covered(by: address) = cell.content, address == anchor else {
                        return false
                    }
                }
            }
        }
        return true
    }
}

/// One logical row in a rectangular table.
public struct TableRow: Codable, Sendable, Hashable {
    /// An opaque occurrence ID unique within this extraction result.
    public let id: String

    /// Cells in zero-based column order.
    public let cells: [TableCell]

    /// The earlier physical row this row continues after shared layout cleanup.
    public let continuationOfRowID: String?

    public init(id: String, cells: [TableCell], continuationOfRowID: String? = nil) {
        precondition(!id.isEmpty, "Table row IDs cannot be empty")
        precondition(!cells.isEmpty, "Table rows cannot be empty")
        self.id = id
        self.cells = cells
        self.continuationOfRowID = continuationOfRowID
    }

    public init(cells: [TableCell]) {
        self.init(id: UUID().uuidString, cells: cells)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case cells
        case continuationOfRowID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let cells = try container.decode([TableCell].self, forKey: .cells)
        guard !id.isEmpty, !cells.isEmpty else {
            throw StructuredDocumentCodingError.invalidValue("Table rows cannot be empty")
        }
        self.id = id
        self.cells = cells
        self.continuationOfRowID = try container.decodeIfPresent(
            String.self,
            forKey: .continuationOfRowID
        )
    }
}

/// A display row derived from one or more physical detector rows.
public struct TableLayoutRow: Codable, Sendable, Hashable {
    public let id: String
    public let sourceRowIDs: [String]
    public let cells: [TableLayoutCell]
}

/// Joined cell text plus the original source occurrences that produced it.
public struct TableLayoutCell: Codable, Sendable, Hashable {
    public let state: TableCellState
    public let text: String?
    public let candidateText: String?
    public let sourceLineIDs: [String]

    fileprivate init(sourceCells: [TableCell]) {
        sourceLineIDs = sourceCells.flatMap { $0.lines.map(\.id) }
        if sourceCells.contains(where: { $0.state == .unresolved }) {
            state = .unresolved
            text = nil
            let candidates = sourceCells.compactMap(\.unresolvedCandidateText)
            candidateText = candidates.isEmpty ? nil : candidates.joined(separator: " ")
        } else if sourceCells.allSatisfy({ $0.state == .covered }) {
            state = .covered
            text = nil
            candidateText = nil
        } else {
            let fragments = sourceCells
                .filter { $0.state != .covered }
                .compactMap(\.joinedText)
                .filter { !$0.isEmpty }
            state = fragments.isEmpty ? .empty : .text
            text = fragments.joined(separator: " ")
            candidateText = nil
        }
    }
}

/// A local table-cell address used by a covered slot.
public struct TableCellAddress: Codable, Sendable, Hashable {
    public let row: Int
    public let column: Int

    public init(row: Int, column: Int) {
        precondition(row >= 0 && column >= 0, "Table cell addresses cannot be negative")
        self.row = row
        self.column = column
    }

    private enum CodingKeys: String, CodingKey {
        case row
        case column
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let row = try container.decode(Int.self, forKey: .row)
        let column = try container.decode(Int.self, forKey: .column)
        guard row >= 0, column >= 0 else {
            throw StructuredDocumentCodingError.invalidValue(
                "Table cell addresses cannot be negative"
            )
        }
        self.row = row
        self.column = column
    }
}

/// The number of logical rows and columns covered by an anchor cell.
public struct TableCellSpan: Codable, Sendable, Hashable {
    public let rows: Int
    public let columns: Int

    public init(rows: Int, columns: Int) {
        precondition(rows > 0 && columns > 0, "Table cell spans must be positive")
        precondition(rows > 1 || columns > 1, "Single-cell spans must be omitted")
        self.rows = rows
        self.columns = columns
    }

    private enum CodingKeys: String, CodingKey {
        case rows
        case columns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decode(Int.self, forKey: .rows)
        let columns = try container.decode(Int.self, forKey: .columns)
        guard rows > 0, columns > 0, rows > 1 || columns > 1 else {
            throw StructuredDocumentCodingError.invalidValue(
                "Table cell spans must be positive and cover more than one slot"
            )
        }
        self.rows = rows
        self.columns = columns
    }
}

/// A source-backed table-cell role, present only for explicit tagged-PDF evidence.
public enum TableCellRole: String, Codable, Sendable, Hashable {
    case header
    case body
}

/// The state of a table cell's content.
public enum TableCellState: String, Codable, Sendable, Hashable {
    case text
    case empty
    case unresolved
    case covered
}

/// A cell in a rectangular table row.
public struct TableCell: Codable, Sendable, Hashable {
    /// The cell's strictly typed content evidence.
    public let content: Content

    /// Explicit tagged-PDF role evidence, when available.
    public let role: TableCellRole?

    /// The anchor cell's nontrivial span, when available.
    public let span: TableCellSpan?

    /// The union of the cell's source-line bounds, when available.
    public let bounds: DocumentBounds?

    public init(
        content: Content,
        role: TableCellRole? = nil,
        span: TableCellSpan? = nil,
        bounds: DocumentBounds? = nil
    ) {
        precondition(
            Self.isValidMetadata(content: content, role: role, span: span, bounds: bounds),
            "Covered cells cannot carry independent evidence"
        )
        self.content = content
        self.role = role
        self.span = span
        self.bounds = bounds
    }

    public var state: TableCellState {
        content.state
    }

    /// Positioned source lines for text or unresolved evidence.
    public var lines: [TextLine] {
        content.lines
    }

    /// Unreconciled detector text, when the engine retained it separately.
    ///
    /// It is never substituted for confirmed source text.
    public var unresolvedCandidateText: String? {
        content.unresolvedCandidateText
    }

    /// Confirmed source text joined with newlines, or an empty string for a
    /// confirmed empty slot. Unresolved and covered slots return nil.
    public var joinedText: String? {
        content.joinedText
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case span
        case bounds
    }

    public init(from decoder: Decoder) throws {
        let content = try Content(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let role = try container.decodeIfPresent(TableCellRole.self, forKey: .role)
        let span = try container.decodeIfPresent(TableCellSpan.self, forKey: .span)
        let bounds = try container.decodeIfPresent(DocumentBounds.self, forKey: .bounds)
        guard Self.isValidMetadata(content: content, role: role, span: span, bounds: bounds) else {
            throw StructuredDocumentCodingError.invalidValue(
                "Covered cells cannot carry independent evidence"
            )
        }
        self.content = content
        self.role = role
        self.span = span
        self.bounds = bounds
    }

    public func encode(to encoder: Encoder) throws {
        try content.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(span, forKey: .span)
        try container.encodeIfPresent(bounds, forKey: .bounds)
    }

    private static func isValidMetadata(
        content: Content,
        role: TableCellRole?,
        span: TableCellSpan?,
        bounds: DocumentBounds?
    ) -> Bool {
        guard content.isValid else { return false }
        guard case .covered = content else { return true }
        return role == nil && span == nil && bounds == nil
    }

    /// The source evidence stored in a table cell.
    public enum Content: Codable, Sendable, Hashable {
        /// Confirmed positioned lines from the PDF text layer.
        case text([TextLine])

        /// A confirmed empty slot in the detected grid.
        case empty

        /// Positioned evidence that could not be reconciled with the detector grid.
        case unresolved(lines: [TextLine], candidateText: String?)

        /// A slot covered by an anchor cell's span.
        case covered(by: TableCellAddress)

        fileprivate var isValid: Bool {
            switch self {
            case let .text(lines):
                !lines.isEmpty
            case let .unresolved(lines: _, candidateText: candidateText):
                candidateText.map({ !$0.isEmpty }) ?? true
            case .empty, .covered:
                true
            }
        }

        fileprivate var state: TableCellState {
            switch self {
            case .text: .text
            case .empty: .empty
            case .unresolved: .unresolved
            case .covered: .covered
            }
        }

        fileprivate var lines: [TextLine] {
            switch self {
            case let .text(lines):
                lines
            case let .unresolved(lines: lines, candidateText: _):
                lines
            case .empty, .covered:
                []
            }
        }

        fileprivate var unresolvedCandidateText: String? {
            guard case let .unresolved(lines: _, candidateText: candidateText) = self else {
                return nil
            }
            return candidateText
        }

        fileprivate var joinedText: String? {
            switch self {
            case let .text(lines):
                lines.map(\.text).joined(separator: "\n")
            case .empty:
                ""
            case .unresolved, .covered:
                nil
            }
        }

        private enum CodingKeys: String, CodingKey {
            case state
            case lines
            case candidateText
            case coveredBy
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let state = try container.decode(TableCellState.self, forKey: .state)
            switch state {
            case .text:
                let lines = try container.decode([TextLine].self, forKey: .lines)
                guard !lines.isEmpty,
                    !container.contains(.candidateText),
                    !container.contains(.coveredBy)
                else {
                    throw StructuredDocumentCodingError.invalidValue(
                        "Text cells require lines and cannot carry unresolved evidence"
                    )
                }
                self = .text(lines)
            case .empty:
                guard !container.contains(.lines),
                    !container.contains(.candidateText),
                    !container.contains(.coveredBy)
                else {
                    throw StructuredDocumentCodingError.invalidValue(
                        "Empty cells cannot carry text evidence"
                    )
                }
                self = .empty
            case .unresolved:
                let lines = try container.decodeIfPresent([TextLine].self, forKey: .lines) ?? []
                let candidateText = try container.decodeIfPresent(String.self, forKey: .candidateText)
                guard candidateText.map({ !$0.isEmpty }) ?? true,
                    !container.contains(.coveredBy)
                else {
                    throw StructuredDocumentCodingError.invalidValue(
                        "Unresolved cells have invalid evidence"
                    )
                }
                self = .unresolved(lines: lines, candidateText: candidateText)
            case .covered:
                guard !container.contains(.lines), !container.contains(.candidateText) else {
                    throw StructuredDocumentCodingError.invalidValue(
                        "Covered cells cannot carry text evidence"
                    )
                }
                self = .covered(by: try container.decode(TableCellAddress.self, forKey: .coveredBy))
            }
        }

        public func encode(to encoder: Encoder) throws {
            guard isValid else {
                throw EncodingError.invalidValue(
                    self,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Invalid table cell content"
                    )
                )
            }
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .text(lines):
                try container.encode(TableCellState.text, forKey: .state)
                try container.encode(lines, forKey: .lines)
            case .empty:
                try container.encode(TableCellState.empty, forKey: .state)
            case let .unresolved(lines, candidateText):
                try container.encode(TableCellState.unresolved, forKey: .state)
                if !lines.isEmpty {
                    try container.encode(lines, forKey: .lines)
                }
                try container.encodeIfPresent(candidateText, forKey: .candidateText)
            case let .covered(by: address):
                try container.encode(TableCellState.covered, forKey: .state)
                try container.encode(address, forKey: .coveredBy)
            }
        }
    }
}

/// One extracted line and its optional source bounds.
public struct TextLine: Codable, Sendable, Hashable {
    /// An opaque source-occurrence ID unique within this extraction result.
    public let id: String
    public let text: String
    public let bounds: DocumentBounds?

    public init(id: String, text: String, bounds: DocumentBounds? = nil) {
        precondition(!id.isEmpty, "Source line IDs cannot be empty")
        self.id = id
        self.text = text
        self.bounds = bounds
    }

    public init(text: String, bounds: DocumentBounds? = nil) {
        self.init(id: UUID().uuidString, text: text, bounds: bounds)
    }
}

/// A source address for data derived from an extracted document.
public struct DocumentSourceReference: Codable, Sendable, Hashable {
    public let pageIndex: Int
    public let blockID: String

    /// The zero-based literal table row, when the reference points into a table.
    public let row: Int?

    /// The zero-based literal table column, when the reference points into a table.
    public let column: Int?

    /// The zero-based line index within a text block or literal table slot.
    public let lineIndex: Int?

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
        case let .invalidValue(message):
            message
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
    var lineIDs = Set<String>()
    for page in pages {
        for block in page.blocks {
            guard blockIDs.insert(block.id).inserted else { return false }
            let lines: [TextLine]
            switch block.content {
            case let .text(text):
                lines = text.lines
            case let .table(table):
                lines = table.rows.flatMap { $0.cells.flatMap(\.lines) } + table.unassignedLines
            }
            guard lines.allSatisfy({ !$0.id.isEmpty && lineIDs.insert($0.id).inserted }) else {
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
            throw StructuredDocumentCodingError.invalidValue("Processing time cannot be negative")
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
            throw StructuredDocumentCodingError.invalidValue("Engine version cannot be empty")
        }
        self.engineVersion = engineVersion
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(pageCount, forKey: .pageCount)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(
            processingTime.millisecondsForStructuredDocument,
            forKey: .processingTimeMilliseconds
        )
        try container.encode(pagesNeedingOCR, forKey: .pagesNeedingOCR)
        try container.encode(ocrReasonsByPage, forKey: .ocrReasonsByPage)
        try container.encodeIfPresent(layout, forKey: .layout)
        try container.encodeIfPresent(hasEncodingIssues, forKey: .hasEncodingIssues)
        try container.encode(engineVersion, forKey: .engineVersion)
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
        guard !code.isEmpty, isStrictlyAscending(pageIndexes),
            pageIndexes.allSatisfy({ $0 >= 0 })
        else {
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
        precondition(
            !seconds.overflow && !milliseconds.overflow,
            "Duration is too large to encode as milliseconds"
        )
        return milliseconds.partialValue
    }
}
