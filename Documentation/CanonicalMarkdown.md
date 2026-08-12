# Canonical Markdown benchmark specification

This specification defines the reviewed answer key used to measure PDF-to-Markdown
quality. A PDF has no intrinsic Markdown representation, so these rules are part
of the benchmark contract. They are frozen before any candidate extraction is
scored.

## Evidence and independence

- The rendered PDF is the primary source. Embedded text and independent OCR can
  assist transcription but do not override visible content.
- Authors and reviewers must not see DocumentKit output, diffs, scores, prompts,
  or failure reports before the golden revision is locked.
- Preserve source errors and inconsistent arithmetic. This is transcription,
  not correction.
- Never use a real customer statement, even if it appears redacted. Hidden text,
  annotations, metadata, and embedded images can retain personal information.

Each case has a PDF, canonical `.md`, and manifest metadata containing source,
rights, hashes, review state, authoring method, expected page/OCR labels, and
critical values. Benchmark metadata never appears in the Markdown itself.

## File normalization

- UTF-8, Unicode NFC, LF line endings, no tabs or trailing whitespace, and one
  terminal newline.
- One blank line between blocks. Do not hard-wrap prose.
- Preserve visible case, punctuation, signs, currency markers, separators, and
  decimal precision.

## Content and reading order

- Use ATX headings only. Map the highest visible semantic level to H1 and
  preserve relative hierarchy without skipped levels. Do not invent headings.
- Join purely visual line wraps into one paragraph. Use `<br>` only where a line
  break conveys meaning, such as an address.
- Preserve ordered-list numbers and use `-` for unordered lists.
- Read pages in source order. Within a page, place full-width material first,
  then read each column top-to-bottom and columns left-to-right unless numbering,
  connectors, or sentence continuity clearly prove another order.
- Place a sidebar, table note, figure caption, or footnote immediately after its
  semantic anchor.

## Tables and financial values

- Use a GFM pipe table for a simple rectangular table with one logical value per
  cell. Use minimal semantic HTML only when row spans, column spans, or multi-level
  headers cannot be represented faithfully.
- Preserve headers, row/column association, units, currencies, row order,
  subtotal/total meaning, footnotes, signs, parentheses, `CR`/`DR`, displayed
  precision, and thousands separators.
- Distinguish an empty cell, `0`, `-`, `N/A`, and `[[ILLEGIBLE]]`.
- Join a table continued across pages. Remove repeated continuation headers but
  preserve all data rows and meaningful carry-forward values.
- Never calculate a missing value, repair arithmetic, expand a ditto mark, or
  infer an illegible digit from surrounding totals.

Critical values are selected and annotated before DocumentKit is run. Each
locked value includes an exact canonical Markdown context containing that
literal, normally the full table row or labeled line. A value passes only when
both its literal and context occur exactly the expected number of times. This
makes duplicated or relocated amounts fail automatically; the independent
review also checks row, column, currency, and debit/credit semantics.

## Page artifacts, images, and forms

- Omit decorative rules, crop marks, watermarks, navigational page numbers, and
  verbatim repeated running headers/footers.
- Preserve unique disclaimers, payment instructions, carry-forward balances, and
  substantive page-specific notices even when positioned in a footer.
- Do not insert physical page-break markers. Join semantic content that continues
  across pages; store page provenance in benchmark metadata.
- Repair layout-induced line-end hyphenation only when the join is unambiguous.
  Preserve lexical hyphens and negative signs.
- Omit decorative images. Represent meaningful non-text images as
  `![Objective description](asset://figure-NNN)` and keep a source caption adjacent.
  Transcribe only chart labels and values that are explicitly visible.
- Represent fields as `**Label:** value`; use `[[BLANK_FIELD]]` for a visible
  empty field. Checkboxes use `- [x]`, `- [ ]`, `- [indeterminate]`, or
  `- [unknown]`.
- Use `[[REDACTED]]`, `[[ILLEGIBLE]]`, or `[[UNAVAILABLE: type]]` at the visible
  reading-order position. Never reconstruct redacted or unreadable content.

## Review states

- `draft`: editable author work; excluded from quality aggregates and gates.
- `reviewed`: independently checked page-by-page; useful for development metrics
  but not a release gate.
- `locked`: immutable, adjudicated, zero unresolved critical discrepancies, and
  pinned by source and Markdown hashes. Only locked truth gates a release.

The reviewer independently records the heading outline and all critical values
before seeing the author's Markdown. Every page, table, field, image, and omitted
artifact is checked against a rendered page. Critical or ambiguous disagreements
require a separate adjudicator. Any edit creates a new draft; a locked correction
requires a version bump and complete re-review.

## Corpus and scoring policy

- Split by issuer/template family, language, native-text/scanned mode, and layout
  difficulty. Never split near-duplicate monthly statements across development
  and holdout sets.
- Looking at document-level holdout gold or output moves that case to development.
- Exact Markdown equality is diagnostic. Report content, local word order,
  structure, tables, critical values, OCR routing, determinism, failures, and
  speed separately with eligible-document counts.
- A release has zero hallucinated, substituted, sign-flipped, currency-mismatched,
  duplicated, or misassociated release-blocking critical values.
- Performance is reported only for correct, deterministic, successful documents.
  Quality is always the first gate.
