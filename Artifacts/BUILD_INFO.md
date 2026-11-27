# DocumentKitCore build provenance

- pdf-inspector version: `1.25.2`
- pdf-inspector repository: `swiftlysingh/pdf-inspector`
- pdf-inspector upstream source revision: `ac05c0c9d28a66de7a4dcaf14435e3138a8c444c`
- Rust toolchain: `1.96.0`
- Default architectures: `arm64`-only (`aarch64-apple-darwin`, `aarch64-apple-ios`, `aarch64-apple-ios-sim`); `x86_64` slices are opt-in via `Scripts/build-xcframework.sh --include-x86-64`.
- Binary packaging: pre-linked single-object static archives (`xcrun strip -S`, `xcrun ld -r -S -exported_symbols_list Native/DocumentKitCore/exports.txt`, `xcrun strip -S`, `xcrun libtool -static -D`) exporting only the 9 `_documentkit_*` C ABI functions with zero `__DWARF` and zero `__LLVM` sections.
- Release distribution: tagged GitHub Releases attach `DocumentKitCore-<version>.xcframework.zip` and update `Package.swift` to reference it via `.binaryTarget(name:url:checksum:)`. Local builds write to the gitignored `Artifacts/DocumentKitCore.xcframework`.

The artifact includes indirect Form resource decoding, first-transaction-row
deduplication, embedded CMaps, the Apple single-threaded lopdf configuration,
selection-aware sparse-text and font-quality heuristics, explicit sparse
single-byte ToUnicode mappings with per-byte fallback, and source-preserving
structured capture from the pinned fork, shared visible-page box resolution,
and consistent OCR coverage after reclassification. Build paths are remapped to
`/DocumentKit`, `/Cargo`, and `/BuildUser`. Rebuilds must update this file when
bumping the pinned engine and pass `Scripts/verify-artifact.sh` plus Swift
runtime and parity tests. Artifact verification confirms the version, source
revision, exact 9-symbol export list, single-object archive structure, and
absence of `__DWARF`/`__LLVM` sections in every packaged slice.
`Turnip.engineRevision` reports that exact source revision. Compile-time
verification requires an exact clean `HEAD`.
