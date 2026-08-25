# Third-party notices

## pdf-inspector

Turnip includes compiled portions of
[`swiftlysingh/pdf-inspector`](https://github.com/swiftlysingh/pdf-inspector), a
fork of [`firecrawl/pdf-inspector`](https://github.com/firecrawl/pdf-inspector),
pinned to version 1.14.2 and source commit
`2322bcce4cd9458d24399bf8fee42f1aa201c8c1`.

Its copyright notice and MIT terms are reproduced with the other Rust
dependencies in [`RUST_THIRD_PARTY_LICENSES.md`](RUST_THIRD_PARTY_LICENSES.md).

## Adobe CMaps

The Apple binary embeds Adobe CMap data redistributed by `pdf-inspector` for
CID-encoded PDF text extraction. Its complete terms are reproduced from
`pdf-inspector`'s `external/bcmaps/LICENSE` in
[`RUST_THIRD_PARTY_LICENSES.md`](RUST_THIRD_PARTY_LICENSES.md).

## Rust dependencies

The exact transitive crate versions and checksums are fixed in
`Native/DocumentKitCore/Cargo.lock`. The complete normal and build dependency
inventory for every supported Apple target, including every explicit license,
notice, copyright, and nested asset-license file in those package sources, is
reproduced in
[`RUST_THIRD_PARTY_LICENSES.md`](RUST_THIRD_PARTY_LICENSES.md).

`Scripts/generate-rust-licenses.sh --check` makes CI fail when that generated
notice no longer matches the locked dependency graph. This notice is not a
substitute for a release-time legal review.
