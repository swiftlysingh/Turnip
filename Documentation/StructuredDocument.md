# Structured document schema v2

`Turnip.extractDocument` returns an `ExtractedDocument`: ordered
text and page-local tables from a digital PDF. It is a local extraction
contract. It does not run OCR, expose native text items, or assign meaning to
extracted strings.

Every model in the document graph is `Codable`, `Sendable`, and
`Hashable`. The public JSON is independent from the private native
bridge payload.

## Shape

```swift
for page in document.pages {
    for block in page.blocks {
        switch block.content {
        case let .text(text):
            print(text.joinedText)
        case let .table(table):
            let cell = table.rows[0].cells[0]
            print(cell.joinedText)
        }
    }
}
```

Pages use their original zero-based PDF indexes and appear in ascending source
order. Blocks appear in inferred reading order within a page. A table stays on
the physical page where it was detected. Turnip does not join page fragments,
deduplicate repeated rows, or remove repeated headers.

Text before, between, and after detected tables remains in text blocks at its
place in the inferred reading order. This is still extraction output. A visual
table can be missed or represented as text when the engine cannot establish a
table.

```json
{
  "id": "p0-b1",
  "content": {
    "type": "table",
    "rows": [
      {
        "cells": [
          {
            "state": "text",
            "role": "header",
            "lines": [{ "text": "Place" }]
          },
          {
            "state": "text",
            "lines": [
              { "text": "North" },
              { "text": "Campus" }
            ]
          },
          { "state": "empty" }
        ]
      }
    ]
  }
}
```

`TableBlock.rows[r].cells[c]` is the literal logical slot at row `r`
and column `c`. A table has at least one row and one column. Every row
has the same number of cells, so both counts are derived from `rows`.
The JSON does not store a flat cell list or repeat row and column indexes in
each cell.

## Cell evidence

Each `TableCell` has one tagged content state:

- `text` has one or more positioned `TextLine` values. The lines
  preserve the engine's line grouping. `joinedText` joins them with newline
  characters.
- `empty` is a confirmed empty logical slot. Its `joinedText` is
  the empty string.
- `unresolved` means the engine could not reconcile table evidence.
  It can retain positioned `lines` and separately marked
  `unresolvedCandidateText`. Its `joinedText` is always `nil`.
  Turnip never promotes candidate text to confirmed source text.
- `covered` is a slot occupied by another cell's span. Its
  `coveredBy` address points to the anchor. Its `joinedText` is
  `nil`.

A span appears on its anchor as `span: { rows, columns }`. Every slot it
covers remains present as `covered`; no value is duplicated. Only spans
the engine can establish appear in output. Do not infer a span from blank or
matching strings.

`role` is optional. `header` and `body` appear only when
tagged-PDF evidence provides that role. Turnip does not make a row a header to
suit a presentation format.

Cell values remain strings. Turnip does not parse numbers, dates, units,
identifiers, signs, categories, or any other application-specific values.

## Source references

`DocumentSourceReference` addresses:

```text
pageIndex -> blockID -> optional literal row/column -> optional lineIndex
```

`blockID` is an opaque identifier unique within one extracted document.
A table row is identified by `(pageIndex, blockID, row)`; identical rows
remain separate because their array positions differ.

`document.cell(for:)` returns the literal slot. A covered slot stays
covered. `document.resolvedCell(for:)` and
`document.resolvedSourceReference(for:)` follow `coveredBy` only
when the caller asks. A line reference to a covered slot is invalid and does
not become a line reference on its anchor.

`document.text(for:)` returns confirmed text only. It returns `nil`
for a literal unresolved or covered table slot. `document.line(for:)`
can expose a positioned line retained by an unresolved cell, without making
the cell confirmed text.

References are useful within the same extraction result. They are not durable
keys across a changed PDF, page selection, schema version, or engine revision.

## Pages, warnings, and bounds

Every requested page appears once, even when it has no blocks.
`inspection.pageCount` is the total source-PDF page count; `pages`
contains the requested selection.

`extracted` means the engine processed the page. It does not claim that
the text is correct. `needsOCR` means the engine found evidence that OCR
would be needed. Turnip reports that state but does not perform OCR.
`extractionFailed` is reserved for a recoverable page-local failure; a
fatal parse, encryption, or selection error still throws.

Keep page statuses and warnings with downstream results. An empty warning
`pageIndexes` list means the warning is document-level but could not be
localized. It does not mean every selected page is affected.

`DocumentBounds` is optional source-inspection evidence. It has normalized
`x`, `y`, `width`, and `height` coordinates in the
top-left-origin upright visible page. `DocumentPage.size` supplies that
page's visible size in PDF points. Bounds can be absent and are approximate
locations, not glyph positions or table reconstruction data. Turnip exposes no
raw text-item stream.

## JSON and versioning

Schema v2 requires:

- `schemaVersion`, `inspection`, `pages`, and `warnings` on
  the root.
- `pageIndex`, `size`, `status`, and `blocks` on each page.
- `id` and `content` on each block.
- `type` plus `lines` for text content, or `type` plus `rows`
  for table content.
- `cells` on each table row.
- `state` on each cell. Text cells require `lines`; covered cells
  require `coveredBy`.

`bounds`, `role`, `span`, and `candidateText` are optional.
Optional values are omitted when absent. Unsupported root schema versions and
unknown structural enum values fail decoding. Unknown warning codes remain
round-trippable because warnings are advisory.

Encoding a valid v2 model, decoding it, and encoding it again preserves the
public value and ordered arrays. The contract does not promise identical JSON
bytes, JSON key order, measured processing time, block IDs, or extraction
results across engine or schema changes.

For the same PDF bytes, options, schema, and Turnip build, v2 acceptance
tests require stable page, block, row, cell, and line order. They cover
multiline cells, repeated rows, confirmed blanks, unresolved evidence, spans,
text around a table, page-local table fragments, source-reference resolution,
and JSON round trips using generated digital PDFs. These tests do not establish
accuracy across all document layouts.
