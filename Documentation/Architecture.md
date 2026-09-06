# Architecture

Turnip keeps the public Swift API independent from the Rust engine and its
wire format.

```text
PDF Data or URL
      |
      v
Turnip Swift API
  input/options validation, async handoff, typed errors
      |
      v
DocumentKitCore C ABI
  borrowed PDF/password/page buffers in, owned UTF-8 JSON buffer out
      |
      v
pinned pdf-inspector Rust engine
  detect-only or one shared full extraction pipeline
      |
      v
private versioned JSON envelope
      |
      v
typed DocumentInspection, DocumentExtraction, or ExtractedDocument
```

## Public boundary

`Turnip.inspect` uses the engine's detect-only mode. It is intended for
cheap routing and returns no layout or encoding analysis.

`Turnip.extract` uses the full mode once. The loaded PDF is shared across
classification and extraction inside `pdf-inspector`; Turnip does not call
`inspect` first. The returned `DocumentExtraction` contains Markdown, the full
inspection, and warnings.

`Turnip.extractDocument` also uses one loaded PDF and the same table detection
and reading-order work as Markdown extraction. The engine captures page-local
text and table evidence before Markdown presentation cleanup. This matters
because Markdown formatting can merge continuation rows, extract footnotes,
remove empty rows, add a syntactic header separator, and join table fragments
across pages. Structured v1 keeps the earlier rows, lines, blank slots, repeated
headers, and page boundaries. The established Markdown renderer remains in
place so its output does not change.

The public API does not expose Rust, C pointers, the private JSON schema, or a
generic converter protocol. The private bridge schema and public document
schema have separate versions. The current bridge envelope is version 2; the
public structured document is version 1. Bridge schema changes are validated
inside Turnip and do not define the consumer JSON contract.

`DocumentOptions` is shared by inspection and both extraction APIs. A `nil` page list
means the entire source PDF. A non-`nil` list must be nonempty, zero-based,
unique, and strictly ascending. A password is optional. Missing and incorrect
passwords deliberately map to the same `encryptedPDF` error because the pinned
engine does not distinguish them.

## Native ownership

Swift owns the input `Data`, page-index buffer, and password bytes for the
duration of each C call. Rust borrows that memory and never stores the input
pointers. Passwords are not serialized into the response or persisted by the
SDK.

Rust serializes a schema-versioned private response into `Box<[u8]>` and returns
the pointer plus length as `DocumentKitBuffer`. Swift copies those bytes into
`Data` and always returns the original buffer through
`documentkit_buffer_free`. Rust allocations are never freed by Swift's
allocator.

Every exported Rust function catches unwinding panics. Release builds retain
`panic = "unwind"` for that reason. Abort, stack exhaustion in non-unwinding
paths, OOM, and operating-system termination cannot be caught.

## Index and coordinate conventions

Upstream OCR and layout page numbers are one-based. The bridge converts all
public page collections to zero-based indexes. The Swift transport rejects a
successful response with a non-positive page count or an out-of-range page
index as an engine failure.

`DocumentInspection.pageCount` is always the source document's total page
count. For a selected operation, Markdown, structured pages, OCR page lists,
OCR reasons, layout page lists, encoding warnings, and warnings are filtered to
the selection. Selected output stays in source-document order and structured
pages keep their original indexes.

The bridge converts selected pages back to the engine's one-based convention.
The tracked engine patch also makes sparse-text and undecodable-font quality
heuristics use only the processed selection. Some detect-only font analysis is
still document-wide, so page selection is an output contract rather than a
guaranteed proportional performance optimization.

Structured bounds use normalized `x`, `y`, `width`, and `height`. The origin is
the top-left of the upright visible page after applying the inherited CropBox,
its nonzero origin, page rotation, and inherited `/UserUnit`. Page sizes remain
in PDF points. The engine transforms all rectangle corners, takes their
enclosing rectangle, and clips real geometry to the visible page before
normalization. Native PDF rectangles may use signed extents, so the engine
canonicalizes their endpoint order first. Public widths and heights are always
positive. Wholly outside, non-finite, or otherwise unavailable geometry is
omitted instead of replaced with zeros. Swift validates every bridge rectangle
before making it public.

Text height is sometimes estimated from font size because PDF text operators
do not always provide a glyph box. Bounds are suitable for taking a user back
to a source region, but callers should allow padding and must not treat them as
pixel-perfect highlights. A cell bound encloses its positioned text evidence,
not the entire painted cell rectangle, so a blank or unresolved slot may have
no location.

## Structured document invariants

Every requested page appears exactly once. `extracted` means the page was
processed, not that its contents are guaranteed correct. `needsOCR` may include
best-effort embedded text, while image-only pages normally have no blocks.
`extractionFailed` is reserved for an engine capable of reporting a recoverable
page-local failure. The pinned engine does not currently emit it. Page
extraction, document parse, encryption, invalid selection, and other engine
failures still throw.

Blocks have deterministic IDs in the form `p{pageIndex}-b{ordinal}`. They are
stable only for the same input, options, public schema, and engine. Text and
table blocks appear in inferred page reading order. Tables stay page-local and
cells are row-major. A spanning cell is emitted once at its top-left anchor;
covered slots are omitted. All remaining slots have an explicit cell. An empty
cell has no decoded text in an established slot, while an unresolved cell says
the engine could not reconcile its raw cell string with positioned source
items. For an unresolved cell, positioned lines remain the source evidence and
an optional detector-text field preserves a conflicting raw grid association.
Neither representation is silently discarded, and neither cell state proves
that the visible region is blank.

Table roles are `header`, `body`, or `unknown`. A role is emitted only when the
source structure provides evidence. The first row is not labeled as a header
just because Markdown syntax needs one.

See [StructuredDocument.md](StructuredDocument.md) for the public JSON fields,
versioning rules, source references, and downstream validation boundary.

## Apple packaging

`DocumentKitCore.xcframework` contains three platform variants built from five
Rust targets:

| Variant | Rust targets |
| --- | --- |
| iOS device | `aarch64-apple-ios` |
| iOS Simulator | `aarch64-apple-ios-sim`, `x86_64-apple-ios` |
| macOS | `aarch64-apple-darwin`, `x86_64-apple-darwin` |

The C header and module map are copied into every variant. SwiftPM exposes the
binary only to the source `Turnip` target, so client apps import the Swift
module rather than the bridge.

The pinned upstream native code normally discovers Adobe CMaps through
`CARGO_MANIFEST_DIR`, which cannot exist inside an installed app. The tracked
Apple patch embeds those bytes using the same mechanism upstream uses for
WebAssembly.

## Concurrency and cancellation

Parsing is synchronous and CPU-bound. Swift runs it in a detached task so it
does not occupy the caller's actor. Cancellation is checked immediately before
and after the native call. Upstream exposes no cancellation hook, so work that
has already entered Rust runs to completion before the cancelled task returns.

The SDK does not impose a global concurrency queue. Apps doing batch
processing should limit concurrent calls based on their memory budget.

## Benchmark contracts

The benchmark package is macOS-only and intentionally outside the SDK API. It
compares `Turnip.extract(data).markdown` and
`PDFDocument(data: data)?.string`, each passed to one frozen AMEX adapter. The
adapter sees only its raw candidate string; it does not receive PDF bytes,
truth, page-level PDFKit text/layout, or candidate-specific expected values.

Manifest validation pins PDF/truth checksums, bytes, pages, the engine revision,
and the adapter ruleset plus normalized adapter/scorer source aggregate.
Structured truth has a checksum-pinned, human-reviewable deterministic canonical
Markdown projection with exact financial associations. Every truth group has a
checksum-pinned review record binding its source-variant set, truth/canonical
hashes, statement currency, source-only independent author/reviewer prompts,
and no-candidate-output rendered-page adjudication. Standard and
screen-reader-shaped variants that share truth are one robustness group, not
independent periods.

Raw-output and full ordered semantic-output determinism are required. Failed
cases remain in all quality denominators with zero scores. Detailed and
shareable reports are redacted DTOs protected by a privacy sentinel and key
allowlist; they contain safe reproducibility metadata (including sanitized code
revision and non-host machine model) but no private input identifiers, values,
paths, hashes, or raw surfaces. Private local inputs and reports belong under
ignored `Benchmarks/Private/`.

See [BenchmarkTruth.md](BenchmarkTruth.md) for canonicalization, scoring, and
review requirements.
