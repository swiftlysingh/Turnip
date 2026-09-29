# DocumentKitCore build provenance

- Turnip source revision: `9687c4a85c854cd78b8f5d368228495e38efd517`

- pdf-inspector version: `1.24.0`
- pdf-inspector repository: `swiftlysingh/pdf-inspector`
- pdf-inspector upstream source revision: `714c6c80bed26040026d50985b667a68ff2f5fbc`
- Rust toolchain: `1.96.0`
- Xcode: `27.0 (27A266a)`
- Host build dependency profile: `strip = "none"` to keep Rust 1.96/macOS 27 proc-macro dylibs loadable; final release static libraries remain `strip = "symbols"`.

The artifact includes indirect Form resource decoding, first-transaction-row
deduplication, embedded CMaps, the Apple single-threaded lopdf configuration,
selection-aware sparse-text and font-quality heuristics, explicit sparse
single-byte ToUnicode mappings with per-byte fallback, and source-preserving
structured capture from the pinned fork, shared visible-page box resolution,
and consistent OCR coverage after reclassification. Build paths were remapped to
`/DocumentKit`, `/Cargo`, and `/BuildUser`. Rebuilds must update this file and
pass `Scripts/verify-artifact.sh` plus Swift runtime and parity tests. Artifact
runtime checks confirm the version and source revision in every packaged
library slice. `Turnip.engineRevision` reports that exact source revision.
Compile-time verification requires an exact clean `HEAD`.
