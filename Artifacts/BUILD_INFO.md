# DocumentKitCore build provenance

- Turnip source revision: `cee676c8458c09e29e2cae2e263a06262786930c`

- pdf-inspector version: `1.14.2`
- pdf-inspector repository: `swiftlysingh/pdf-inspector`
- pdf-inspector upstream source revision: `2322bcce4cd9458d24399bf8fee42f1aa201c8c1`
- Turnip patch: `Patches/pdf-inspector-embed-apple-cmaps.patch`
- Turnip patch SHA-256: `22c266b3c3f0f1e0fe66934e05ccd826cbdad1765c571da8c113b5bfb8ce986f`
- Rust toolchain: `1.96.0`
- Xcode: `27.0 (27A266a)`
- Host build dependency profile: `strip = "none"` to keep Rust 1.96/macOS 27 proc-macro dylibs loadable; final release static libraries remain `strip = "symbols"`.

The artifact includes indirect Form resource decoding and first-transaction-row
deduplication from the pinned fork. It was built with CMaps embedded, the Apple
single-threaded lopdf configuration, selection-aware sparse-text/font quality
heuristics, explicit sparse single-byte ToUnicode mappings with per-byte fallback,
and source-preserving structured capture before Markdown presentation cleanup from
the tracked patch. Build paths were remapped to `/DocumentKit`,
`/Cargo`, and `/BuildUser`. Rebuilds must update this file and pass
`Scripts/verify-artifact.sh` plus Swift runtime and parity tests. Artifact
runtime checks confirm the version and upstream source revision in every
packaged library slice. `Turnip.engineRevision` reports that upstream
source revision, not the patch state. Compile-time verification requires the
exact `HEAD` plus tracked-patch tree.
