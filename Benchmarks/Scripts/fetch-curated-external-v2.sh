#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/../.." && pwd)
manifest=${1:-"$repository_root/Benchmarks/Manifests/curated-external-v2.json"}
destination_root=${2:-"$repository_root/Benchmarks/Corpus/curated-v2"}

for command_name in curl jq shasum swiftc; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done
[ -f "$manifest" ] || fail "manifest not found: $manifest"

jq -e '
  . as $root |
  .schema_version == 2 and
  .corpus.distribution == "external-only" and
  .corpus.ground_truth.status == "not-authored" and
  (.corpus.minimum_documents | type == "number" and . >= 20) and
  (.corpus.minimum_bank_statements | type == "number" and . >= 5) and
  (.documents | type == "array") and
  ((.documents | length) >= $root.corpus.minimum_documents) and
  (([.documents[] | select(.document_type == "bank_statement")] | length) >= $root.corpus.minimum_bank_statements) and
  ([.documents[].id] | length == (unique | length)) and
  ([.documents[].pdf] | length == (unique | length)) and
  ([.documents[].sha256] | length == (unique | length)) and
  ([.documents[].source.final_url] | length == (unique | length)) and
  all(.documents[];
    (.id | type == "string" and test("^[a-z0-9][a-z0-9-]+$")) and
    (.pdf | type == "string" and endswith(".pdf") and
      (startswith("/") | not) and
      (split("/") | index("..") == null) and
      all(explode[]; . >= 32)) and
    (.title | type == "string" and length > 0) and
    (.publisher | type == "string" and length > 0) and
    (.retrieved_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) and
    (.source.request_url | type == "string" and startswith("https://")) and
    (.source.final_url | type == "string" and startswith("https://")) and
    (.source.publisher_page_url | type == "string" and startswith("https://")) and
    (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.bytes | type == "number" and . > 0 and floor == .) and
    (.pages | type == "number" and . > 0 and floor == .) and
    (.document_type | type == "string" and length > 0) and
    (.origin | type == "string" and length > 0) and
    (.categories | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) and
    (.features | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) and
    (.rights.status == "external-only") and
    (.rights.review_status == "not-legal-review") and
    (.rights.evidence_url | type == "string" and startswith("https://")) and
    (.rights.hypothesis | type == "string" and length > 0) and
    (has("ground_truth") | not) and
    (has("raw_markdown_sha256") | not)
  )
' "$manifest" >/dev/null || fail "schema-v2 manifest validation failed"

mkdir -p "$destination_root"
destination_root=$(CDPATH= cd -P -- "$destination_root" && pwd)

build_directory=$(mktemp -d "${TMPDIR:-/tmp}/documentkit-corpus-fetch.XXXXXX")
active_download=
cleanup() {
  if [ -n "$active_download" ] && [ -f "$active_download" ]; then
    rm -f -- "$active_download"
  fi
  rm -rf -- "$build_directory"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$build_directory/module-cache"
SWIFT_MODULECACHE_PATH="$build_directory/module-cache" \
CLANG_MODULE_CACHE_PATH="$build_directory/module-cache" \
  swiftc -framework PDFKit \
  "$script_directory/validate-pdfkit.swift" \
  -o "$build_directory/validate-pdfkit"

jq -c '.documents[]' "$manifest" > "$build_directory/documents.jsonl"

while IFS= read -r document; do
  id=$(printf '%s' "$document" | jq -er '.id')
  relative_path=$(printf '%s' "$document" | jq -er '.pdf')
  request_url=$(printf '%s' "$document" | jq -er '.source.request_url')
  final_url=$(printf '%s' "$document" | jq -er '.source.final_url')
  expected_sha256=$(printf '%s' "$document" | jq -er '.sha256')
  expected_bytes=$(printf '%s' "$document" | jq -er '.bytes')
  expected_pages=$(printf '%s' "$document" | jq -er '.pages')

  destination_path="$destination_root/$relative_path"
  destination_directory=$(dirname -- "$destination_path")
  mkdir -p "$destination_directory"
  destination_directory=$(CDPATH= cd -P -- "$destination_directory" && pwd)
  case "$destination_directory" in
    "$destination_root"|"$destination_root"/*) ;;
    *) fail "$id resolves outside the destination root" ;;
  esac
  [ ! -L "$destination_path" ] || fail "$id destination is a symbolic link"

  case "$destination_path" in
    "$repository_root"/*)
      repository_relative=${destination_path#"$repository_root"/}
      git -C "$repository_root" check-ignore -q -- "$repository_relative" || \
        fail "$id destination is not ignored by Git: $repository_relative"
      if git -C "$repository_root" ls-files --error-unmatch -- "$repository_relative" >/dev/null 2>&1; then
        fail "$id destination is tracked by Git: $repository_relative"
      fi
      ;;
  esac

  if [ ! -f "$destination_path" ]; then
    active_download=$(mktemp "$destination_directory/.documentkit-download.XXXXXX")
    if ! transfer=$(curl \
      --fail \
      --silent \
      --show-error \
      --location \
      --proto '=https' \
      --proto-redir '=https' \
      --retry 2 \
      --retry-all-errors \
      --user-agent 'Mozilla/5.0 (compatible; DocumentKitCorpus/0.2)' \
      --output "$active_download" \
      --write-out '%{json}' \
      -- "$request_url"); then
      fail "$id download failed: $request_url"
    fi
    printf '%s' "$transfer" | jq -e \
      --arg final_url "$final_url" \
      --argjson expected_bytes "$expected_bytes" \
      '.http_code == 200 and .url_effective == $final_url and .size_download == $expected_bytes' \
      >/dev/null || fail "$id response URL, status, or byte count drifted"
    candidate_path=$active_download
  else
    candidate_path=$destination_path
  fi

  actual_bytes=$(wc -c < "$candidate_path" | tr -d '[:space:]')
  [ "$actual_bytes" = "$expected_bytes" ] || \
    fail "$id byte count mismatch: expected $expected_bytes, found $actual_bytes"
  actual_sha256=$(shasum -a 256 "$candidate_path" | awk '{print $1}')
  [ "$actual_sha256" = "$expected_sha256" ] || \
    fail "$id SHA-256 mismatch: expected $expected_sha256, found $actual_sha256"
  "$build_directory/validate-pdfkit" "$candidate_path" "$expected_pages"

  if [ "$candidate_path" != "$destination_path" ]; then
    mv -- "$candidate_path" "$destination_path"
    active_download=
  fi
  printf 'verified\t%s\t%s bytes\t%s pages\n' "$id" "$expected_bytes" "$expected_pages"
done < "$build_directory/documents.jsonl"

document_count=$(jq -r '.documents | length' "$manifest")
statement_count=$(jq -r '[.documents[] | select(.document_type == "bank_statement")] | length' "$manifest")
total_bytes=$(jq -r '[.documents[].bytes] | add' "$manifest")
total_pages=$(jq -r '[.documents[].pages] | add' "$manifest")
printf 'corpus verified\t%s documents\t%s bank statements\t%s bytes\t%s pages\n' \
  "$document_count" "$statement_count" "$total_bytes" "$total_pages"
