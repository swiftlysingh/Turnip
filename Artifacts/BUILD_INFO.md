# DocumentKitCore build provenance

- pdf-inspector version: `1.14.1`
- pdf-inspector revision: `f4aab3b36f7fa1752c65ea45fa64be1274f671cf`
- Rust toolchain: `1.96.0`
- Xcode: `26.4.1 (17E202)`
- Checksums: [`SHA256SUMS`](SHA256SUMS)

The artifact was built with CMaps embedded and the Apple single-threaded lopdf
configuration from the tracked patch. Rebuilds must update this file and pass
`Scripts/verify-artifact.sh` plus Swift runtime and parity tests.
