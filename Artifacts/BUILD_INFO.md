# DocumentKitCore build provenance

- pdf-inspector version: `1.14.2`
- pdf-inspector repository: `swiftlysingh/pdf-inspector`
- pdf-inspector upstream source revision: `2322bcce4cd9458d24399bf8fee42f1aa201c8c1`
- Turnip patch: `Patches/pdf-inspector-embed-apple-cmaps.patch`
- Turnip patch SHA-256: `76ab34609c4c83342a6efdcc5b1a54ed2b52302d0f3a416fbc55c801ac19b414`
- Rust toolchain: `1.96.0`
- Xcode: `27.0 (27A5194q)`

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
