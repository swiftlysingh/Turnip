# DocumentKitCore build provenance

- pdf-inspector version: `1.14.2`
- pdf-inspector repository: `swiftlysingh/pdf-inspector`
- pdf-inspector revision: `2322bcce4cd9458d24399bf8fee42f1aa201c8c1`
- Rust toolchain: `1.96.0`
- Xcode: `26.4.1 (17E202)`
- Checksums: [`SHA256SUMS`](SHA256SUMS)

The artifact includes indirect Form resource decoding and first-transaction-row
deduplication from the pinned fork. It was built with CMaps embedded, the Apple
single-threaded lopdf configuration, and selection-aware sparse-text/font
quality heuristics from the tracked patch. Rebuilds must update this file and
pass `Scripts/verify-artifact.sh` plus Swift runtime and parity tests. Artifact
verification matches this identity across the source pin, lockfile, notices,
headers, and every packaged library slice.
