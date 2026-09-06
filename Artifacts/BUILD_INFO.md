# DocumentKitCore build provenance

- pdf-inspector version: `1.14.2`
- pdf-inspector repository: `swiftlysingh/pdf-inspector`
- pdf-inspector upstream source revision: `2322bcce4cd9458d24399bf8fee42f1aa201c8c1`
- Turnip patch: `Patches/pdf-inspector-embed-apple-cmaps.patch`
- Rust toolchain: `1.96.0`
- Xcode: `26.3 (17C529)`
- Checksums: [`SHA256SUMS`](SHA256SUMS)

The artifact includes indirect Form resource decoding and first-transaction-row
deduplication from the pinned fork. It was built with CMaps embedded, the Apple
single-threaded lopdf configuration, selection-aware sparse-text/font quality
heuristics, and source-preserving structured capture before Markdown presentation
cleanup from the tracked patch. Rebuilds must update this file and pass
`Scripts/verify-artifact.sh` plus Swift runtime and parity tests. Artifact
runtime checks confirm the version and upstream source revision in every
packaged library slice. `Turnip.engineRevision` reports that upstream
source revision, not the patch state. Compile-time verification requires the
exact `HEAD` plus tracked-patch tree, and `SHA256SUMS` pins the revision, patch,
build inputs, and every library slice.
