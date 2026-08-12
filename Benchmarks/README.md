# DocumentKit benchmark runner

This is a small, local-only SwiftPM executable for benchmarking the
DocumentKit wrapper. It does not download a corpus and it never treats a
missing, unreviewed, or checksum-mismatched PDF as a valid run.

The runner deliberately has two acceptance layers:

1. **Upstream parity:** compare the Swift wrapper with a pinned raw
   `pdf-inspector` baseline. This is the first release gate. Markdown and
   inspection metadata should be identical; timing is reported separately.
2. **Human ground truth:** compare extracted Markdown with reviewed UTF-8
   Markdown. The built-in smoke evaluator reports case-insensitive token F1 and
   Markdown-structure F1 against explicit thresholds. Full-corpus runs can add
   a pinned external evaluator for richer layout metrics. Quality is not a
   substitute for wrapper parity.

## Corpus policy

Do not copy the full OpenDataLoader corpus into the SDK repository. Put a
manifest and benchmark code in version control, then place an external corpus
under an ignored directory such as `Corpus/`. The manifest records the exact
corpus revision when one exists, plus per-file SHA-256, source, license, and
rights status. A curated set of direct publication URLs has no single
repository revision; its per-file checksums are the pin.

`distribution` describes where the corpus is allowed to live:

- `committed` is for a small, rights-cleared fixture set checked into the
  repository. Every document must have `rights.status` set to `cleared`.
- `external-only` is for a local or CI checkout that must not be committed or
  published by this repository. Every document still needs a source, license,
  and an approved `rights.status` of `external-only` or `cleared`.

The only accepted document rights statuses are `cleared` and `external-only`.
Unknown values fail manifest decoding. A private repository does not remove
the need to review rights for every underlying PDF, image, and excerpt.

## Manifest

The current schema is intentionally small:

```json
{
  "schema_version": 1,
  "corpus": {
    "id": "opendataloader-dp-bench",
    "distribution": "external-only",
    "source_url": "https://github.com/opendataloader-project/opendataloader-bench",
    "revision": "<exact-corpus-commit>"
  },
  "raw_engine_baseline": {
    "engine": "pdf-inspector",
    "revision": "<exact-engine-commit>",
    "markdown_directory": "RawBaseline/markdown"
  },
  "documents": [
    {
      "id": "document-001",
      "pdf": "Corpus/pdfs/document-001.pdf",
      "sha256": "<64-hex-pdf-digest>",
      "raw_markdown_sha256": "<64-hex-baseline-digest>",
      "ground_truth": {
        "markdown": "GroundTruth/document-001.md",
        "sha256": "<64-hex-ground-truth-digest>",
        "minimum_token_f1": 0.95,
        "minimum_structure_f1": 0.9
      },
      "rights": {
        "status": "external-only",
        "license": "review-per-document",
        "source_url": "<document-source-url>",
        "attribution": "<required-attribution>"
      }
    }
  ]
}
```

`raw_engine_baseline` is optional. When present, it must have an exact
40-character engine revision and every document must provide
`raw_markdown_sha256`. The runner compares the SHA-256 of every successful
Markdown extraction with that pinned value. `markdown_directory` is provenance
for the checked-out baseline; the digest in the manifest is the comparison
contract, so baseline Markdown need not be committed.

Paths are relative to the manifest directory unless `--root` is supplied.
Paths may not escape that root. All documents are preflighted before the Rust
engine is called, so a rights or checksum failure cannot produce a partial
benchmark that looks successful.

`ground_truth` is optional per document. When present, its checksum and UTF-8
encoding are verified before any engine call. Token F1 measures content-word
recovery using word multiplicity. Structure F1 compares heading levels, list
items, table rows, blockquotes, code fences, and paragraph lines. These small,
transparent metrics are useful for committed smoke fixtures; they do not claim
to measure visual fidelity or replace a standard full-corpus evaluator.

## Running it

After the root package has a built `Artifacts/DocumentKitCore.xcframework`:

```sh
Benchmarks/Scripts/verify-smoke-fixture.sh
swift run --package-path Benchmarks documentkit-benchmark \
  --manifest Benchmarks/Manifests/smoke-v1.json \
  --root Benchmarks \
  --output Benchmarks/.cache/results/smoke-v1 \
  --repetitions 2
```

The verification script regenerates the 1-page PDF from the tracked Swift
source and checks both fixture digests. This is benchmark tooling only;
DocumentKit does not expose PDF generation.

The tracked curated external manifest can be reproduced without committing
third-party PDFs:

```sh
Benchmarks/Scripts/fetch-curated-external-v1.sh
swift run --package-path Benchmarks documentkit-benchmark \
  --manifest Benchmarks/Manifests/curated-external-v1.json \
  --root Benchmarks/Corpus/curated-v1 \
  --output Benchmarks/.cache/results/curated-v1 \
  --repetitions 2
```

The four inputs cover nested headings/lists, scientific figures/equations,
tagged financial tables, and graphic-heavy card/multi-column layout. The
manifest preserves per-document source, reuse basis, attribution, and digest.
They remain external-only because each publisher warns that government or
openly licensed publications may still contain separately owned elements.

The runner writes:

```text
<output>/summary.json
<output>/documents/<id>/result.json
<output>/documents/<id>/markdown/run-01.md
<output>/documents/<id>/markdown/run-02.md
```

`summary.json` is the machine-readable run report. Per-document records keep
the input digest, inspect and extract attempts, Markdown digests, errors,
repeatability, baseline comparison, ground-truth scores, and elapsed
milliseconds. Processing time reported by the PDF engine is excluded from
parity comparisons; wall timing is reported as benchmark data.

## Test cadence

- **Every PR:** run the small committed, rights-cleared smoke manifest. Require
  checksum verification, successful separate `inspect` and `extract` calls,
  deterministic repeated output, exact raw-engine parity when a baseline is
  pinned, and ground-truth thresholds when provided.
- **Nightly:** fetch the curated external corpus, verify every PDF checksum and
  rights record, and run the pinned parity baseline. Store detailed results as
  CI artifacts, not SDK source.
- **Release:** repeat the nightly benchmark on a recorded machine/toolchain,
  review per-document regressions, and retain the exact manifest, engine commit,
  evaluator commit, and result JSON.

The full quality run should report the evaluator's NID/NID-S, TEDS/TEDS-S, and
MHS/MHS-S metrics with eligible-document counts. Do not turn a missing download
or evaluator failure into a zero score or a green result.

## Current verification status

The committed smoke fixture passes its quality thresholds with token F1 `1.0`
and structure F1 `0.923`. Repeated inspection and Markdown output are stable.
The four-document external run also passes with exact raw-engine Markdown
parity and no nondeterministic documents. Local timing, hashes, and the known
smoke-fixture structure difference are recorded in
[`Reports/v0.1-baseline.json`](Reports/v0.1-baseline.json).
