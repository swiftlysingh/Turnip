# DocumentKit

DocumentKit extracts Markdown from PDFs locally in native Swift apps. It wraps
Firecrawl's Rust [`pdf-inspector`](https://github.com/firecrawl/pdf-inspector)
engine behind a small Swift API and ships the engine as a prebuilt
XCFramework for iOS and macOS.

```swift
let extraction = try await DocumentKit.extract(pdfData)

print(extraction.markdown)
print(extraction.inspection.kind)
print(extraction.warnings)
```

DocumentKit is private while the pre-release API is being validated. The
current scope is deliberately narrow: **PDF input to Markdown output**. It does not generate
PDFs, convert Office documents, perform OCR, use an LLM, upload files, or expose
plain-text and structured-JSON output yet.

## Why it exists

`pdf-inspector` already does the hard PDF work well: classification, embedded
text extraction, reading order, layout analysis, table-aware Markdown, and
page-level OCR routing. DocumentKit makes that engine practical in Swift by
adding:

- an idiomatic `async throws` API with typed results and errors;
- a stable, ownership-safe C bridge hidden from client apps;
- Apple device, simulator, and macOS slices in one local XCFramework;
- zero-based page indexes everywhere in the Swift API;
- a native PDF-versus-Markdown sample app;
- a reproducible parity and quality benchmark harness.

Processing is local and synchronous inside Rust. The Swift API moves the work
off the caller's executor, but cancellation cannot interrupt a parse already in
progress.

## Requirements

- iOS 16 or later
- macOS 13 or later
- Swift 6.2 or later to build this checkout

The packaged engine contains these architectures:

- iOS device: arm64
- iOS Simulator: arm64 and x86_64
- macOS: arm64 and x86_64

## Installation

The repository currently uses a checked-in local binary target. Add this
private package in Xcode using its repository URL, then add the `DocumentKit`
product to your app target:

```text
git@github.com:swiftlysingh/DocumentKit.git
```

The binary target is an implementation detail. Client code imports only:

```swift
import DocumentKit
```

## API

### Extract Markdown

```swift
let result = try await DocumentKit.extract(pdfData)

result.markdown
result.inspection.pageCount
result.inspection.layout?.pagesWithTables
result.inspection.pagesNeedingOCR
result.warnings
```

File URLs are supported too:

```swift
let result = try await DocumentKit.extract(contentsOf: pdfURL)
```

The URL overload checks the file size before reading. Both overloads reject
inputs larger than `DocumentKit.maximumInputSize`, currently 100 MiB.

Select pages or unlock a password-protected PDF with `DocumentOptions`:

```swift
let options = DocumentOptions(
    pageIndexes: [0, 2, 3],
    password: suppliedPassword
)
let result = try await DocumentKit.extract(pdfData, options: options)
```

Page indexes are zero-based, unique, and strictly ascending. `nil` means the
entire document. `inspection.pageCount` always reports the source PDF's total
page count, even when only some pages were selected. Selected Markdown remains
in document order.

### Inspect without extracting

```swift
let inspection = try await DocumentKit.inspect(pdfData)
```

`inspect` is the lighter routing call. It classifies the PDF, counts pages, and
identifies pages that likely need OCR, but does not build Markdown. Because it
uses the engine's detect-only mode, `inspection.layout` and
`inspection.hasEncodingIssues` are `nil`.

`extract` is not implemented as `inspect` followed by another parse. It makes
one full engine call and returns both Markdown and the richer inspection data,
including layout and encoding analysis. Apps that need Markdown should call
`extract` directly.

Page selection limits the requested output and OCR-routing results. It does not
promise proportional speedups because some engine checks may still examine
document-wide metadata. Benchmark the documents that matter to your app.

All public page indexes are zero-based. OCR confidence and extraction
confidence are engine signals, not guarantees that text is correct.

### Errors

`DocumentKitError` distinguishes empty and oversized inputs, missing or wrong
passwords, invalid and out-of-range page selections, invalid PDFs, documents
with no extractable text, and internal engine failures.
A scanned or image-only PDF commonly produces `noExtractableText` with its
inspection attached. DocumentKit reports the OCR need but does not perform OCR.

## Sample app

[`Examples/DocumentKitDemo`](Examples/DocumentKitDemo) is a native macOS
SwiftUI app. It opens or accepts a dropped PDF, renders the source with PDFKit,
and shows selectable raw Markdown beside it. It also exercises page selection
and password-protected PDFs. Raw Markdown is intentional. It makes reading-order,
table, and encoding problems easy to see.

```sh
xcodebuild \
  -project Examples/DocumentKitDemo/DocumentKitDemo.xcodeproj \
  -scheme DocumentKitDemo \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Benchmarks

The [`Benchmarks`](Benchmarks) package separates three questions:

1. **Bridge parity:** does DocumentKit return the exact Markdown produced by
   the pinned raw Rust engine?
2. **Determinism:** do repeated runs return identical Markdown and inspection
   metadata?
3. **Extraction quality:** how closely does output match reviewed Markdown
   ground truth?

The existing four-document external baseline is checksum-pinned and remains a
useful historical parity check. The committed project-owned smoke fixture runs
in CI with source-authored draft truth. Neither is the v0.2 accuracy corpus.

The v0.2 release gate is being built as a 20-plus-document, rights- and
provenance-tracked corpus with independently authored and reviewed canonical
Markdown. Until those PDFs are retrieved, hashed, and their truth is locked,
DocumentKit does not claim a release-quality extraction score.

See [`Benchmarks/README.md`](Benchmarks/README.md) for the manifest, fetch, run,
and ground-truth workflow. See
[`Benchmarks/Reports/v0.1-baseline.json`](Benchmarks/Reports/v0.1-baseline.json)
for the recorded parity, quality, and local timing baseline.

## Engine pin and rebuild

The upstream revision is fixed in [`ENGINE_REVISION`](ENGINE_REVISION). The
build does not follow `main` or a semver range. `Scripts/prepare-engine.sh`
clones that exact revision into the ignored `Build` directory and applies the
tracked Apple patch.

The patch makes three narrow changes to the pinned engine:

- embeds Adobe CMaps so CID text extraction never depends on a build-machine
  filesystem path;
- uses lopdf's single-threaded parser on Apple targets to keep the binary and
  build footprint bounded;
- evaluates sparse-text and undecodable-font quality heuristics against the
  selected pages when a page filter is supplied.

To rebuild all five Rust slices and replace the local artifact:

```sh
Scripts/build-xcframework.sh
```

Rust 1.96.0 is pinned in `rust-toolchain.toml`. The build script creates and
then verifies the XCFramework architecture and header layout.

## Project layout

```text
Sources/DocumentKit/           Public Swift API and private wire decoder
Native/DocumentKitCore/        Rust static-library bridge and C header
Artifacts/                     Prebuilt local XCFramework
Patches/                       Minimal patch applied to pinned pdf-inspector
Examples/DocumentKitDemo/      Native PDF-versus-Markdown sample app
Benchmarks/                    Corpus manifest, runner, and methodology
Scripts/                       Reproducible engine build and artifact checks
Tests/                         Swift API and real-PDF bridge tests
```

The detailed data flow and ownership rules live in
[`Documentation/Architecture.md`](Documentation/Architecture.md).

## Roadmap

The likely next output is plain text, followed by a typed structured document
model that can be encoded as JSON. Those should be additional renderers over a
stable internal result, not a generic `convert` method. OCR is a separate
provider boundary and remains out of the current SDK scope.

## Security and limitations

PDFs are complex, potentially hostile input. DocumentKit catches Rust panics
at the C boundary and limits input bytes, but it parses in-process and is not a
sandbox. It cannot catch process aborts or out-of-memory failures. Read
[`SECURITY.md`](SECURITY.md) before accepting arbitrary untrusted documents.

The extraction quality is inherited from the pinned engine. Known hard cases
include malformed fonts, right-to-left text, unusual reading order, and complex
tables. Always preserve warnings and provenance instead of treating a Markdown
string as proof of correctness.

## License

DocumentKit is MIT licensed. It includes compiled `pdf-inspector` code and
Adobe CMap data under their respective terms. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
