# Structured document schema v1

`Turnip.extractDocument` returns an `ExtractedDocument`. Every public model in
the document graph is `Codable`, `Sendable`, and `Hashable`. The JSON is a
consumer contract, not the private Rust bridge envelope.

## Contract

These fields are required in schema v1:

- `schemaVersion`, `inspection`, `pages`, and `warnings` on the root object
- `kind`, `pageCount`, `confidence`, `processingTimeMilliseconds`,
  `pagesNeedingOCR`, `ocrReasonsByPage`, and `engineVersion` on inspection
- `isComplex`, `pagesWithTables`, and `pagesWithColumns` when `layout` is present
- `pageIndex` and `reasons` on each OCR-reason entry
- `code` and `pageIndexes` on each warning
- `pageIndex`, `size`, `status`, and `blocks` on every page
- `width` and `height` on every page size
- `id` and `content` on every block
- `type` and `lines` for text content
- `type`, `rowCount`, `columnCount`, and `cells` for table content
- `row`, `column`, `rowSpan`, `columnSpan`, `role`, `state`, and `lines` on cells
- `text` on lines
- `x`, `y`, `width`, and `height` when a bounds object is present

`title`, `layout`, `hasEncodingIssues`, `detectedText`, and every `bounds` field
are optional.
Turnip's encoder omits an optional field when no value is available. Its
decoder accepts either an omitted field or `null`, then re-encoding omits the
field. Passwords, input bytes, file paths, and Markdown are never part of this
schema.

A separately encoded `DocumentSourceReference` requires `pageIndex` and
`blockID`. Its `row`, `column`, and `lineIndex` fields are optional and omitted
when absent. Row and column must either both be present or both be absent.

Block content has an explicit discriminator:

```json
{
  "id": "p0-b1",
  "content": {
    "type": "table",
    "rowCount": 1,
    "columnCount": 1,
    "cells": [
      {
        "row": 0,
        "column": 0,
        "rowSpan": 1,
        "columnSpan": 1,
        "role": "unknown",
        "state": "empty",
        "lines": []
      }
    ]
  }
}
```

Schema v1 uses these enum strings:

- page status: `extracted`, `needsOCR`, `extractionFailed`
- block type: `text`, `table`
- cell role: `header`, `body`, `unknown`
- cell state: `extracted`, `empty`, `unresolved`
- document kind: `text_based`, `scanned`, `image_based`, `mixed`
- known warning codes: `ocrRequired`, `encodingIssues`

Unknown structural enums and unsupported root schema versions fail decoding.
Warning codes are different because warnings are advisory and extensible. An
unknown warning code decodes as `DocumentWarning.Kind.unknown(String)` and is
preserved when encoded again. Unknown object fields are ignored within schema
v1; a change that alters the meaning of existing fields requires a new root
schema version.

Warning `pageIndexes` contain only pages for which the engine supplied
page-local evidence. An empty list means the warning applies to the document
but could not be localized. Consumers must not interpret an empty list as every
requested page.

Pages are strictly ascending by their original zero-based PDF index. Blocks
remain in inferred reading order. Cells are ordered by zero-based row and then
column. JSON array order is meaningful and round-tripping preserves it.

## Pages and partial extraction

Every requested page appears in a successful result, including a selected page
that contains no extracted text. `inspection.pageCount` is the source PDF's
total page count, while `pages` contains only the requested indexes.

`extracted` means processing completed. It is not a correctness claim.
`needsOCR` means Turnip found evidence that OCR is needed; Turnip does not run
OCR. Such a page can still contain best-effort embedded text. `extractionFailed`
is reserved for an engine that can report and recover from a page-local
failure. The pinned engine does not currently emit it. A page extraction
failure, invalid PDF, encryption failure, out-of-range selection, or other
engine failure remains a thrown error instead of a successful empty document.

A consumer should treat `needsOCR` or `extractionFailed` as incomplete page
coverage. Warnings and page statuses must be retained with interpreted output.

## Tables, lines, and spans

Structured tables are captured before Markdown presentation cleanup. Page-local
fragments retain repeated headers, duplicate rows, empty rows, continuation
rows, and their source order. Cell text is decoded PDF text before Markdown
escaping. Values such as `03 Jan`, `01/02`, `5.00 CR`, `(12.34)`, and
`1.234,56` remain strings.

Line arrays preserve the source lines available to the engine. A cell's
optional `joinedText` convenience accessor joins them with newline characters,
falling back to `detectedText` only when no positioned line was associated. It
returns an empty string for a confirmed empty cell and `nil` for an unresolved
cell with no text evidence. It is not a second stored text representation.

A spanning cell appears once at its top-left row and column. `rowSpan` and
`columnSpan` say which slots it covers, and those covered slots do not get
duplicate cell objects. All other grid slots are explicit. Turnip preserves a
span only when the extraction path has structural or vector evidence for it.
It does not infer a span from similar or blank strings.

Cell state carries an important distinction:

- `extracted`: positioned source lines agree with the raw grid content.
- `empty`: an established, non-covered grid slot has no raw text or associated
  positioned source item.
- `unresolved`: raw grid content and positioned evidence could not be
  reconciled. Positioned `lines` and their available bounds remain present.
  If the detector also produced different raw cell content, `detectedText`
  preserves it without pretending it is a source line. This is the only case
  where both representations can appear.

An empty cell is not proof that the visible PDF region is blank.

## Coordinates

`DocumentBounds` uses normalized `x`, `y`, `width`, and `height` values. Its
origin is the top-left of the upright visible page after the inherited CropBox,
nonzero crop origin, `/Rotate`, and positive finite inherited `/UserUnit` are
applied. `DocumentPage.size` is the same upright visible page in PDF points.
Malformed or non-positive `/UserUnit` values fail extraction instead of
producing misleading dimensions.

The engine transforms all rectangle corners, takes their enclosing rectangle,
clips it to the visible page, and then normalizes it. Native PDF rectangles can
use signed extents, so their endpoint order is canonicalized before this
transformation. Public widths and heights are always positive. A wholly
outside, non-finite, or unavailable location is omitted. It is never replaced
with a zero rectangle.

PDF text often lacks exact glyph boxes. The engine can estimate line height
from font size, so a UI should pad highlights and present them as an approximate
source region. In schema v1, a table cell bound is the union of its positioned
text lines, not the full painted grid rectangle. Empty and unresolved cells can
therefore have no bound even when the table detector saw surrounding rules.

## Source references and financial interpretation

`DocumentSourceReference` addresses:

```text
pageIndex -> blockID -> optional cell row/column -> optional lineIndex
```

Use `document.block(for:)`, `cell(for:)`, `line(for:)`, or `text(for:)` to
resolve a reference. Row and column must be supplied together. A wrapped
transaction can carry references to multiple rows or cells. Row identity is
the tuple `(pageIndex, blockID, row)`, so two legitimate rows with identical
text remain separate and accidental reuse is detectable.

Turnip does not recognize a statement layout or convert dates and money. A
RetroBudget interpreter can turn `5.00 CR` into signed minor units after
considering statement context, then validate the result against its referenced
cell. RetroBudget also owns candidate coverage, row reuse checks, printed-total
reconciliation, and the decision to import or request review.

For example, RetroBudget can store its interpretation separately from the
Turnip document:

```json
{
  "amountMinor": -500,
  "currency": "USD",
  "source": {
    "pageIndex": 0,
    "blockID": "p0-b1",
    "row": 2,
    "column": 2
  }
}
```

Before accepting that value, it can resolve the address with
`document.cell(for: source)` and confirm that the cell still contains
`5.00 CR`. This validates the interpretation against the captured extraction
evidence. It does not prove that the extraction matches the visible PDF.

## Complete example

This is the complete public JSON produced from the invented text-only fixture
in `StructuredDocumentTests.swift`. The measured processing time is from that
run and will vary by device.

```json
{
  "schemaVersion": 1,
  "inspection": {
    "kind": "text_based",
    "pageCount": 1,
    "confidence": 1,
    "processingTimeMilliseconds": 1,
    "pagesNeedingOCR": [],
    "ocrReasonsByPage": [],
    "layout": {
      "isComplex": false,
      "pagesWithTables": [],
      "pagesWithColumns": []
    },
    "hasEncodingIssues": false,
    "engineVersion": "1.24.0@67cda0ba18ca31b12f3ae94a0c0c5c9b6f390b18"
  },
  "pages": [
    {
      "pageIndex": 0,
      "size": {
        "width": 612,
        "height": 792
      },
      "status": "extracted",
      "blocks": [
        {
          "id": "p0-b0",
          "bounds": {
            "x": 0.09803922,
            "y": 0.07575758,
            "width": 0.199451,
            "height": 0.09090909
          },
          "content": {
            "type": "text",
            "lines": [
              {
                "text": "Statement details",
                "bounds": {
                  "x": 0.09803922,
                  "y": 0.07575758,
                  "width": 0.15149021,
                  "height": 0.015151516
                }
              },
              {
                "text": "No detected table here",
                "bounds": {
                  "x": 0.09803922,
                  "y": 0.11363637,
                  "width": 0.19837257,
                  "height": 0.015151508
                }
              },
              {
                "text": "Keep this line separate",
                "bounds": {
                  "x": 0.09803922,
                  "y": 0.15151516,
                  "width": 0.199451,
                  "height": 0.015151516
                }
              }
            ]
          }
        }
      ]
    }
  ],
  "warnings": []
}
```
