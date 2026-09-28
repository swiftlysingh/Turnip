# DocumentKitCore build provenance

- Turnip source revision: `2659cc7f8caf528c335b4d03bf6ea15d1287c794`

- pdf-inspector version: `1.24.0`
- pdf-inspector repository: `swiftlysingh/pdf-inspector`
- pdf-inspector upstream source revision: `37c9ed68ee5a30ccbd086dd2ccf84ab26bc898d5`
- Rust toolchain: `1.96.0`
- Xcode: `27.0 (27A266a)`
- Host build dependency profile: `strip = "none"` to keep Rust 1.96/macOS 27 proc-macro dylibs loadable; final release static libraries remain `strip = "symbols"`.

The artifact includes indirect Form resource decoding, first-transaction-row
deduplication, embedded CMaps, the Apple single-threaded lopdf configuration,
selection-aware sparse-text and font-quality heuristics, explicit sparse
single-byte ToUnicode mappings with per-byte fallback, and source-preserving
structured capture from the pinned fork. Build paths were remapped to
`/DocumentKit`, `/Cargo`, and `/BuildUser`. Rebuilds must update this file and
pass `Scripts/verify-artifact.sh` plus Swift runtime and parity tests. Artifact
runtime checks confirm the version and source revision in every packaged
library slice. `Turnip.engineRevision` reports that exact source revision.
Compile-time verification requires an exact clean `HEAD`.
