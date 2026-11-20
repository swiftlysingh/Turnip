# Security

## Supported versions

Use the latest release, currently `0.3.0`. Security fixes are applied to
`main` first and included in the next release. Older releases do not receive
guaranteed backports.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. If GitHub private
vulnerability reporting is enabled, use the [private advisory form](https://github.com/swiftlysingh/Turnip/security/advisories/new).
If the form is unavailable, email [sayhi@swiftlysingh.com](mailto:sayhi@swiftlysingh.com)
privately. Include a minimal reproducer and the affected engine revision.

## Threat model

Turnip parses PDF bytes in the app process. The 100 MiB input limit and
panic boundary reduce some failure modes, but they do not create hostile-input
isolation. A malicious PDF may still consume substantial CPU or memory, trigger
an abort, or exploit a defect in Turnip, `pdf-inspector`, lopdf, or another
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
- Page selections are validated before they cross the native boundary.
- Password bytes are borrowed only for the native call and are not included in
  JSON responses, errors, descriptions, logs, benchmark output, or sample-app
  persistence.
- The AMEX benchmark fails closed on manifest/input checksum, structured-truth,
  canonical-Markdown, and checksum-pinned review/adjudication errors. Its
  private inputs and reports remain under ignored `Benchmarks/Private/`.
  Redacted output cannot serialize raw statement text, values, paths,
  input/truth/review hashes, or localized errors; it may contain only safe
  reproducibility metadata such as a sanitized source revision with an explicit
  local verification status and a non-host machine model.

## Known limitations

- Cancellation does not interrupt a Rust call already in progress.
- There is no timeout, page-count cap, object-depth cap, or memory sandbox yet.
- Missing and incorrect passwords intentionally share the same public error.
- Passwords and PDF bytes still exist in the app process while a call runs, so
  callers remain responsible for their own in-memory threat model.
- OCR is not bundled.
- The sample app is a development tool and not a hardened document sandbox.

Exact engine and dependency revisions should accompany every security report.
