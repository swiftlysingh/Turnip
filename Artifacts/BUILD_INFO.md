# DocumentKitCore build provenance

- pdf-inspector version: `1.24.0`
- pdf-inspector repository: `swiftlysingh/pdf-inspector`
- pdf-inspector upstream source revision: `67cda0ba18ca31b12f3ae94a0c0c5c9b6f390b18`
- Turnip patch: `Patches/pdf-inspector-embed-apple-cmaps.patch`
- Turnip patch SHA-256: `125f2dee8a7e969976075445057913a15b0badc9ab1b65865ecd53ce3214a4dd`
- Rust toolchain: `1.96.0`
- Xcode: `27.0 (27A266a)`

The artifact includes indirect Form resource decoding and first-transaction-row
deduplication from the pinned fork. It uses upstream's embedded CMaps and the
tracked patch's Apple single-threaded lopdf configuration, explicit sparse
single-byte ToUnicode mappings, and source-preserving structured capture before
Markdown presentation cleanup. Build paths were remapped to `/DocumentKit`,
`/Cargo`, and `/BuildUser`. Rebuilds must update this file and pass
`Scripts/verify-artifact.sh` plus Swift runtime and parity tests. Artifact
runtime checks confirm the version and upstream source revision in every
packaged library slice. `Turnip.engineRevision` reports that upstream
source revision, not the patch state. Compile-time verification requires the
exact `HEAD` plus tracked-patch tree.
