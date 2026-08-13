# DocumentKit benchmark runner

This is a small, local-only SwiftPM executable for benchmarking the
DocumentKit wrapper. It does not download a corpus and it never treats a
missing, unreviewed, or checksum-mismatched PDF as a valid run.

The runner deliberately has three measurement layers:

1. **Upstream parity:** compare the Swift wrapper with a pinned raw
   `pdf-inspector` baseline. This is the first release gate. Exact Markdown
   SHA-256 is the raw-engine comparison; wrapper inspection snapshots are
   checked for repeatability separately.
2. **Human ground truth:** compare extracted Markdown with independently authored
   UTF-8 Markdown under
   [`Documentation/CanonicalMarkdown.md`](../Documentation/CanonicalMarkdown.md).
   The runner reports content, adjacent-word order, Markdown structure, table
   cells, exact critical values, and OCR routing. Draft and reviewed truth are
   diagnostic; only locked truth gates a release.
3. **Native baseline:** compare the same truth with PDFKit embedded-text output.
   This is intentionally plain text and non-OCR. Its quality score is
   non-gating, while successful deterministic execution is required so a
   comparative run cannot silently omit the native baseline.

Each measured repetition also runs inspection two ways: the unchanged SDK
default, which uses the pinned engine's up-to-eight-page sample, and an explicit
zero-based selection of every page. The explicit selection is derived from the
first successful default inspection's `pageCount`; the discovery call is not a
timing sample. Per-run JSON records the strategy, requested indexes, known page
count and its source, semantic coverage, elapsed time, inspection snapshot, and
error. PDFKit's page count remains part of the independent native baseline, and
the result reports whether it matches DocumentKit's count.

Sampled and explicit-full repeatability both gate a passing document. Their
stable snapshots are also compared field by field, but sampled-versus-full
equality is diagnostic rather than a gate. OCR-routing quality continues to use
the inspection returned by Markdown extraction, not either standalone inspect
strategy.

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

## External corpus acquisition (v0.2)

The v0.2 acquisition manifest pins 24 public, official sample PDFs without
committing their bytes. Five are fictional or official bank-statement
examples; none contains customer data. The set has 128 pages in total and no
document exceeds 17 pages.

On macOS with `curl`, `jq`, `shasum`, and the Swift toolchain installed, fetch
or revalidate the ignored corpus with:

```sh
Benchmarks/Scripts/fetch-curated-external-v2.sh
```

The script fails closed if the schema, URL after redirects, byte count,
SHA-256, Git-ignore boundary, PDF header, PDFKit readability, lock state, or
page count differs from the manifest. Public availability is not treated as a
redistribution license: every document remains `external-only`, records a
rights-evidence URL and conservative hypothesis, and is explicitly marked as
not having received legal review.

This is acquisition metadata only. It contains no DocumentKit output, raw
engine baseline, or authored golden Markdown. Ground truth must be created and
reviewed separately before this corpus can be used for quality scoring.

## Benchmark runner manifest

Schema v1 remains readable. New corpora should use schema v2:

```json
{
  "schema_version": 2,
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
      "document_type": "bank_statement",
      "origin": "official_sample",
      "features": ["tables", "critical-values"],
      "expected_page_count": 1,
      "expected_ocr_pages": [],
      "raw_markdown_sha256": "<64-hex-baseline-digest>",
      "ground_truth": {
        "markdown": "GroundTruth/document-001.md",
        "sha256": "<64-hex-ground-truth-digest>",
        "state": "locked",
        "authoring_method": "visual-transcription",
        "authored_without_documentkit_output": true,
        "author": "<golden author>",
        "reviewer": "<independent reviewer>",
        "reviewed_at": "2026-08-12",
        "critical_values": [
          {
            "id": "closing-balance",
            "kind": "amount",
            "value": "$1,234.56",
            "context": "| Closing balance | $1,234.56 |",
            "occurrences": 1
          }
        ],
        "minimum_token_f1": 0.95,
        "minimum_structure_f1": 0.9,
        "minimum_word_order_f1": 0.95,
        "minimum_table_cell_f1": 0.95,
        "minimum_critical_value_accuracy": 1.0,
        "minimum_ocr_routing_f1": 1.0
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

`raw_engine_baseline` is optional for diagnostic runs and required by
`--require-release`. When present, it must have an exact
40-character engine revision and every document must provide
`raw_markdown_sha256`. The runner compares the SHA-256 of every successful
Markdown extraction with that pinned value. `markdown_directory` is provenance
for the checked-out baseline; the digest in the manifest is the comparison
contract, so baseline Markdown need not be committed.

Paths are relative to the manifest directory unless `--root` is supplied.
Paths may not escape that root. All documents are preflighted before the Rust
engine is called, so a rights or checksum failure cannot produce a partial
benchmark that looks successful.

`ground_truth` is optional per document. Its checksum and UTF-8 encoding are
verified before any engine call. Schema v2 requires a `draft`, `reviewed`, or
`locked` state, authoring method, and declaration that the author did not consult
DocumentKit output. Locked truth additionally requires distinct author and
reviewer identities plus an ISO review date. Locked critical values require a
1.0 threshold and exact canonical context containing the literal; missing,
duplicated, or relocated occurrences fail. The declared literal and context
counts are also checked against the golden itself before the engine runs. OCR indexes are zero-based,
ascending, unique, and range-checked.

The built-in table metric recognizes simple GFM pipe tables and reports
normalized-cell F1. It does not claim visual table-tree fidelity or reliably
score complex row/column spans.

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

For release performance evidence, require an optimized build, discard at least
one warm-up, and keep enough samples for tail percentiles:

```sh
DOCUMENTKIT_BENCHMARK_SOURCE_REVISION="$(git rev-parse HEAD)" \
  Benchmarks/Scripts/run-release.sh \
  --manifest Benchmarks/Manifests/v0.2-development.json \
  --root Benchmarks \
  --output Benchmarks/.cache/results/release-v0.2 \
  --warmups 1 \
  --repetitions 20
```

The wrapper requires a clean committed checkout whose `HEAD` equals the exact
`DOCUMENTKIT_BENCHMARK_SOURCE_REVISION`. It preserves `/usr/bin/time -l` output
beside the benchmark result and writes `resource-usage.json` with the maximum
resident set size plus hashes of the resource log and `summary.json`. This is
the process-lifetime high-water mark for the corpus run, not a per-document or
per-engine measurement. The output directory must be new or empty, so a failed
rerun cannot leave stale green evidence. Release evidence also requires schema
v2, at least 20 documents, five bank statements, exact pinned raw-engine parity,
locked truth for every case, page/OCR labels, explicit quality floors, table
thresholds where applicable, and exact critical-value gates for every bank
statement. Use a direct release-mode invocation for diagnostic draft corpora
such as the smoke fixture. The v0.2 manifest path above becomes valid only after
the external corpus and every locked truth file have been prepared.

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

`summary.json` records the manifest hash, build configuration, injected source
revision, OS, architecture, memory, toolchain, engine versions, warm-ups, and
measured repetitions. Sampled and explicit-full inspect timings have separate
aggregates. Per-document records keep
the input digest, inspect and extract attempts, Markdown digests, errors,
repeatability, baseline comparison, ground-truth scores, and elapsed
milliseconds. It reports expected, scored, unscored, threshold-failed, and total
failed locked-truth counts separately, so engine failures and quality failures
cannot disappear from the denominator. Failed-run timings remain diagnostic.

Inspection coverage is semantic, not a proportional-speed promise. The pinned
detector's undecodable-font checks can still examine all pages, so even the
default sampled strategy may retain O(total pages) work. Interpret the separate
timings as observed end-to-end costs for each strategy, not as evidence that
sampling bounds total work. Sampled inspection currently runs before explicit
full inspection in each repetition, so their timing comparison also contains
fixed-order and cache bias.

DocumentKit currently runs before PDFKit, so cross-engine timings contain
cache/order bias. Treat them as separate baselines, not a definitive speed
ranking, until isolated randomized subprocess runs are added. Apple Vision is
not part of this non-OCR baseline; when added, its timing must include PDF page
rendering.

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

Do not turn a missing download, unreviewed golden, or evaluator failure into a
zero score or a green result. The 21 researched entries in
[`CorpusSources/v0.2-candidates.json`](CorpusSources/v0.2-candidates.json),
including six fictional or blank sample statements, are candidates only. Each
still requires retrieval, SHA-256/size/page pinning, privacy and rights review,
independent canonical Markdown, and an explicit review state. With the four
existing external documents this is a 25-document sourcing plan, not a claim
that 25 documents have been benchmarked.

## Current verification status

The committed smoke fixture has source-authored draft truth. It produces useful
diagnostic scores but is not a locked release-quality case. Repeated inspection
and Markdown output are stable.
The four-document external run also passes with exact raw-engine Markdown
parity and no nondeterministic documents. Local timing, hashes, and the known
smoke-fixture structure difference are recorded in
[`Reports/v0.1-baseline.json`](Reports/v0.1-baseline.json).
