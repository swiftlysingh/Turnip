# Third-party notices

## pdf-inspector

DocumentKit includes compiled portions of
[`firecrawl/pdf-inspector`](https://github.com/firecrawl/pdf-inspector), pinned
to version 1.14.1 and source commit
`f4aab3b36f7fa1752c65ea45fa64be1274f671cf`.

Copyright (c) 2026 Firecrawl

Licensed under the MIT License. The upstream license text is reproduced in
`ThirdPartyLicenses/pdf-inspector-LICENSE`.

## Adobe CMaps

The Apple binary embeds Adobe CMap data redistributed by `pdf-inspector` for
CID-encoded PDF text extraction. The license text is reproduced in
`ThirdPartyLicenses/adobe-bcmaps-LICENSE`.

## Rust dependencies

The exact transitive crate versions and checksums are fixed in
`Native/DocumentKitCore/Cargo.lock`. Run `Scripts/list-rust-licenses.sh` after
preparing the pinned engine to review the license declarations for the crates
resolved for an Apple build. No dependency in the current lockfile reports an
undeclared license.

Before a public binary release, regenerate that inventory, review each resolved
license and bundled asset, and add any notices required by those licenses. The
current repository remains private and this notice is not a substitute for a
release-time legal review.
