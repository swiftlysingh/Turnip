# AMEX transaction-integrity benchmark

This macOS-only Swift package compares two local extraction paths for one
financial-import question:

1. `DocumentKit.extract(data).markdown` followed by the frozen AMEX adapter.
2. `PDFDocument(data: data)?.string` followed by the same AMEX adapter.

It is deliberately small. There is no raw `pdf-inspector` candidate, external
corpus acquisition, OCR, LLM, generic Markdown parity score, or release
benchmark in this package.

## What is measured

The adapter receives only each candidate's raw string. It does not receive PDF
bytes, page-level PDFKit text or layout, manifest data, truth, or expected
values. Raw extraction timing begins with in-memory PDF data and ends at the
raw string. File I/O, truth loading, adaptation, scoring, and report encoding
are excluded.

The default run performs one warmup and five measured repetitions. Candidate
order alternates by case and repetition. Raw strings and full ordered adapter
results must be exactly deterministic. A failed raw extraction or raw-output
nondeterminism makes that case timing-ineligible; the report keeps every
successful/failed raw attempt count rather than silently forming a smaller
nominal sample. Adapter failures and semantic nondeterminism still fail quality,
but do not erase an otherwise eligible raw-extraction timing measurement.

Quality is separate from time. The detailed report labels timing as **Raw
extraction median**. It records eligible, scored, failed, and total case counts,
per-case metrics/timings, and stable failure codes. The shareable JSON and text
contain warmup/repetition counts, corpus counts, aggregate metrics, timings,
and failure counts only.
Candidate misses do not change the command exit status. Invalid invocation,
manifest/truth/review/input/privacy validation, report writing, and internal
runner failures exit nonzero.

The exact truth, normalization, duplicate handling, critical-value ownership,
period clustering, and adoption gate are defined in
[BenchmarkTruth.md](../Documentation/BenchmarkTruth.md).

## Private local workflow

Keep real PDFs, truth, equivalence reviews, manifests, and reports under
`Benchmarks/Private/`. Legacy local corpus, truth, baseline, results, cache,
and v0.2-development-manifest paths remain ignored for existing local work.
Never commit a statement, raw extraction, report with values, source URL, or
machine path.

The command accepts explicit paths so a local harness may live elsewhere, but
the private convention is intentionally simple:

```sh
swift run -c release --package-path Benchmarks documentkit-benchmark \
  --manifest Benchmarks/Private/manifest.json \
  --root Benchmarks/Private \
  --output Benchmarks/Private/results \
  --warmups 1 \
  --repetitions 5
```

The manifest pins every PDF/truth byte hash, byte count, page count, the
DocumentKit engine revision, and the AMEX adapter revision/checksum. Truth also
pins a deterministic canonical Markdown projection. A shared truth for a
`standard`/`screen-reader` pair additionally needs one checksum-pinned review
record that binds the truth/canonical hashes, statement currency, exact source
variant set, both PDF hashes/page counts, exact source-only author/reviewer
prompts and participants, and completed rendered-page adjudication.

Output is intentionally redacted. It never contains raw text, truth values,
merchant names, account/card information, dates, paths, file names, URLs,
localized errors, document/truth/review hashes, or host/user data. It does
include safe reproducibility metadata: OS, architecture, non-host hardware
model, Swift version, build configuration, sanitized source revision, engine
revision, the source revision's `verified`/`asserted`/`working_tree` evidence
state, adapter checksum, and aggregate input page/byte counts. The package uses
a redacted DTO allowlist and privacy sentinel check before reports are written.

Supply a full 40- or 64-character lowercase hexadecimal code revision when
publishing evidence, either with `--source-revision <sha>` or
`DOCUMENTKIT_BENCHMARK_SOURCE_REVISION`. The report marks a supplied revision
`verified` only when it exactly equals the invocation directory's clean Git
`HEAD`; otherwise it is explicitly `asserted`. If neither is available, reports
say `working-tree`; that is useful locally but not publishable exact evidence.

## Committed synthetic smoke fixture

The repository contains two wholly invented AMEX-shaped PDFs with one shared,
reviewed structured truth record and its deterministic canonical Markdown
projection. The screen-reader-shaped variant is an invented representation with
a wrapped merchant and summaries after the table; it is not claimed to be a
genuine accessibility export. The pair is synthetic coverage, not a claim
about real statements or a product-quality finding.

Verify that the tracked host-independent fixed PDF serializer reproduces the
tracked PDFs without rewriting them:

```sh
Benchmarks/Scripts/verify-smoke-fixture.sh
```

Run the synthetic pair:

```sh
swift run -c release --package-path Benchmarks documentkit-benchmark \
  --manifest Benchmarks/Manifests/smoke-v1.json \
  --root Benchmarks \
  --output /tmp/documentkit-benchmark-smoke \
  --warmups 1 \
  --repetitions 5
```

The smoke run exercises both candidate pipelines and the report boundary using
invented data. It does not establish real-statement quality, a broader accuracy
finding, or a release result.

For real evidence, one unseen period plus its paired variants is the minimum
useful holdout. At least three separate unseen periods are needed before a
broader public accuracy claim. A paired variant measures representation
robustness rather than independent statement diversity. Inspecting a period's
candidate output, diff, or score makes it development data. Private statements
must not be uploaded to a cloud model without explicit source-specific approval.
