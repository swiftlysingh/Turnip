#!/usr/bin/env python3
"""Assemble the ignored v0.2 development benchmark manifest.

The acquisition manifest, corpus, raw baseline, and locked source-only review
records are separate inputs on purpose. This script only joins inputs that
already agree; it never treats an extractor result as ground truth.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, NoReturn


class AssemblyError(Exception):
    """An input cannot safely participate in the development manifest."""


MISSING = object()
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
REVISION_RE = re.compile(r"^[0-9a-f]{40}$")
# Match the runner's path-safe identifier contract while still rejecting
# whitespace and separators. Acquisition metadata uses both hyphens and
# underscores (for example, `bank_statement`).
IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
HTTPS_RE = re.compile(r"^https://[^/]+")

RELEASE_FLOORS = {
    "minimum_token_f1": 0.90,
    "minimum_structure_f1": 0.80,
    "minimum_word_order_f1": 0.80,
    "minimum_table_cell_f1": 0.80,
    "minimum_ocr_routing_f1": 1.00,
    "minimum_critical_value_accuracy": 1.00,
}


def fail(message: str) -> NoReturn:
    raise AssemblyError(message)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path, label: str) -> dict[str, Any]:
    require(path.is_file() and not path.is_symlink(), f"{label} is missing or is not a regular file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"could not read {label} {path}: {error}")
    require(isinstance(value, dict), f"{label} must be a JSON object: {path}")
    return value


def get_path(value: Any, path: str) -> Any:
    current = value
    for component in path.split("."):
        if not isinstance(current, dict) or component not in current:
            return MISSING
        current = current[component]
    return current


def present_values(value: dict[str, Any], paths: Iterable[str]) -> list[tuple[str, Any]]:
    found: list[tuple[str, Any]] = []
    for path in paths:
        candidate = get_path(value, path)
        if candidate is not MISSING and candidate is not None:
            found.append((path, candidate))
    return found


def normalized_string(value: Any, label: str, *, allow_placeholder: bool = False) -> str:
    require(isinstance(value, str), f"{label} must be a string")
    result = value.strip()
    if allow_placeholder and result.lower() in {"", "null", "none", "n/a"}:
        return ""
    require(bool(result), f"{label} must not be empty")
    return result


def first_string(value: dict[str, Any], paths: Iterable[str], label: str, *, required: bool = True) -> str | None:
    for path in paths:
        candidate = get_path(value, path)
        if candidate is MISSING or candidate is None:
            continue
        result = normalized_string(candidate, f"{label} ({path})", allow_placeholder=True)
        if result:
            return result
    if required:
        fail(f"{label} is required")
    return None


def check_sha256(value: Any, label: str) -> str:
    result = normalized_string(value, label).lower()
    require(bool(SHA256_RE.fullmatch(result)), f"{label} must be a lowercase SHA-256")
    return result


def check_revision(value: Any, label: str) -> str:
    result = normalized_string(value, label).lower()
    require(bool(REVISION_RE.fullmatch(result)), f"{label} must be a lowercase 40-character commit SHA")
    return result


def check_identifier(value: Any, label: str) -> str:
    result = normalized_string(value, label)
    require(bool(IDENTIFIER_RE.fullmatch(result)), f"{label} must be a safe identifier")
    return result


def check_https(value: Any, label: str) -> str:
    result = normalized_string(value, label)
    require(bool(HTTPS_RE.match(result)), f"{label} must be an HTTPS URL")
    return result


def check_nonnegative_int(value: Any, label: str) -> int:
    require(isinstance(value, int) and not isinstance(value, bool) and value >= 0, f"{label} must be a non-negative integer")
    return value


def check_positive_int(value: Any, label: str) -> int:
    result = check_nonnegative_int(value, label)
    require(result > 0, f"{label} must be positive")
    return result


def check_relative_path(value: Any, label: str) -> PurePosixPath:
    raw = normalized_string(value, label)
    require("\\" not in raw and not raw.startswith("/"), f"{label} must be a safe relative path")
    path = PurePosixPath(raw)
    require(
        path.parts and all(part not in {"", ".", ".."} for part in path.parts),
        f"{label} must not contain empty, dot, or parent components",
    )
    require(all(ord(character) >= 32 for character in raw), f"{label} contains a control character")
    return path


def safe_child(root: Path, relative: PurePosixPath, label: str) -> Path:
    root = root.resolve()
    candidate = root.joinpath(*relative.parts)
    current = root
    for component in relative.parts:
        current = current / component
        require(not current.is_symlink(), f"{label} must not traverse a symbolic link: {current}")
    resolved = candidate.resolve(strict=False)
    require(resolved == root or root in resolved.parents, f"{label} escapes its configured root")
    return candidate


def relative_to_benchmark(path: Path, benchmark_root: Path, label: str) -> str:
    try:
        return path.resolve().relative_to(benchmark_root.resolve()).as_posix()
    except ValueError:
        fail(f"{label} must live under benchmark root {benchmark_root}: {path}")


def is_git_ignored(repo_root: Path, path: Path, label: str) -> None:
    try:
        relative = path.resolve(strict=False).relative_to(repo_root.resolve()).as_posix()
    except ValueError:
        fail(f"{label} must live under the repository root: {path}")
    result = subprocess.run(
        ["git", "-C", str(repo_root), "check-ignore", "-q", "--", relative],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    require(result.returncode == 0, f"{label} must be ignored by Git: {relative}")


def pdf_page_count(path: Path) -> int:
    try:
        result = subprocess.run(
            ["pdfinfo", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        fail("pdfinfo is required to validate acquired PDF page counts")
    require(result.returncode == 0, f"pdfinfo could not inspect {path.name}: {result.stderr.strip()}")
    for line in result.stdout.splitlines():
        match = re.fullmatch(r"Pages:\s+(\d+)", line.strip())
        if match:
            return int(match.group(1))
    fail(f"pdfinfo did not report a page count for {path.name}")


def validate_canonical_markdown(data: bytes, document_id: str) -> str:
    try:
        markdown = data.decode("utf-8")
    except UnicodeDecodeError as error:
        fail(f"{document_id} locked Markdown is not UTF-8: {error}")
    lines = markdown.split("\n")
    has_trailing_whitespace = any(line.endswith((" ", "\t")) for line in lines)
    require("\r" not in markdown, f"{document_id} locked Markdown must use LF line endings")
    require("\0" not in markdown and "\t" not in markdown, f"{document_id} locked Markdown contains a forbidden character")
    require(not has_trailing_whitespace, f"{document_id} locked Markdown has trailing whitespace")
    require(markdown.strip(), f"{document_id} locked Markdown is empty")
    require(markdown == unicodedata.normalize("NFC", markdown), f"{document_id} locked Markdown is not NFC-normalized")
    require(markdown.endswith("\n") and not markdown.endswith("\n\n"), f"{document_id} locked Markdown must have one terminal newline")
    return markdown


def check_index_list(value: Any, label: str, page_count: int) -> list[int]:
    require(isinstance(value, list), f"{label} must be a zero-based integer array")
    indexes = [check_nonnegative_int(item, f"{label}[{index}]") for index, item in enumerate(value)]
    require(indexes == sorted(indexes), f"{label} must be ascending")
    require(len(indexes) == len(set(indexes)), f"{label} must not contain duplicates")
    require(all(index < page_count for index in indexes), f"{label} contains an out-of-range page index")
    return indexes


def require_matching_scalars(
    review: dict[str, Any],
    paths: Iterable[str],
    expected: Any,
    label: str,
    validator: callable | None = None,
    *,
    required: bool = False,
) -> None:
    values = present_values(review, paths)
    if required:
        require(values, f"{label} is missing from locked review metadata")
    for path, value in values:
        if validator is not None:
            value = validator(value, f"{label} ({path})")
        require(value == expected, f"{label} mismatch at {path}: expected {expected!r}, found {value!r}")


def state_is_locked(review: dict[str, Any], document_id: str) -> None:
    states = present_values(review, ("state", "review_state"))
    if not states:
        states = present_values(review, ("status",))
    require(states, f"{document_id} review has no lock state")
    for path, value in states:
        require(normalized_string(value, f"{document_id} review {path}").lower() == "locked", f"{document_id} review is not locked")


def review_date(review: dict[str, Any], document_id: str) -> str:
    raw = first_string(review, ("reviewed_at", "review_date", "locked_at", "metadata_snapshot.reviewed_at"), f"{document_id} review date")
    assert raw is not None
    candidate = raw[:10]
    try:
        return dt.date.fromisoformat(candidate).isoformat()
    except ValueError:
        fail(f"{document_id} review date must begin with YYYY-MM-DD: {raw!r}")


def review_identity(review: dict[str, Any], document_id: str, role: str) -> str:
    if role == "author":
        paths = (
            "author_identity",
            "author",
            "identities.author",
            "metadata_snapshot.author_identity",
            "reference_identity",
            "identities.reference",
        )
    else:
        paths = ("reviewer_identity", "reviewer", "identities.reviewer", "metadata_snapshot.reviewer_identity")
    identity = first_string(review, paths, f"{document_id} {role} identity")
    assert identity is not None
    require(identity.casefold() not in {"null", "none"}, f"{document_id} {role} identity must not be a placeholder")
    return identity


def iter_leaf_values(value: Any, prefix: str = "") -> Iterable[tuple[str, Any]]:
    if isinstance(value, dict):
        for key, nested in value.items():
            path = f"{prefix}.{key}" if prefix else str(key)
            yield from iter_leaf_values(nested, path)
    elif isinstance(value, list):
        for index, nested in enumerate(value):
            yield from iter_leaf_values(nested, f"{prefix}[{index}]")
    else:
        yield prefix.lower(), value


def source_only_attestation(review: dict[str, Any], document_id: str) -> bool:
    negative_categories: set[str] = set()
    positive_source_evidence = False
    output_use_errors: list[str] = []
    text_fragments: list[str] = []

    def categories(key: str) -> set[str]:
        found: set[str] = set()
        if "documentkit" in key:
            found.add("documentkit")
        if "pdf_inspector" in key or "pdf-inspector" in key or "engine" in key:
            found.add("engine")
        if "raw" in key:
            found.add("raw")
        if "benchmark" in key or "score" in key or "diff" in key:
            found.add("benchmark")
        return found

    for path, value in iter_leaf_values(review):
        key = path.lower()
        if isinstance(value, str):
            text_fragments.append(value.lower())
        if not isinstance(value, bool):
            continue
        if any(token in key for token in ("source_only", "source_render", "rendered_source", "all_pages_rendered", "source_pages_visually")) and value:
            positive_source_evidence = True
        covered = categories(key)
        if not covered:
            continue
        if "without" in key or key.startswith("no_") or ".no_" in key:
            if value:
                negative_categories.update(covered)
            else:
                output_use_errors.append(path)
        elif value:
            output_use_errors.append(path)
        else:
            negative_categories.update(covered)

    joined_text = "\n".join(text_fragments)
    source_words = ("rendered source", "source pdf", "source-only", "source only", "page-by-page visual")
    positive_source_evidence = positive_source_evidence or any(word in joined_text for word in source_words)
    no_output_words = (
        "no documentkit output",
        "did not inspect documentkit",
        "without documentkit output",
        "no documentkit,",
    )
    if any(word in joined_text for word in no_output_words):
        negative_categories.add("documentkit")
    if any(word in joined_text for word in ("no engine output", "raw extraction output", "pdf-inspector output", "raw baseline")):
        negative_categories.add("engine")
        negative_categories.add("raw")
    if any(word in joined_text for word in ("no benchmark", "benchmark output", "benchmark result")) and any(
        word in joined_text for word in ("no benchmark", "did not inspect", "not consulted", "no documentkit")
    ):
        negative_categories.add("benchmark")

    require(not output_use_errors, f"{document_id} review indicates extractor or benchmark output was consulted: {', '.join(output_use_errors)}")
    require(positive_source_evidence, f"{document_id} review lacks source-only visual/source evidence")
    require(
        {"documentkit", "engine", "raw"}.intersection(negative_categories),
        f"{document_id} review lacks a no-DocumentKit/no-engine attestation",
    )

    explicit_author_without_output = present_values(
        review,
        (
            "authored_without_documentkit_output",
            "attestations.author_authored_without_documentkit_output",
            "metadata_snapshot.authored_without_documentkit_output",
        ),
    )
    for path, value in explicit_author_without_output:
        require(value is True, f"{document_id} {path} must be true")
    return bool(explicit_author_without_output) or bool({"documentkit", "engine", "raw"}.intersection(negative_categories))


def authoring_method(review: dict[str, Any], document_id: str, source_only: bool) -> str:
    method = first_string(
        review,
        ("authoring_method", "metadata_snapshot.authoring_method"),
        f"{document_id} authoring method",
        required=False,
    )
    if method is None:
        require(source_only, f"{document_id} cannot infer authoring method without source-only attestation")
        return "visual-transcription"
    require(method in {"source-authored", "visual-transcription"}, f"{document_id} authoring method is unsupported: {method!r}")
    return method


def unresolved_critical_discrepancies_are_zero(review: dict[str, Any], document_id: str) -> None:
    paths = (
        "unresolved_critical_discrepancies",
        "unresolved",
        "critical_discrepancies",
        "page_review.critical_discrepancies",
        "page_review.unresolved_issues",
        "attestation.unresolved_critical_discrepancies",
        "attestations.unresolved_critical_discrepancies",
        "review.zero_unresolved_critical_discrepancies",
        "metadata_snapshot.attestations.unresolved_critical_discrepancies",
    )
    values = present_values(review, paths)
    require(values, f"{document_id} review lacks an explicit unresolved-critical-discrepancy result")
    for path, value in values:
        if isinstance(value, bool):
            require(value is True and "zero_" in path, f"{document_id} {path} must affirm zero unresolved critical discrepancies")
        elif isinstance(value, int) and not isinstance(value, bool):
            require(value == 0, f"{document_id} {path} must be zero")
        elif isinstance(value, list):
            require(not value, f"{document_id} {path} must be empty")
        elif isinstance(value, str):
            require("zero unresolved critical" in value.lower(), f"{document_id} {path} must explicitly state zero unresolved critical discrepancies")
        else:
            fail(f"{document_id} {path} has an unsupported discrepancy result")


def checked_pages(review: dict[str, Any], document_id: str, page_count: int) -> None:
    paths = (
        "pages_checked_zero_based",
        "pages_checked",
        "source.pages_checked_zero_based",
        "pages.zero_based_checked",
        "pages.checked_zero_based",
        "metadata_snapshot.pages_checked_zero_based",
    )
    values = present_values(review, paths)
    require(values, f"{document_id} review does not record zero-based pages checked")
    expected = list(range(page_count))
    for path, value in values:
        indexes = check_index_list(value, f"{document_id} {path}", page_count)
        require(indexes == expected, f"{document_id} {path} must cover every source page exactly once")


def expected_ocr_pages(review: dict[str, Any], document_id: str, page_count: int) -> list[int]:
    numbering_paths = (
        "expected_ocr_page_numbering",
        "pages.ocr_page_numbering",
        "source.expected_ocr_page_numbering",
        "metadata_snapshot.source.expected_ocr_page_numbering",
    )
    for path, value in present_values(review, numbering_paths):
        require(normalized_string(value, f"{document_id} {path}").lower() == "zero-based", f"{document_id} {path} must be zero-based")

    inherent_zero_based = (
        "expected_ocr_pages_zero_based",
        "expected_ocr_page_indexes",
        "source.expected_ocr_pages_zero_based",
        "pages.expected_ocr_page_indexes",
        "metadata_snapshot.source.expected_ocr_pages_zero_based",
    )
    values = present_values(review, inherent_zero_based)
    generic_values = present_values(review, ("pages.expected_ocr_pages", "expected_ocr_pages"))
    if generic_values:
        require(
            bool(present_values(review, numbering_paths)),
            f"{document_id} generic OCR page labels need an explicit zero-based declaration",
        )
        values.extend(generic_values)
    require(values, f"{document_id} review has no expected OCR-page labels")

    normalized = [check_index_list(value, f"{document_id} {path}", page_count) for path, value in values]
    first = normalized[0]
    for other in normalized[1:]:
        require(other == first, f"{document_id} review has conflicting expected OCR-page labels")
    return first


def page_count_from_review(review: dict[str, Any], document_id: str, expected: int) -> None:
    require_matching_scalars(
        review,
        (
            "source_page_count",
            "source_pages",
            "expected_page_count",
            "page_count",
            "source.page_count",
            "pages.count",
            "pages.expected_page_count",
            "metadata_snapshot.source.page_count",
        ),
        expected,
        f"{document_id} source page count",
        check_positive_int,
        required=False,
    )


def source_metadata_matches(review: dict[str, Any], document: dict[str, Any]) -> None:
    document_id = document["id"]
    expected_hash = document["sha256"]
    require_matching_scalars(
        review,
        (
            "source_sha256",
            "source_pdf_sha256",
            "source.sha256",
            "hashes.source_pdf.sha256",
            "metadata_snapshot.source.sha256",
        ),
        expected_hash,
        f"{document_id} reviewed source SHA-256",
        check_sha256,
        required=True,
    )
    require_matching_scalars(
        review,
        (
            "source_bytes",
            "source.bytes",
            "hashes.source_pdf.bytes",
            "metadata_snapshot.source.bytes",
        ),
        document["bytes"],
        f"{document_id} reviewed source byte count",
        check_positive_int,
        required=False,
    )
    page_count_from_review(review, document_id, document["pages"])

    source_paths = present_values(
        review,
        (
            "source_pdf",
            "source.pdf",
            "hashes.source_pdf.path",
            "metadata_snapshot.source.path",
            "review_scope.source_pdf",
        ),
    )
    for path, source_path in source_paths:
        source_path = normalized_string(source_path, f"{document_id} {path}")
        normalized = source_path.replace("\\", "/")
        require(
            normalized == document["pdf"] or normalized.endswith("/" + document["pdf"]),
            f"{document_id} {path} does not refer to acquisition PDF {document['pdf']}",
        )


def review_markdown_hash(review: dict[str, Any], document_id: str, actual_hash: str) -> None:
    require_matching_scalars(
        review,
        (
            "markdown_sha256",
            "locked_markdown_sha256",
            "golden_sha256",
            "markdown.sha256",
            "hashes.canonical_markdown.sha256",
            "metadata_snapshot.markdown.sha256",
        ),
        actual_hash,
        f"{document_id} locked Markdown SHA-256",
        check_sha256,
        required=True,
    )


def numeric_threshold(review: dict[str, Any], name: str, floor: float) -> float:
    values = present_values(review, (name, f"thresholds.{name}", f"metadata_snapshot.thresholds.{name}"))
    normalized: list[float] = []
    for path, value in values:
        require(isinstance(value, (int, float)) and not isinstance(value, bool), f"{name} ({path}) must be numeric")
        number = float(value)
        require(math.isfinite(number) and 0 <= number <= 1, f"{name} ({path}) must be between zero and one")
        normalized.append(number)
    return max([floor, *normalized])


def critical_values(review: dict[str, Any], document_id: str, markdown: str) -> list[dict[str, Any]]:
    candidates = present_values(
        review,
        ("critical_values", "critical_numerical_values", "metadata_snapshot.critical_values"),
    )
    if not candidates:
        return []
    _, source = candidates[0]
    require(isinstance(source, list), f"{document_id} critical values must be an array")
    output: list[dict[str, Any]] = []
    ids: set[str] = set()
    for index, entry in enumerate(source, start=1):
        require(isinstance(entry, dict), f"{document_id} critical value {index} must be an object")
        entry_id = entry.get("id")
        if entry_id is None:
            identifier = f"critical-{index:03d}"
        else:
            identifier = check_identifier(entry_id, f"{document_id} critical value {index} id")
        require(identifier not in ids, f"{document_id} has duplicate critical value id {identifier!r}")
        ids.add(identifier)

        raw_values = [entry[key] for key in ("value", "literal") if key in entry and entry[key] is not None]
        require(raw_values, f"{document_id} critical value {identifier} needs value or literal")
        literal = normalized_string(raw_values[0], f"{document_id} critical value {identifier} literal")
        for candidate in raw_values[1:]:
            require(normalized_string(candidate, f"{document_id} critical value {identifier} literal") == literal, f"{document_id} critical value {identifier} has conflicting value/literal fields")
        context = normalized_string(entry.get("context"), f"{document_id} critical value {identifier} context")
        require(literal in context, f"{document_id} critical value {identifier} context must contain its literal")

        occurrence_values = [entry[key] for key in ("occurrences", "expected_occurrences") if key in entry and entry[key] is not None]
        require(occurrence_values, f"{document_id} critical value {identifier} needs occurrences")
        occurrences = check_positive_int(occurrence_values[0], f"{document_id} critical value {identifier} occurrences")
        for candidate in occurrence_values[1:]:
            require(check_positive_int(candidate, f"{document_id} critical value {identifier} occurrences") == occurrences, f"{document_id} critical value {identifier} has conflicting occurrence fields")
        if "observed_occurrences" in entry and entry["observed_occurrences"] is not None:
            require(check_positive_int(entry["observed_occurrences"], f"{document_id} critical value {identifier} observed occurrences") == occurrences, f"{document_id} critical value {identifier} review did not observe the declared occurrence count")
        if "status" in entry and entry["status"] is not None:
            status = normalized_string(entry["status"], f"{document_id} critical value {identifier} status").lower()
            require(status in {"pass", "resolved", "locked", "approved"}, f"{document_id} critical value {identifier} is not resolved")

        require(markdown.count(literal) == occurrences, f"{document_id} critical value {identifier} literal occurrence count does not match locked Markdown")
        require(markdown.count(context) == occurrences, f"{document_id} critical value {identifier} context occurrence count does not match locked Markdown")

        normalized: dict[str, Any] = {
            "id": identifier,
            "value": literal,
            "context": context,
            "occurrences": occurrences,
        }
        kind = entry.get("kind")
        if kind is not None:
            normalized["kind"] = normalized_string(kind, f"{document_id} critical value {identifier} kind")
        output.append(normalized)
    return output


def normalized_ground_truth(
    review: dict[str, Any],
    document: dict[str, Any],
    markdown: str,
    markdown_hash: str,
    markdown_path: str,
) -> tuple[dict[str, Any], list[int]]:
    document_id = document["id"]
    state_is_locked(review, document_id)
    source_metadata_matches(review, document)
    checked_pages(review, document_id, document["pages"])
    ocr_pages = expected_ocr_pages(review, document_id, document["pages"])
    review_markdown_hash(review, document_id, markdown_hash)
    source_only = source_only_attestation(review, document_id)
    unresolved_critical_discrepancies_are_zero(review, document_id)
    author = review_identity(review, document_id, "author")
    reviewer = review_identity(review, document_id, "reviewer")
    require(author.casefold() != reviewer.casefold(), f"{document_id} author and reviewer must be distinct")
    values = critical_values(review, document_id, markdown)

    ground_truth: dict[str, Any] = {
        "markdown": markdown_path,
        "sha256": markdown_hash,
        "state": "locked",
        "authoring_method": authoring_method(review, document_id, source_only),
        "authored_without_documentkit_output": True,
        "author": author,
        "reviewer": reviewer,
        "reviewed_at": review_date(review, document_id),
        "minimum_token_f1": numeric_threshold(review, "minimum_token_f1", RELEASE_FLOORS["minimum_token_f1"]),
        "minimum_structure_f1": numeric_threshold(review, "minimum_structure_f1", RELEASE_FLOORS["minimum_structure_f1"]),
        "minimum_word_order_f1": numeric_threshold(review, "minimum_word_order_f1", RELEASE_FLOORS["minimum_word_order_f1"]),
        "minimum_ocr_routing_f1": RELEASE_FLOORS["minimum_ocr_routing_f1"],
    }
    if "tables" in document["features"]:
        ground_truth["minimum_table_cell_f1"] = numeric_threshold(
            review,
            "minimum_table_cell_f1",
            RELEASE_FLOORS["minimum_table_cell_f1"],
        )
    if values:
        ground_truth["critical_values"] = values
        ground_truth["minimum_critical_value_accuracy"] = RELEASE_FLOORS["minimum_critical_value_accuracy"]
    return ground_truth, ocr_pages


def validated_acquisition(manifest: dict[str, Any], corpus_root: Path) -> list[dict[str, Any]]:
    require(manifest.get("schema_version") == 2, "acquisition manifest must be schema_version 2")
    corpus = manifest.get("corpus")
    require(isinstance(corpus, dict), "acquisition manifest corpus must be an object")
    require(corpus.get("distribution") == "external-only", "acquisition corpus must remain external-only")
    require(corpus.get("ground_truth", {}).get("status") == "not-authored", "acquisition manifest must not contain authored ground truth")
    minimum_documents = check_positive_int(corpus.get("minimum_documents"), "acquisition corpus minimum_documents")
    minimum_statements = check_positive_int(corpus.get("minimum_bank_statements"), "acquisition corpus minimum_bank_statements")
    documents = manifest.get("documents")
    require(isinstance(documents, list) and documents, "acquisition manifest must contain documents")
    require(len(documents) >= minimum_documents, "acquisition manifest has fewer documents than its own minimum")

    output: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    seen_paths: set[str] = set()
    for raw_document in documents:
        require(isinstance(raw_document, dict), "acquisition document must be an object")
        document_id = check_identifier(raw_document.get("id"), "acquisition document id")
        require(document_id not in seen_ids, f"duplicate acquisition document id {document_id!r}")
        seen_ids.add(document_id)
        pdf = check_relative_path(raw_document.get("pdf"), f"{document_id} PDF path")
        require(pdf.suffix.lower() == ".pdf", f"{document_id} PDF path must end in .pdf")
        pdf_string = pdf.as_posix()
        require(pdf_string not in seen_paths, f"duplicate acquisition PDF path {pdf_string!r}")
        seen_paths.add(pdf_string)
        expected_hash = check_sha256(raw_document.get("sha256"), f"{document_id} PDF SHA-256")
        expected_bytes = check_positive_int(raw_document.get("bytes"), f"{document_id} PDF byte count")
        expected_pages = check_positive_int(raw_document.get("pages"), f"{document_id} PDF page count")
        document_type = check_identifier(raw_document.get("document_type"), f"{document_id} document type")
        origin = check_identifier(raw_document.get("origin"), f"{document_id} origin")
        features = raw_document.get("features")
        require(isinstance(features, list) and features, f"{document_id} needs at least one extraction feature")
        features = [check_identifier(feature, f"{document_id} feature") for feature in features]
        require(len(features) == len(set(features)), f"{document_id} has duplicate features")
        source = raw_document.get("source")
        rights = raw_document.get("rights")
        require(isinstance(source, dict) and isinstance(rights, dict), f"{document_id} source and rights must be objects")
        publisher_url = check_https(source.get("publisher_page_url"), f"{document_id} publisher page URL")
        check_https(source.get("request_url"), f"{document_id} request URL")
        check_https(source.get("final_url"), f"{document_id} final URL")
        require(rights.get("status") == "external-only", f"{document_id} rights status must remain external-only")
        rights_hypothesis = normalized_string(rights.get("hypothesis"), f"{document_id} rights hypothesis")
        title = normalized_string(raw_document.get("title"), f"{document_id} title")
        publisher = normalized_string(raw_document.get("publisher"), f"{document_id} publisher")

        source_file = safe_child(corpus_root, pdf, f"{document_id} source PDF")
        require(source_file.is_file() and not source_file.is_symlink(), f"{document_id} source PDF is missing or not regular: {source_file}")
        data_prefix = source_file.read_bytes()[:5]
        require(data_prefix == b"%PDF-", f"{document_id} source PDF is missing a PDF header")
        actual_bytes = source_file.stat().st_size
        require(actual_bytes == expected_bytes, f"{document_id} source PDF bytes mismatch: expected {expected_bytes}, found {actual_bytes}")
        actual_hash = sha256_file(source_file)
        require(actual_hash == expected_hash, f"{document_id} source PDF SHA-256 mismatch: expected {expected_hash}, found {actual_hash}")
        actual_pages = pdf_page_count(source_file)
        require(actual_pages == expected_pages, f"{document_id} source PDF pages mismatch: expected {expected_pages}, found {actual_pages}")

        output.append(
            {
                "id": document_id,
                "pdf": pdf_string,
                "sha256": expected_hash,
                "bytes": expected_bytes,
                "pages": expected_pages,
                "document_type": document_type,
                "origin": origin,
                "features": features,
                "title": title,
                "publisher": publisher,
                "publisher_url": publisher_url,
                "rights_hypothesis": rights_hypothesis,
            }
        )

    statement_count = sum(document["document_type"] == "bank_statement" for document in output)
    require(statement_count >= minimum_statements, "acquisition manifest has fewer bank statements than its own minimum")
    return output


def checked_engine_revision(repo_root: Path, raw_index: dict[str, Any]) -> tuple[str, str, str]:
    revision = check_revision(raw_index.get("engine_revision"), "raw baseline engine_revision")
    require(raw_index.get("engine") == "pdf-inspector", "raw baseline must identify pdf-inspector")
    expected_revision = normalized_string((repo_root / "ENGINE_REVISION").read_text(encoding="utf-8"), "ENGINE_REVISION").lower()
    require(revision == expected_revision, f"raw baseline engine revision {revision} differs from ENGINE_REVISION {expected_revision}")
    patch_hash = check_sha256(raw_index.get("apple_cmaps_patch_sha256"), "raw baseline Apple CMaps patch SHA-256")
    actual_patch_hash = sha256_file(repo_root / "Patches" / "pdf-inspector-embed-apple-cmaps.patch")
    require(patch_hash == actual_patch_hash, "raw baseline Apple CMaps patch SHA-256 differs from the checked-in patch")
    binary_hash = check_sha256(raw_index.get("binary_sha256"), "raw baseline binary SHA-256")
    return revision, patch_hash, binary_hash


def raw_records(raw_index: dict[str, Any], documents: list[dict[str, Any]], raw_root: Path) -> dict[str, dict[str, Any]]:
    require(raw_index.get("schema_version") == 1, "raw baseline index must be schema_version 1")
    entries = raw_index.get("documents")
    require(isinstance(entries, list), "raw baseline index documents must be an array")
    acquisition_by_id = {document["id"]: document for document in documents}
    records: dict[str, dict[str, Any]] = {}
    for entry in entries:
        require(isinstance(entry, dict), "raw baseline entry must be an object")
        document_id = check_identifier(entry.get("id"), "raw baseline document id")
        require(document_id in acquisition_by_id, f"raw baseline has a document not in acquisition manifest: {document_id}")
        require(document_id not in records, f"raw baseline has duplicate document id {document_id}")
        document = acquisition_by_id[document_id]
        require(check_relative_path(entry.get("pdf"), f"{document_id} raw baseline PDF").as_posix() == document["pdf"], f"{document_id} raw baseline PDF path differs from acquisition")
        require(check_sha256(entry.get("source_sha256"), f"{document_id} raw baseline source SHA-256") == document["sha256"], f"{document_id} raw baseline source SHA-256 differs from acquisition")
        status = normalized_string(entry.get("status"), f"{document_id} raw baseline status")
        require(status in {"markdown", "ocr_required"}, f"{document_id} raw baseline has unsupported status {status!r}")
        if status == "markdown":
            markdown_name = check_relative_path(entry.get("markdown"), f"{document_id} raw baseline Markdown").as_posix()
            require(markdown_name == f"{document_id}.md", f"{document_id} raw baseline Markdown must use the canonical filename")
            expected_hash = check_sha256(entry.get("markdown_sha256"), f"{document_id} raw baseline Markdown SHA-256")
            expected_bytes = check_positive_int(entry.get("markdown_bytes"), f"{document_id} raw baseline Markdown byte count")
            markdown_file = safe_child(raw_root, PurePosixPath(markdown_name), f"{document_id} raw baseline Markdown")
            require(markdown_file.is_file() and not markdown_file.is_symlink(), f"{document_id} raw baseline Markdown is missing")
            require(markdown_file.stat().st_size == expected_bytes, f"{document_id} raw baseline Markdown byte count drifted")
            actual_hash = sha256_file(markdown_file)
            require(actual_hash == expected_hash, f"{document_id} raw baseline Markdown SHA-256 drifted")
        else:
            require("markdown" not in entry and "markdown_sha256" not in entry and "markdown_bytes" not in entry, f"{document_id} OCR-required baseline must not provide Markdown")
        records[document_id] = entry
    require(set(records) == set(acquisition_by_id), "raw baseline index must account for every acquisition document")
    return records


def assemble(args: argparse.Namespace) -> tuple[int, list[str]]:
    repo_root = Path(__file__).resolve().parents[2]
    benchmark_root = args.benchmark_root.resolve()
    acquisition_path = args.acquisition_manifest.resolve()
    corpus_root = args.corpus_root.resolve()
    raw_index_path = args.raw_index.resolve()
    raw_root = args.raw_root.resolve()
    truth_root = args.ground_truth_root.resolve()
    output_path = args.output.resolve()

    for path, label in ((benchmark_root, "benchmark root"), (corpus_root, "corpus root"), (raw_root, "raw baseline root"), (truth_root, "ground truth root")):
        require(path.is_dir() and not path.is_symlink(), f"{label} is missing or not a regular directory: {path}")
        relative_to_benchmark(path, benchmark_root, label)
    relative_to_benchmark(acquisition_path, benchmark_root, "acquisition manifest")
    relative_to_benchmark(output_path, benchmark_root, "development manifest output")
    is_git_ignored(repo_root, corpus_root, "external corpus")
    is_git_ignored(repo_root, raw_root, "raw baseline")
    is_git_ignored(repo_root, truth_root, "locked ground truth")
    is_git_ignored(repo_root, output_path, "development manifest output")

    acquisition = load_json(acquisition_path, "acquisition manifest")
    documents = validated_acquisition(acquisition, corpus_root)
    raw_index = load_json(raw_index_path, "raw baseline index")
    revision, patch_hash, binary_hash = checked_engine_revision(repo_root, raw_index)
    raw_by_id = raw_records(raw_index, documents, raw_root)

    goldens_root = truth_root / "goldens"
    reviews_root = truth_root / "reviews"
    require(goldens_root.is_dir() and not goldens_root.is_symlink(), f"goldens directory is missing: {goldens_root}")
    require(reviews_root.is_dir() and not reviews_root.is_symlink(), f"reviews directory is missing: {reviews_root}")
    selected: list[dict[str, Any]] = []
    diagnostics: list[str] = []
    for document in documents:
        record = raw_by_id[document["id"]]
        if record["status"] == "ocr_required":
            diagnostics.append(f"excluded OCR-only diagnostic: {document['id']}")
            continue
        document_id = document["id"]
        golden_file = safe_child(goldens_root, PurePosixPath(f"{document_id}.md"), f"{document_id} locked Markdown")
        review_file = safe_child(reviews_root, PurePosixPath(f"{document_id}.json"), f"{document_id} locked review")
        require(golden_file.is_file() and not golden_file.is_symlink(), f"{document_id} locked Markdown is missing")
        require(review_file.is_file() and not review_file.is_symlink(), f"{document_id} locked review is missing")
        golden_data = golden_file.read_bytes()
        markdown = validate_canonical_markdown(golden_data, document_id)
        golden_hash = sha256_bytes(golden_data)
        review = load_json(review_file, f"{document_id} locked review")
        review_id = first_string(review, ("id", "document_id"), f"{document_id} review document id")
        require(review_id == document_id, f"{document_id} review ID does not match its filename")
        ground_truth_path = (truth_root / "goldens" / f"{document_id}.md").resolve().relative_to(benchmark_root).as_posix()
        ground_truth, ocr_pages = normalized_ground_truth(review, document, markdown, golden_hash, ground_truth_path)
        if document["document_type"] == "bank_statement":
            require(ground_truth.get("critical_values"), f"{document_id} bank statement needs locked critical values")
            require(ground_truth.get("minimum_critical_value_accuracy") == 1.0, f"{document_id} bank statement critical-value accuracy must be 1.0")
        raw_hash = check_sha256(record.get("markdown_sha256"), f"{document_id} raw Markdown SHA-256")
        pdf_path = (corpus_root / PurePosixPath(document["pdf"])).resolve().relative_to(benchmark_root).as_posix()
        selected.append(
            {
                "id": document_id,
                "pdf": pdf_path,
                "sha256": document["sha256"],
                "document_type": document["document_type"],
                "origin": document["origin"],
                "features": document["features"],
                "expected_page_count": document["pages"],
                "expected_ocr_pages": ocr_pages,
                "raw_markdown_sha256": raw_hash,
                "ground_truth": ground_truth,
                "rights": {
                    "status": "external-only",
                    "license": document["rights_hypothesis"],
                    "source_url": document["publisher_url"],
                    "attribution": f"{document['publisher']}: {document['title']}",
                },
            }
        )

    acquisition_minimum = acquisition["corpus"]["minimum_documents"]
    statement_minimum = acquisition["corpus"]["minimum_bank_statements"]
    require(len(selected) >= max(20, acquisition_minimum), f"only {len(selected)} Markdown-capable locked documents; need at least {max(20, acquisition_minimum)}")
    statement_count = sum(document["document_type"] == "bank_statement" for document in selected)
    require(statement_count >= max(5, statement_minimum), f"only {statement_count} Markdown-capable locked bank statements; need at least {max(5, statement_minimum)}")

    raw_directory = relative_to_benchmark(raw_root, benchmark_root, "raw baseline root")
    manifest = {
        "schema_version": 2,
        "corpus": {
            "id": "documentkit-curated-external-v2-development",
            "distribution": "external-only",
            "source_url": "https://github.com/swiftlysingh/DocumentKit",
        },
        "raw_engine_baseline": {
            "engine": "pdf-inspector",
            "revision": revision,
            "markdown_directory": raw_directory,
            "apple_cmaps_patch_sha256": patch_hash,
            "binary_sha256": binary_hash,
            "index_sha256": sha256_file(raw_index_path),
        },
        "documents": selected,
    }

    if not args.dry_run:
        require(not output_path.is_symlink(), f"development manifest output must not be a symbolic link: {output_path}")
        output_path.parent.mkdir(parents=True, exist_ok=True)
        serialized = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
        descriptor, temporary_name = tempfile.mkstemp(prefix=".v0.2-development.", dir=output_path.parent)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(serialized)
            os.replace(temporary_name, output_path)
        except Exception:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass
            raise
    return len(selected), diagnostics


def parser() -> argparse.ArgumentParser:
    repo_root = Path(__file__).resolve().parents[2]
    benchmarks = repo_root / "Benchmarks"
    result = argparse.ArgumentParser(description="Fail-closed assembler for the ignored DocumentKit v0.2 development benchmark manifest.")
    result.add_argument("--benchmark-root", type=Path, default=benchmarks)
    result.add_argument("--acquisition-manifest", type=Path, default=benchmarks / "Manifests" / "curated-external-v2.json")
    result.add_argument("--corpus-root", type=Path, default=benchmarks / "Corpus" / "curated-v2")
    result.add_argument("--raw-index", type=Path, default=benchmarks / "RawBaseline" / "curated-v2" / "index.json")
    result.add_argument("--raw-root", type=Path, default=benchmarks / "RawBaseline" / "curated-v2")
    result.add_argument("--ground-truth-root", type=Path, default=benchmarks / "GroundTruth" / "curated-v2")
    result.add_argument("--output", type=Path, default=benchmarks / "Manifests" / "v0.2-development.json")
    result.add_argument("--dry-run", action="store_true", help="validate every input without writing the manifest")
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        count, diagnostics = assemble(args)
    except AssemblyError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"error: filesystem failure: {error}", file=sys.stderr)
        return 1
    print(f"assembled v0.2 development manifest with {count} locked Markdown documents")
    for diagnostic in diagnostics:
        print(diagnostic)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
