# ``Turnip``

Extract typed document structure and Markdown from PDFs locally in iOS and
macOS apps.

## Overview

Turnip wraps a pinned PDF engine behind a small Swift API. It reads PDF
data in the app process, preserves source text and tables in a typed document,
produces Markdown when requested, and reports classification, layout, encoding,
and OCR-routing signals alongside the result. It does not upload PDFs, call an
LLM, convert Office documents, perform OCR, or interpret domain values.

```swift
import Turnip
import Foundation

let document = try await Turnip.extractDocument(pdfData)

for page in document.pages {
    print(page.pageIndex, page.status)
}

let json = try JSONEncoder().encode(document)
```

Use ``Turnip/extractDocument(_:)`` when your app needs source pages, text,
tables, lines, or geometry. Use ``Turnip/extract(_:)`` when it needs Markdown. Use
``Turnip/inspect(_:)`` when it only needs to classify a PDF and decide
whether another OCR-capable path is needed. `inspect` does not first extract
Markdown, so its layout and encoding fields are `nil`. File URLs use
``Turnip/extractDocument(contentsOf:)``, ``Turnip/extract(contentsOf:)``, and
``Turnip/inspect(contentsOf:)``.

## Select pages and handle passwords

All public page indexes are zero-based. A selection must be unique, nonempty,
and strictly ascending. Pass `nil` to process the whole document.

```swift
let options = DocumentOptions(
    pageIndexes: [0, 2, 3],
    password: suppliedPassword
)
let document = try await Turnip.extractDocument(pdfData, options: options)
```

Turnip passes the supplied password to the engine and redacts it from
`DocumentOptions` descriptions and reflection. It limits every input to
``Turnip/maximumInputSize``. A parsed PDF still runs in the app process,
so apps that accept hostile documents should apply their own concurrency and
resource limits.

## Trace and interpret the result

Structured output is extraction evidence, not proof that every field is
correct. Preserve ``ExtractedDocument/warnings``, page statuses, source lines,
and the ``DocumentInspection``. In particular,
``DocumentWarning/Kind/ocrRequired`` means the engine recommends OCR for one or
more pages, and ``DocumentWarning/Kind/encodingIssues`` means the engine found
decoding issues. Warning page indexes contain only page-local evidence. An
empty list means the engine could not localize a document-level warning, not
that every requested page is affected.

```swift
let source = DocumentSourceReference(
    pageIndex: 0,
    blockID: "p0-b1",
    row: 2,
    column: 2
)

let literalCell = document.cell(for: source)
let anchorCell = document.resolvedCell(for: source)
```

`cell(for:)` keeps a literal covered slot distinct from its span anchor.
`resolvedCell(for:)` follows that link only when an app asks it to. Cell text
stays as decoded strings and source lines. `TableBlock.layoutRows` exposes the
continuation-row joins shared with Markdown while `TableBlock.rows` retains
every physical row. Each joined cell lists its contributing `TextLine.id`
values, which ``ExtractedDocument/sourceReference(forLineID:)`` resolves back
to original evidence. The consuming app owns any
domain-specific interpretation, normalization, or import decision.

For a scanned or image-only PDF, Markdown extraction throws
``TurnipError/noExtractableText(_:)`` and includes the inspection that
explains the routing decision. Structured extraction instead returns each
requested page with ``DocumentPage/status`` set to
``DocumentPageStatus/needsOCR`` and no invented text.

## Validation status

Committed fixtures prove mechanical behavior only. They do not support a
general accuracy or performance claim. The repository validation notes define
the input boundaries, redacted reports, and holdout rules.

## Topics

### Essentials

- ``Turnip/extract(_:)``
- ``Turnip/extract(_:options:)``
- ``Turnip/extract(contentsOf:)``
- ``Turnip/extract(contentsOf:options:)``
- ``Turnip/extractDocument(_:)``
- ``Turnip/extractDocument(_:options:)``
- ``Turnip/extractDocument(contentsOf:)``
- ``Turnip/extractDocument(contentsOf:options:)``
- ``Turnip/inspect(_:)``
- ``Turnip/inspect(_:options:)``
- ``Turnip/inspect(contentsOf:)``
- ``Turnip/inspect(contentsOf:options:)``
- ``Turnip/maximumInputSize``
- ``Turnip/engineRevision``
- ``DocumentOptions``

### Results

- ``ExtractedDocument``
- ``DocumentPage``
- ``DocumentPageStatus``
- ``PageSize``
- ``DocumentBounds``
- ``DocumentBlock``
- ``TextBlock``
- ``TableBlock``
- ``TableRow``
- ``TableLayoutRow``
- ``TableLayoutCell``
- ``TableCell``
- ``TableCellRole``
- ``TableCellState``
- ``TableCellAddress``
- ``TableCellSpan``
- ``TextLine``
- ``DocumentSourceReference``
- ``DocumentExtraction``
- ``DocumentInspection``
- ``DocumentKind``
- ``DocumentLayout``
- ``PageOCRReasons``
- ``DocumentWarning``

### Errors

- ``TurnipError``
- ``PageSelectionError``
