# Turnip

[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fswiftlysingh%2FTurnip%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/swiftlysingh/Turnip)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fswiftlysingh%2FTurnip%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/swiftlysingh/Turnip)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

<!-- TODO: add a short GIF or screenshot of Examples/TurnipDemo (macOS) showing a PDF beside the structured JSON. Record the real sample app with Benchmarks/Fixtures/Smoke/synthetic-amex-standard.pdf only; don't mock it and don't use a real statement. -->

Turn a PDF into typed Swift data and Markdown, on the device. Tables come back
as rows and cells. Extracted cell text retains references to its source page,
block and lines. No OCR, no LLM, no uploads.

Turnip wraps the Rust [`pdf-inspector`](https://github.com/swiftlysingh/pdf-inspector)
engine, a fork of [firecrawl/pdf-inspector](https://github.com/firecrawl/pdf-inspector),
and ships it as a prebuilt XCFramework for iOS 16+ and macOS 13+.

## What you get

- A versioned `Codable` document you can encode and pass around in Swift: pages, text blocks, and tables.
- Table-aware cells, including spans, empty slots, and unresolved content.
- Source references down to the cell and line. You resolve them by ID, without matching text.
- It runs on the device. The file is never uploaded.
- It's been battle-tested inside RetroBudget's credit card statement imports.

Pre-1.0. Turnip reads text-based PDFs. It flags pages that need OCR but doesn't
do OCR, and it leaves values like `(12.34)` as strings for your app to interpret.

## Quick start

```swift
let document = try await Turnip.extractDocument(pdfData)

for page in document.pages {
    print(page.pageIndex, page.status, page.blocks.count)
}

let json = try JSONEncoder().encode(document)
```

To try it in the sample app, open [`Examples/TurnipDemo`](Examples/TurnipDemo),
run the macOS scheme, and drop in
`Benchmarks/Fixtures/Smoke/synthetic-amex-standard.pdf`. For tagged releases,
SwiftPM fetches the prebuilt XCFramework from GitHub Releases automatically;
for an unreleased local checkout or after modifying the Rust bridge, build it
locally with `Scripts/build-xcframework.sh`.

## Why it exists

PDFKit gives you one string per page, so tables lose their rows and columns.
Cloud parsers keep the structure, but they need an upload and charge per page.
Turnip keeps the structure and the file stays on the device.

It wraps a pinned build of `pdf-inspector` and adds:

- an idiomatic `async throws` API with typed results and errors;
- a stable, ownership-safe C bridge hidden from client apps;
- Apple device, simulator, and macOS slices packaged in one prebuilt XCFramework;
- zero-based page indexes everywhere in the Swift API;
- versioned `Codable` and `Sendable` document, page, text, and table models;
- a native PDF-versus-structured-JSON sample app;
- a reproducible AMEX transaction-integrity benchmark harness.

Processing is local and synchronous inside Rust. The Swift API moves the work
off the caller's executor, but cancellation cannot interrupt a parse already in
progress.

## How it compares

| | Turnip | PDFKit text | Vision `RecognizeDocumentsRequest` | Cloud parsers (LlamaParse, Reducto, Firecrawl) |
|---|---|---|---|---|
| Runs | On device | On device | On device | Their servers, so the file is uploaded |
| Input | PDF with embedded text | PDF with embedded text | Images. Render PDF pages first | PDF (and more) |
| Scanned pages | Flags them as `needsOCR`, doesn't read them | No | Yes, it's OCR | Yes |
| Tables | Rows and cells, spans marked | No, one string per page | Rows and cells, spans as ranges | Yes |
| Trace back to source | Page, block, cell, line | Selections have bounds | Bounding regions | Bounding boxes (Reducto, Firecrawl layout blocks) |
| Minimum OS | iOS 16, macOS 13 | iOS 11, macOS 10.4 | iOS 26, macOS 26 | n/a |
| Cost | Free, MIT | Free | Free | LlamaParse 1–25 credits/page at $1.50 per 1,000 credits. Reducto r-1 $10 / 1,000 pages, r-1 mini $1 / 1,000. Firecrawl 1 credit/page |

If your users scan paper, use Vision. Turnip is for PDFs that already have
text, like bank statements, invoices, and reports.

Sources: PDFKit [`PDFDocument.string`](https://developer.apple.com/documentation/pdfkit/pdfdocument/string)
and `PDFPage.string`. Vision: [WWDC25 "Read documents using the Vision framework"](https://developer.apple.com/videos/play/wwdc2025/272/).
[LlamaParse pricing](https://developers.llamaindex.ai/llamaparse/general/pricing/).
[Reducto credit usage](https://docs.reducto.ai/reference/credit-usage) (list prices from Sep 1, 2026).
[Firecrawl document parsing](https://docs.firecrawl.dev/features/document-parsing).

## Requirements

- iOS 16 or later
- macOS 13 or later
- Swift 6.2 or later to build this checkout

The packaged engine contains `arm64` slices by default:

- iOS device: arm64
- iOS Simulator: arm64 (Apple Silicon)
- macOS: arm64 (Apple Silicon)

Generic iOS Simulator CI builds should exclude `x86_64` on `iphonesimulator`
(or pass `ARCHS=arm64`). If you need Intel `x86_64` macOS or iOS Simulator
slices locally, rebuild with `Scripts/build-xcframework.sh --include-x86-64`.

## Installation

Tagged releases distribute `DocumentKitCore.xcframework` as a GitHub Releases
binary target (`url` + SHA-256 `checksum`) so SwiftPM caches the ~11 MB archive
globally instead of committing new binary snapshots to Git history. Add this
package in Xcode using its repository URL, then add the `Turnip` product to
your app target:

```text
https://github.com/swiftlysingh/Turnip.git
```

Select version `0.4.0` or later in Xcode's package dependency settings (earlier
`0.1.0` through `0.3.0` tags remain intact in Git history with their checked-in
XCFramework).

The binary target is an implementation detail. Client code imports only:

```swift
import Turnip
```

## API

### Extract a structured document

```swift
let document = try await Turnip.extractDocument(pdfData)

let selectedDocument = try await Turnip.extractDocument(
    pdfData,
    options: DocumentOptions(
        pageIndexes: [0, 2],
        password: suppliedPassword
    )
)

let fileDocument = try await Turnip.extractDocument(contentsOf: pdfURL)
let json = try JSONEncoder().encode(document)
```

`ExtractedDocument` contains the public schema version, full inspection data,
every requested page, and extraction warnings. Each page has its original
zero-based PDF index, upright visible size, processing status, and text or
table blocks in inferred reading order. Each table contains rectangular `rows`
of `cells`. Cells distinguish confirmed text, empty slots, unresolved content,
and slots covered by a span. Repeated headers and duplicate rows are retained.
Table fragments stay on their source pages.

```swift
for page in document.pages {
    for block in page.blocks {
        guard case let .table(table) = block.content else { continue }
        for row in table.layoutRows {
            for cell in row.cells {
                if let text = cell.text {
                    print(text)
                }
            }
        }
    }
}
```

Schema version 3 keeps every physical detector row in `rows` and adds
`layoutRows`, the continuation-row and wrapped-content view shared with the
Markdown renderer. A layout cell lists the IDs of every original line that
contributed to it. Unresolved candidate text remains separate from confirmed
text.

Source references identify a page, block, optional table cell, and optional
line. A consumer can resolve them without matching text:

```swift
let source = DocumentSourceReference(
    pageIndex: 0,
    blockID: "p0-b1",
    row: 2,
    column: 2
)

guard let sourceCell = document.cell(for: source) else { return }
guard let sourceText = sourceCell.joinedText else { return }
print(sourceText)
```

Each `TextLine.id` identifies one source occurrence, even when two lines have
identical text. `sourceReference(forLineID:)` resolves that ID through the
existing source-reference API.

Turnip leaves values such as `5.00 CR`, `(12.34)`, and `1.234,56` as strings.
Dates, money, credit and debit conventions, merchants,
categories, reconciliation, and import decisions belong to the consuming app.
See [StructuredDocument.md](Documentation/StructuredDocument.md) for the JSON
contract, coordinates, partial extraction semantics, and a complete example.

### Extract Markdown

```swift
let result = try await Turnip.extract(pdfData)

result.markdown
result.inspection.pageCount
result.inspection.layout?.pagesWithTables
result.inspection.pagesNeedingOCR
result.warnings
```

File URLs are supported too:

```swift
let result = try await Turnip.extract(contentsOf: pdfURL)
```

The URL overload checks available file-size metadata before reading and still
enforces `Turnip.maximumInputSize`, currently 100 MiB, after loading.

Select pages or unlock a password-protected PDF with `DocumentOptions`:

```swift
let options = DocumentOptions(
    pageIndexes: [0, 2, 3],
    password: suppliedPassword
)
let result = try await Turnip.extract(pdfData, options: options)
```

Page indexes are zero-based, unique, nonempty, and strictly ascending. `nil` means the
entire document. `inspection.pageCount` always reports the source PDF's total
page count, even when only some pages were selected. Selected Markdown remains
in document order.

### Inspect without extracting

```swift
let inspection = try await Turnip.inspect(pdfData)
```

`inspect` is the lighter routing call. It classifies the PDF, counts pages, and
identifies pages that likely need OCR, but does not build Markdown. Because it
uses the engine's detect-only mode, `inspection.layout` and
`inspection.hasEncodingIssues` are `nil`.

Neither `extract` nor `extractDocument` is implemented as `inspect` followed by
another parse. Each makes one full engine call over one loaded PDF and returns
the richer inspection data collected by that pass. Apps that need Markdown
should keep calling `extract`; apps that need source structure should call
`extractDocument`. Structured extraction shares the detector and reading-order
pipeline, then stops before Markdown presentation rendering.

Page selection limits the requested output and OCR-routing results. It does not
promise proportional speedups because some engine checks may still examine
document-wide metadata. Benchmark the documents that matter to your app.

All public page indexes are zero-based. OCR confidence and extraction
confidence are engine signals, not guarantees that text is correct.
Warning page indexes identify only pages with page-local evidence. An empty
warning page list means the engine could not localize that document-level
warning; it does not mean every selected page.

### Errors

`TurnipError` distinguishes empty and oversized inputs, missing or wrong
passwords, invalid and out-of-range page selections, invalid PDFs, documents
with no extractable text, and internal engine failures.

The existing `inspect` and `extract` calls remain unchanged. v0.2 adds
`invalidPageSelection` and `pageOutOfRange`, so clients with exhaustive switches
over the pre-1.0 error enum must handle those cases when updating.
A scanned or image-only PDF commonly makes the Markdown API throw
`noExtractableText` with its inspection attached. Structured extraction instead
returns the requested pages with `needsOCR` status and warnings, so a caller can
account for incomplete coverage. Turnip reports the OCR need but does not
perform OCR.

## API documentation

On macOS with Xcode installed, build the static DocC archive locally with an
unused output path:

```sh
Scripts/build-documentation.sh /tmp/Turnip.doccarchive
```

The archive is built for the repository's current `/Turnip` hosting path.

## Sample app

[`Examples/TurnipDemo`](Examples/TurnipDemo) is a native iOS and
macOS SwiftUI app. Both versions open a PDF and show structured page and block
coverage alongside the encoded public JSON;
the macOS layout also renders the source with PDFKit and accepts file drops.
The app exercises page selection and password-protected PDFs. The macOS view
keeps the source PDF beside its structured output so source regions and reading
order can be inspected together.

```sh
xcodebuild \
  -project Examples/TurnipDemo/TurnipDemo.xcodeproj \
  -scheme TurnipDemo \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Benchmarks

The [`Benchmarks`](Benchmarks) package is a small macOS-only AMEX
transaction-integrity comparison. It measures exactly two local paths:
Turnip Markdown followed by a frozen AMEX adapter, and document-level
PDFKit text followed by that same adapter. It reports exact transaction-multiset
F1, diagnostic table-cell/content F1, critical-value accuracy, determinism,
and raw extraction timing separately. Each locked truth has a checksum-pinned
canonical Markdown projection and review record; paired standard and
screen-reader-shaped variants are robustness evidence, not independent periods.

Real benchmark inputs, truth, and reports stay in ignored
`Benchmarks/Private/`. The committed standard/screen-reader smoke pair is
wholly invented implementation coverage, not a claim about real statement
quality or a release result. Reports contain redacted metrics plus safe
reproducibility metadata (including a sanitized source revision and its local
verification status when provided),
never raw statement values or input identifiers. See
[`Benchmarks/README.md`](Benchmarks/README.md) for local use and
[`Documentation/BenchmarkTruth.md`](Documentation/BenchmarkTruth.md) for the
locked truth, review, holdout, and scoring contract.

## Engine pin and rebuild

The engine revision is fixed in [`ENGINE_REVISION`](ENGINE_REVISION). The build
does not follow `main` or a semver range. `Scripts/prepare-engine.sh` clones that
exact source revision into the ignored `Build` directory. `Turnip.engineRevision`
reports that commit. At compile time, the Rust build script rejects the prepared
engine unless it is the exact clean `HEAD`. `Scripts/verify-artifact.sh` checks
every packaged slice against the same pin. The pre-release pin uses the maintained
`swiftlysingh/pdf-inspector` fork, which owns the reusable extraction behavior.

To rebuild the `arm64` Rust slices locally into the gitignored
`Artifacts/DocumentKitCore.xcframework`:

```sh
Scripts/build-xcframework.sh
```

Pass `--include-x86-64` if you also need Intel macOS/iOS Simulator slices, or
`--zip Build/DocumentKitCore.xcframework.zip` to produce a SwiftPM release zip
and print its SHA-256 checksum. To test a locally built XCFramework when
`Package.swift` points at a published GitHub Release, set
`TURNIP_USE_LOCAL_XCFRAMEWORK=1` (or `TURNIP_LOCAL_XCFRAMEWORK_PATH=<package-relative/path/to/DocumentKitCore.xcframework>`):

```sh
TURNIP_USE_LOCAL_XCFRAMEWORK=1 swift test --parallel
```

Rust 1.96.0 is pinned in `rust-toolchain.toml`. The build script strips
`__DWARF` and `__LLVM` sections, pre-links each slice into a single object
exporting only the 9 `_documentkit_*` C functions, and runs
`Scripts/verify-artifact.sh`.

## Release

Run the Release workflow from `main` with a stable version such as `0.4.0`.
Before building or tagging, it requires successful Codemagic `SDK` and `Rust`
checks for that exact commit. It then builds, verifies, and archives
`DocumentKitCore-<version>.xcframework.zip` on Apple Silicon macOS, updates
`Package.swift` with the release URL and SHA-256 checksum, tags `v<version>`,
and publishes the GitHub Release with the zip attached. Missing, pending,
skipped, or failed checks block publication; a newer rerun supersedes an older
result. Finish the checks and rerun Release.

Run `Scripts/test-release-checks.sh` and `Scripts/test-artifact-tooling.sh` to
exercise the release guard and artifact tooling locally.

## Project layout

```text
Sources/Turnip/                Public Swift APIs and models, DocC, and private wire decoder
Native/DocumentKitCore/        Rust static-library bridge, exported-symbol list, and C header
Artifacts/                     Build provenance (local XCFramework builds are gitignored)
Examples/TurnipDemo/           Native PDF-versus-structured-JSON sample app
Benchmarks/                    Corpus manifest, runner, and methodology
Scripts/                       Reproducible engine, artifact, release, and DocC build checks
Tests/                         Swift API and real-PDF bridge tests
Documentation/                 Architecture and benchmark contracts
```

The detailed data flow and ownership rules live in
[`Documentation/Architecture.md`](Documentation/Architecture.md).

## Security and limitations

PDFs are complex, potentially hostile input. Turnip catches Rust panics
at the C boundary and limits input bytes, but it parses in-process and is not a
sandbox. It cannot catch process aborts or out-of-memory failures. Read
[`SECURITY.md`](SECURITY.md) before accepting arbitrary untrusted documents.

The extraction quality is inherited from the pinned engine. Known hard cases
include malformed fonts, right-to-left text, unusual reading order, and complex
tables. Positioned text height can be estimated from font size, so bounds are
not pixel-perfect highlights. Always preserve warnings, page status, source
lines, and provenance. Structured output is evidence for validation, not proof
that extraction matches the visible PDF.

## License

Turnip is MIT licensed. It includes compiled Rust dependencies and Adobe CMap
data under their respective terms. When redistributing the packaged engine,
include [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
