#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_directory/../.." && pwd)
manifest=${1:-"$repository_root/Benchmarks/Manifests/curated-external-v2.json"}
corpus_root=${2:-"$repository_root/Benchmarks/Corpus/curated-v2"}
output_root=${3:-"$repository_root/Benchmarks/RawBaseline/curated-v2"}
target_directory=${DOCUMENTKIT_RAW_ENGINE_TARGET:-"${TMPDIR:-/tmp}/documentkit-raw-engine-build"}
engine_root="$repository_root/Build/vendor/pdf-inspector"
engine_revision=$(tr -d '[:space:]' < "$repository_root/ENGINE_REVISION")
binary="$target_directory/release/pdf2md"

for command_name in cargo git jq shasum; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done
[ -f "$manifest" ] || fail "manifest not found: $manifest"
[ -d "$corpus_root" ] || fail "corpus not found: $corpus_root"

"$repository_root/Scripts/prepare-engine.sh" >/dev/null
[ "$(git -C "$engine_root" rev-parse HEAD)" = "$engine_revision" ] || fail "engine revision mismatch"

cargo build \
  --release \
  --offline \
  --manifest-path "$engine_root/Cargo.toml" \
  --bin pdf2md \
  --target-dir "$target_directory"
[ -x "$binary" ] || fail "pdf2md was not built: $binary"

mkdir -p "$output_root"
output_root=$(CDPATH= cd -P -- "$output_root" && pwd)
case "$output_root" in
  "$repository_root"/*)
    repository_relative=${output_root#"$repository_root"/}
    git -C "$repository_root" check-ignore -q -- "$repository_relative" || \
      fail "output is not ignored by Git: $repository_relative"
    ;;
esac

scratch=$(mktemp -d "${TMPDIR:-/tmp}/documentkit-raw-baseline.XXXXXX")
cleanup() {
  rm -rf -- "$scratch"
}
trap cleanup EXIT HUP INT TERM

jq -c '.documents[]' "$manifest" > "$scratch/documents.jsonl"
: > "$scratch/baselines.jsonl"

while IFS= read -r document; do
  id=$(printf '%s' "$document" | jq -er '.id')
  relative_pdf=$(printf '%s' "$document" | jq -er '.pdf')
  expected_source_sha=$(printf '%s' "$document" | jq -er '.sha256')
  source_pdf="$corpus_root/$relative_pdf"
  output_markdown="$output_root/$id.md"
  temporary_markdown="$scratch/$id.md"

  [ -f "$source_pdf" ] || fail "$id source PDF is missing"
  actual_source_sha=$(shasum -a 256 "$source_pdf" | awk '{print $1}')
  [ "$actual_source_sha" = "$expected_source_sha" ] || fail "$id source SHA-256 mismatch"

  if "$binary" "$source_pdf" "$temporary_markdown"; then
    mv -- "$temporary_markdown" "$output_markdown"
    markdown_sha=$(shasum -a 256 "$output_markdown" | awk '{print $1}')
    markdown_bytes=$(wc -c < "$output_markdown" | tr -d '[:space:]')
    jq -cn \
      --arg id "$id" \
      --arg pdf "$relative_pdf" \
      --arg source_sha256 "$actual_source_sha" \
      --arg markdown "$id.md" \
      --arg markdown_sha256 "$markdown_sha" \
      --argjson markdown_bytes "$markdown_bytes" \
      '{id: $id, status: "markdown", pdf: $pdf, source_sha256: $source_sha256, markdown: $markdown, markdown_sha256: $markdown_sha256, markdown_bytes: $markdown_bytes}' \
      >> "$scratch/baselines.jsonl"
    printf 'baseline\t%s\t%s bytes\t%s\n' "$id" "$markdown_bytes" "$markdown_sha"
  else
    status=$?
    rm -f -- "$temporary_markdown" "$output_markdown"
    [ "$status" -eq 2 ] || fail "$id raw engine failed with exit status $status"
    jq -cn \
      --arg id "$id" \
      --arg pdf "$relative_pdf" \
      --arg source_sha256 "$actual_source_sha" \
      '{id: $id, status: "ocr_required", pdf: $pdf, source_sha256: $source_sha256}' \
      >> "$scratch/baselines.jsonl"
    printf 'baseline\t%s\tOCR required\n' "$id"
  fi
done < "$scratch/documents.jsonl"

patch_sha=$(shasum -a 256 "$repository_root/Patches/pdf-inspector-embed-apple-cmaps.patch" | awk '{print $1}')
binary_sha=$(shasum -a 256 "$binary" | awk '{print $1}')
generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
jq -s \
  --arg generated_at "$generated_at" \
  --arg engine_revision "$engine_revision" \
  --arg patch_sha256 "$patch_sha" \
  --arg binary_sha256 "$binary_sha" \
  '{schema_version: 1, generated_at: $generated_at, engine: "pdf-inspector", engine_revision: $engine_revision, apple_cmaps_patch_sha256: $patch_sha256, binary_sha256: $binary_sha256, documents: .}' \
  "$scratch/baselines.jsonl" > "$scratch/index.json"
mv -- "$scratch/index.json" "$output_root/index.json"

printf 'raw baseline verified\t%s documents\t%s\n' \
  "$(jq '.documents | length' "$output_root/index.json")" \
  "$output_root/index.json"
