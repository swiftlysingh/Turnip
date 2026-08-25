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
  detect-only or full extraction
      |
      v
private versioned JSON envelope
      |
      v
typed DocumentInspection or DocumentExtraction
```

## Public boundary

`Turnip.inspect` uses the engine's detect-only mode. It is intended for
cheap routing and returns no layout or encoding analysis.

`Turnip.extract` uses the full mode once. The loaded PDF is shared across
classification and extraction inside `pdf-inspector`; Turnip does not call
`inspect` first. The returned `DocumentExtraction` contains Markdown, the full
inspection, and warnings.

The public API does not expose Rust, C pointers, the private JSON schema, or a
generic converter protocol. Plain text and structured output can be added as
typed results without changing the native transport.

`DocumentOptions` is shared by inspection and extraction. A `nil` page list
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
count. For a selected operation, Markdown, OCR page lists, OCR reasons, layout
page lists, encoding warnings, and warnings are filtered to the selection.
Selected Markdown stays in source-document order.

The bridge converts selected pages back to the engine's one-based convention.
The tracked engine patch also makes sparse-text and undecodable-font quality
heuristics use only the processed selection. Some detect-only font analysis is
still document-wide, so page selection is an output contract rather than a
guaranteed proportional performance optimization.

Turnip does not expose positioned text or coordinates. A future
structured model must define one normalized coordinate space before those
fields become public.

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
