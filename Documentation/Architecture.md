# Architecture

Turnip has two extraction products. `extract` returns Markdown for
presentation and text-oriented use. `extractDocument` returns the public
structured v2 document for consumers that need ordered text, directly usable
table rows, and source references.

```text
PDF data or URL
        |
        v
Turnip Swift API
        |
        v
DocumentKitCore C ABI
        |
        v
pinned native PDF engine
  load once, inspect, extract, order text, detect tables
        |
        +--> Markdown renderer --> extract
        |
        +--> private structured capture --> v2 Swift adapter --> extractDocument
```

The Swift API owns input data for the duration of the C call. The native
library borrows it, serializes a private response, and returns an owned UTF-8
buffer. Swift copies that buffer and returns it through the native free
function. Rust pointers and the private wire JSON never reach client code.

## Why structured output does not start from Markdown

Markdown is a lossy presentation. Its renderer can escape cell text, add table
syntax, join paragraphs, merge continuation fragments, remove presentation-only
lines, or turn a row into a header for Markdown syntax. Those are useful
rendering choices. They cannot define a source-oriented table contract.

`extractDocument` captures the same reading-order and table-detection work
before the Markdown renderer changes it. It keeps physical page boundaries,
repeated rows, repeated headers, blank slots, wrapped source lines, and text
that appears before or after a table. Markdown keeps its established path and
does not become an input to the structured API.

The capture is still an extraction result, not a reconstructed PDF display
list. The native engine can miss a visual table, group text differently from a
reader, or return unresolved evidence. The public API exposes that uncertainty
instead of guessing.

## Public v2 boundary

The native engine currently supplies an anchor-based grid, source-line
associations, optional bounds, and a small amount of role and span evidence.
Those are private transport details. The Swift adapter validates them and
builds a consumer-facing matrix:

```text
native anchor cells + spans
        |
        v
TableBlock.rows[row].cells[column]
  text | empty | unresolved | covered
```

Every public table row has the same number of cells. A span anchor stores its
span once. Each covered logical slot remains in the matrix and points to that
anchor. A caller can therefore inspect a literal slot without accidentally
treating it as duplicated source text.

The adapter keeps source lines for confirmed and unresolved cells. It retains
unreconciled detector text only as separately marked unresolved evidence.
`joinedText` never falls back to that candidate. Tagged-PDF header and body
roles remain optional evidence; Turnip does not infer them from row position.

Bounds remain optional source-inspection hints. They are normalized to the
upright visible page and work with `DocumentPage.size`; they are not raw
glyph coordinates, table geometry, or a public text-item API.

## Source references and page coverage

A `DocumentSourceReference` identifies one page, block, optional literal
table slot, and optional source line. `cell(for:)` preserves that literal
slot. `resolvedCell(for:)` is the separate operation that follows a
covered slot to its anchor. A covered slot never acquires an anchor line
silently.

Selected pages retain original zero-based indexes. Every selected page appears
once, including a page with no blocks. `needsOCR` reports that embedded
text is insufficient. Turnip does not run OCR. A fatal parse, password, or
selection failure throws instead of producing an invented empty page.

The current scope is digital PDFs with embedded text. Turnip does not expose
domain-specific interpretation. It returns strings, lines, table structure,
warnings, and optional source evidence. A consuming app decides what any value
means.

## Versions and validation

The private bridge schema and public structured-document schema evolve
independently. The current public schema is v2. A bridge change can remain
private when the Swift adapter preserves the v2 behavior. A public change to
field meaning, ordering, or cell semantics requires a new public schema
version.

Within one PDF, options set, public schema, and Turnip build, validation
checks stable semantic order. It does not treat processing duration, JSON byte
layout, or identifiers across engine upgrades as stable output. The structured
contract tests validate rectangular rows, multiline and repeated content,
blanks and unresolved evidence, spans, page fragments, text-table-text order,
literal source references, and Codable round trips.

See [StructuredDocument.md](StructuredDocument.md) for the v2 field contract
and consumer rules.
