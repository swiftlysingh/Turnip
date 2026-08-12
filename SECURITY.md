# Security

## Supported version

DocumentKit is in private v0.1 development. Security fixes are applied to the
latest commit on `main`; no released version is supported yet.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private
security advisory flow for `swiftlysingh/DocumentKit`, or contact the repository
owner privately with a minimal reproducer and the affected engine revision.

## Threat model

DocumentKit parses PDF bytes in the app process. The 100 MiB input limit and
panic boundary reduce some failure modes, but they do not create hostile-input
isolation. A malicious PDF may still consume substantial CPU or memory, trigger
an abort, or exploit a defect in DocumentKit, `pdf-inspector`, lopdf, or another
transitive dependency.

For apps that accept arbitrary internet documents:

- apply a smaller product-specific byte and page limit where practical;
- avoid launching many parses concurrently;
- use an operating-system process or service sandbox when the product can
  support one;
- keep the engine pinned and review upstream security changes before updating;
- never infer that high confidence makes extracted content safe or correct;
- treat extracted Markdown as untrusted text before rendering HTML or feeding
  another parser.

## Current controls

- The upstream engine is pinned to a full source commit.
- Rust dependencies are locked in `Native/DocumentKitCore/Cargo.lock`.
- C entry points validate null, empty, and oversized input.
- Rust panics are caught before crossing the C ABI when unwinding is possible.
- Native buffers have one matching Rust deallocator and are copied before free.
- The Swift API exposes typed errors instead of raw engine internals.
- Corpus downloads and ground truth fail closed on checksum or rights errors.

## Known limitations

- Cancellation does not interrupt a Rust call already in progress.
- There is no timeout, page-count cap, object-depth cap, or memory sandbox yet.
- Password-protected PDFs are rejected by the public API.
- OCR is not bundled.
- The sample app is a development tool and not a hardened document sandbox.

Exact engine and dependency revisions should accompany every security report.
