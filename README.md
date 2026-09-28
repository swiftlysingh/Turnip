# Turnip

Turnip extracts typed document structure and Markdown from PDFs locally in
native Swift apps. It wraps a pinned build of the Rust
[`pdf-inspector`](https://github.com/swiftlysingh/pdf-inspector) engine behind a
small Swift API and ships the engine as a prebuilt XCFramework for iOS and
macOS.

```swift
let document = try await Turnip.extractDocument(pdfData)

for page in document.pages {
    print(page.pageIndex, page.status, page.blocks.count)
}

let json = try JSONEncoder().encode(document)
```

Turnip is pre-release. The current scope is deliberately narrow: local PDF
inspection and extraction. It does not generate PDFs, convert Office documents,
perform OCR, use an LLM, upload files, or interpret financial values.

## Why it exists

`pdf-inspector` already does the hard PDF work well: classification, embedded
text extraction, reading order, layout analysis, table-aware Markdown, and
page-level OCR routing. Turnip makes that engine practical in Swift by
adding:

- an idiomatic `async throws` API with typed results and errors;
- a stable, ownership-safe C bridge hidden from client apps;
- Apple device, simulator, and macOS slices in one local XCFramework;
- zero-based page indexes everywhere in the Swift API;
- versioned `Codable` and `Sendable` document, page, text, and table models;
- a native PDF-versus-structured-JSON sample app;
- a reproducible AMEX transaction-integrity benchmark harness.

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
package in Xcode using its repository URL, then add the `Turnip` product
to your app target:

```text
https://github.com/swiftlysingh/Turnip.git
```

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

To rebuild all five Rust slices and replace the local artifact:

```sh
Scripts/build-xcframework.sh
```

Rust 1.96.0 is pinned in `rust-toolchain.toml`. The build script creates and
then verifies the XCFramework architecture and header layout.

## Project layout

```text
Sources/Turnip/                Public Swift APIs and models, DocC, and private wire decoder
Native/DocumentKitCore/        Rust static-library bridge and C header
Artifacts/                     Prebuilt local XCFramework
Examples/TurnipDemo/           Native PDF-versus-structured-JSON sample app
Benchmarks/                    Corpus manifest, runner, and methodology
Scripts/                       Reproducible engine, artifact, and DocC build checks
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

Turnip is MIT licensed. It includes compiled `pdf-inspector` code and
Adobe CMap data under their respective terms. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
