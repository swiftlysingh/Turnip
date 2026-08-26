# DocumentKitCore build provenance

- pdf-inspector version: `1.14.2`
- pdf-inspector repository: `swiftlysingh/pdf-inspector`
- pdf-inspector upstream source revision: `2322bcce4cd9458d24399bf8fee42f1aa201c8c1`
- Turnip patch: `Patches/pdf-inspector-embed-apple-cmaps.patch`
- Rust toolchain: `1.96.0`
- Packaging Xcode: `26.4.1 (17E202)`
- Turnip source paths: remapped beneath `/DocumentKit`
- Cargo source paths: remapped beneath `/Cargo`

The artifact includes indirect Form resource decoding and first-transaction-row
deduplication from the pinned fork. It was built with CMaps embedded, the Apple
single-threaded lopdf configuration, and selection-aware sparse-text/font
quality heuristics from the tracked patch. Rebuilds must update this file and
pass `Scripts/verify-artifact.sh` plus Swift runtime and parity tests. Artifact
runtime checks confirm the version and upstream source revision in every
packaged library slice. `Turnip.engineRevision` reports that upstream
source revision, not the patch state. Compile-time verification requires the
exact `HEAD` plus tracked-patch tree.
