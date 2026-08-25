# ``Turnip``

Extract Markdown from PDFs locally in iOS and macOS apps.

## Overview

Turnip wraps a pinned PDF engine behind a small Swift API. It reads PDF
data in the app process, produces Markdown when embedded text is available, and
reports classification, layout, encoding, and OCR-routing signals alongside the
result. It does not upload PDFs, call an LLM, convert Office documents, or
perform OCR.

```swift
import Turnip
import Foundation

let result = try await Turnip.extract(pdfData)

print(result.markdown)
print(result.inspection.kind)
print(result.warnings)
```

Use ``Turnip/extract(_:)`` when your app needs Markdown. Use
``Turnip/inspect(_:)`` when it only needs to classify a PDF and decide
whether another OCR-capable path is needed. `inspect` does not first extract
Markdown, so its layout and encoding fields are `nil`. File URLs use
``Turnip/extract(contentsOf:)`` and ``Turnip/inspect(contentsOf:)``.

## Select pages and handle passwords

All public page indexes are zero-based. A selection must be unique, nonempty,
and strictly ascending. Pass `nil` to process the whole document.

```swift
let options = DocumentOptions(
    pageIndexes: [0, 2, 3],
    password: suppliedPassword
)
let result = try await Turnip.extract(pdfData, options: options)
```

Turnip passes the supplied password to the engine and redacts it from
`DocumentOptions` descriptions and reflection. It limits every input to
``Turnip/maximumInputSize``. A parsed PDF still runs in the app process,
so apps that accept hostile documents should apply their own concurrency and
resource limits.

## Interpret the result

Markdown is an extraction result, not proof that every field is correct.
Preserve ``DocumentExtraction/warnings`` and the ``DocumentInspection`` with
the Markdown. In particular, ``DocumentWarning/Kind/ocrRequired`` means the
engine recommends OCR for one or more pages, and
``DocumentWarning/Kind/encodingIssues`` means the engine found decoding issues.

For a scanned or image-only PDF, extraction throws
``TurnipError/noExtractableText(_:)`` and includes the inspection that
explains the routing decision.

## Benchmark status

Both candidate pipelines are exact on the committed two-variant invented
fixture. The two variants share one four-transaction truth. The aggregate
report counts those four truth rows once per variant, so its eight figure is
case-rows rather than eight distinct transactions. That proves mechanical
benchmark-harness coverage, not a real-statement accuracy finding or a timing
claim. The synthetic corpus passes the mechanical gate, but it is not
real-holdout or product-adoption evidence. One unseen real statement period and
its paired variants are the minimum useful holdout. Three separate unseen
periods are required before a broader public accuracy claim.

The [repository benchmark methodology](https://github.com/swiftlysingh/DocumentKit/blob/main/Benchmarks/README.md)
defines the candidate boundary, frozen adapter, redacted reports, and holdout
rules.

## Topics

### Essentials

- ``Turnip/extract(_:)``
- ``Turnip/extract(_:options:)``
- ``Turnip/extract(contentsOf:)``
- ``Turnip/extract(contentsOf:options:)``
- ``Turnip/inspect(_:)``
- ``Turnip/inspect(_:options:)``
- ``Turnip/inspect(contentsOf:)``
- ``Turnip/inspect(contentsOf:options:)``
- ``Turnip/maximumInputSize``
- ``Turnip/engineRevision``
- ``DocumentOptions``

### Results

- ``DocumentExtraction``
- ``DocumentInspection``
- ``DocumentKind``
- ``DocumentLayout``
- ``PageOCRReasons``
- ``DocumentWarning``

### Errors

- ``TurnipError``
- ``PageSelectionError``
