# AMEX transaction-integrity truth contract

`amex-retrobudget-v1` is a small macOS benchmark for one product question:
whether a local PDF extraction surface can be converted into the financial
fields RetroBudget imports. It is not a generic PDF leaderboard, OCR
evaluation, raw-engine parity test, or release certification.

## Candidate boundary

Each candidate gives the same frozen AMEX adapter exactly one raw `String`:

1. `try await Turnip.extract(data).markdown`
2. `PDFDocument(data: data)?.string`

The adapter receives no truth, manifest, PDF bytes, document, page/layout
objects, expected values, closures capturing expected values, or
candidate-specific rules. PDFKit construction is part of its timed raw
extraction surface.

The adapter covers these preregistered fields: new balance, minimum payment,
payment due date, credit limit, payments/credits, fees, and interest. Its
manifest checksum binds its revision, declared canonicalization contract,
critical-field rules, and a pinned normalized source aggregate for the adapter
and exact financial scorer. The benchmark test fails if either source changes
without repinning that digest and the manifest.

## Locked truth and review

Every case has checksum-pinned structured truth. It records a statement ID,
statement period and currency, transaction rows (`date`, `merchant`, signed
minor-unit amount, zero-based `page_index`), and visible preregistered critical
values. Truth is invalid when critical IDs are duplicated, a transaction page
index is outside the source PDF, currency/period guards fail, or a field has
the wrong kind, sign, currency, or precision.

Truth also references a checksum-pinned canonical Markdown file. This is a
human-reviewable, reviewed deterministic projection of structured truth, not
an independently authored candidate or Turnip output. The runner renders
the same fixed Markdown table/field format and requires exact UTF-8 equality,
so every transaction and critical association is present before execution.

Every truth group requires one checksum-pinned review record. A truth group is
keyed by statement ID, statement period, and truth hash, not by the truth file
path, so byte-identical truth at another path cannot bypass shared-truth
review. The record binds the truth and canonical-Markdown hashes, statement
currency, exact source-variant set, and each source PDF's hash and page count.
It also retains exact hashed author and reviewer prompts, participant kind,
model and reasoning effort, and attests that the author/reviewer differ,
worked independently from rendered sources only, inspected every page, did not
consult candidate output, and left no transaction or critical discrepancy.

Every completed review requires a checksum-pinned adjudication by a participant
distinct from the author and reviewer. The adjudicator resolves the two
independent reconstructions against the rendered pages, frozen conventions,
and final structured/Markdown projection. The record identifies the participant
and exact prompt, records zero unresolved discrepancies, and never consults
candidate output. It is not represented as a source-only pass. Historical
authorship is provenance only: a retained historical model record must say its
exact prompt was not retained; it never replaces the independent review.

The committed fixture is wholly invented. Its completed review records the
historical `gpt-5.6-terra` author at max effort with no retained exact prompt,
two independent `gpt-5.6-luna` max source-only reconstructions, and a
`gpt-5.6-sol` xhigh rendered-page adjudication. This is provenance for the
invented fixture, not a claim about private statements or product quality.

Private statements are never sent to a cloud model without explicit,
source-specific approval. Model/prompt provenance may be recorded for the
invented committed fixture when a review actually occurs.

## Canonicalization and scoring

Merchant comparison uses Unicode NFC, locale-independent POSIX Unicode case
folding, smart-punctuation normalization, and whitespace collapse. The only
join is an immediately adjacent date-led line wrap whose first line has no
amount and whose continuation supplies one valid amount. There are no aliases,
fuzzy matching, tolerances, arithmetic repair, or truth-derived behavior.
When an extractor supplies the entire statement as one whitespace-separated
surface, the adapter recognizes only explicit statement-field, section, and
transaction-date boundaries before applying that same parser; this is shared
surface-shape handling, not a candidate-specific rule.

Amounts require exactly two decimal places and either ungrouped digits or
standard comma grouping (`\d{1,3}(,\d{3})*`). Invalid grouping, unsupported
precision, plus signs, multiple signs, and malformed/conflicting CR/DR forms
are rejected. Parentheses, leading/trailing minus, CR, and DR preserve
direction. A transaction-like malformed candidate remains a row false positive.
A date-led transaction-shaped line before `Transactions` also counts as a row
false positive, while arbitrary pre-heading amount-like prose remains outside
transaction scoring. Unknown or malformed summary candidates, including
date-valued summaries, are counted as unexpected critical candidates.
Preregistered critical fields may occur before or after the transaction
section; a field label embedded in transaction merchant prose is not a summary.
An explicit `Transaction Summary` heading ends transaction parsing. Any
otherwise-unparsed colon field in that section is unexpected. A date-led or
amount-like non-field line after that heading is a malformed row candidate.
Outside it, the adapter counts an unknown colon field only when its label says
summary or its value is amount/date-shaped. Valid date-led transaction rows
parse before that check.

Transaction years must resolve consistently with the extracted statement
period. Two-digit years are accepted only when one period-consistent year is
unambiguous. Conflicting currency or statement-period metadata is rejected;
identical duplicate metadata is accepted once. Currency and statement period
must exactly match locked truth.

The headline transaction unit is the row multiset:

```text
(date, merchant, signed_amount_minor)
TP = sum(min(expectedCount, observedCount))
FP = validObserved.count - TP + malformedTransactionCandidates
FN = expected.count - TP
F1 = 2TP / (2TP + FP + FN)
```

`page_index` is provenance only; statement currency is an independent exact
guard, not a component of row F1. Valid duplicate rows are preserved. An empty
expected/observed multiset has F1 1 only when there are no malformed candidates;
a one-sided empty multiset has F1 0.

Critical accuracy is `correct expected keys / expected keys`. A correct key
requires an exact ID, kind, value, sign, currency, and multiplicity.
Unexpected keys are reported separately and do not reduce that expected-key
accuracy. A duplicate for an expected ID makes that key incorrect and lowers
accuracy. Both prevent a perfect statement and therefore adoption. When truth
has no criticals, accuracy is 1 only when observed criticals and unexpected
candidates are also empty, otherwise it is 0. Financial table-cell F1 and
content token F1 are diagnostics only; they do not affect perfect, adoption,
or exit.

A case is perfect only when row and critical semantics are exact, statement
currency/period match truth, extraction and adaptation succeed, and raw plus
full ordered semantic results are deterministic. Failures and nondeterminism
remain in every denominator with zero semantic score; a report never serializes
`perfect: true` for such a case.

## Timing, aggregation, and reproducibility

The timer covers raw extraction only, from in-memory PDF data through the raw
string. It excludes warmup reporting, adapter/scoring, truth/file I/O, and
report writing. Candidate order alternates. A failed measured raw extraction or
raw-output nondeterminism makes that case timing-ineligible, but
successful/failed raw attempts remain counted. Adapter failures and semantic
nondeterminism fail the quality result without invalidating an otherwise
eligible raw timing. Aggregate raw time is the median of all eligible measured
raw samples, not a median of case medians.

Reports include a macro average per PDF case and a statement-period-clustered
average. Standard and screen-reader variants are paired robustness evidence and
never independent statement periods. Both detailed and shareable reports use
redacted DTOs. Detailed reports may contain opaque case/period tokens,
per-case counts, metrics, and timings; shareable reports are aggregate-only
apart from the public warmup/repetition methodology counts.

Safe reproducibility metadata is public: OS, architecture, non-host hardware
model, Swift version, debug/release configuration, sanitized Turnip source
revision, `Turnip.engineRevision`, adapter revision/contract checksum, and
input page/byte counts. A source revision may be passed with
`--source-revision` or `TURNIP_BENCHMARK_SOURCE_REVISION`; it must be a
40- or 64-character lowercase hexadecimal revision. The report calls it
`verified` only when it equals the clean Git `HEAD` at invocation; otherwise it
is explicitly `asserted`. `working-tree` means no exact source revision was
provided and is not publishable exact evidence. Reports never include paths,
filenames, URLs, users, hosts, serials, UUIDs, private IDs, source PDF/truth/
review hashes, raw surfaces, canonical models, statement values, or localized
errors. Numeric report fields are protected by the DTO key allowlist rather
than substring scanning raw minor-unit values.

## Evidence limits and holdouts

One previously unseen statement period with its paired standard/screen-reader
variants is the minimum useful holdout. At least three separate unseen periods
are required before making a broader public accuracy claim. Paired variants
test representation robustness, not independent statement diversity. Looking
at a period's candidate output, diff, or score converts that period into
development data; it must not be presented as an unseen holdout afterward.

The committed synthetic pair is implementation coverage only. It can pass its
per-corpus mechanical adoption gate, but that does not establish real-statement
accuracy, a quality finding, or product adoption evidence. Quality/adoption
misses do not change process exit status. Invalid invocation,
manifest/truth/review/input/privacy/report, and internal failures exit nonzero.
