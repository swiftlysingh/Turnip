#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRATCH=${DOCUMENTKIT_BENCHMARK_SCRATCH:-"$ROOT/.cache/release-build"}
SOURCE_REVISION=${DOCUMENTKIT_BENCHMARK_SOURCE_REVISION:-}
OUTPUT=
EXPECT_OUTPUT=0
MANIFEST=
EXPECT_MANIFEST=0

for ARG in "$@"; do
    if [ "$EXPECT_MANIFEST" -eq 1 ]; then
        MANIFEST=$ARG
        EXPECT_MANIFEST=0
    elif [ "$EXPECT_OUTPUT" -eq 1 ]; then
        OUTPUT=$ARG
        EXPECT_OUTPUT=0
    elif [ "$ARG" = "--manifest" ]; then
        EXPECT_MANIFEST=1
    elif [ "$ARG" = "--output" ]; then
        EXPECT_OUTPUT=1
    fi
done

if [ -z "$OUTPUT" ]; then
    echo "error: --output is required" >&2
    exit 2
fi
if [ -z "$MANIFEST" ]; then
    echo "error: --manifest is required" >&2
    exit 2
fi
MANIFEST_DIR=$(dirname "$MANIFEST")
if [ ! -d "$MANIFEST_DIR" ]; then
    echo "error: manifest parent directory does not exist: $MANIFEST_DIR" >&2
    exit 2
fi
MANIFEST_ABS=$(CDPATH= cd -- "$MANIFEST_DIR" && pwd -P)/$(basename "$MANIFEST")
CANONICAL_MANIFEST="$ROOT/Manifests/v0.2-development.json"
if [ "$MANIFEST_ABS" != "$CANONICAL_MANIFEST" ]; then
    echo "error: release benchmark requires the canonical generated manifest $CANONICAL_MANIFEST" >&2
    exit 2
fi
RAW_BINARY=${DOCUMENTKIT_RAW_ENGINE_BINARY:-}
if [ -z "$RAW_BINARY" ]; then
    echo "error: DOCUMENTKIT_RAW_ENGINE_BINARY must identify the exact pdf2md binary used for the baseline" >&2
    exit 2
fi
if [ -e "$OUTPUT" ]; then
    if [ ! -d "$OUTPUT" ]; then
        echo "error: benchmark output path exists and is not a directory: $OUTPUT" >&2
        exit 2
    fi
    if /usr/bin/python3 -c 'import os, sys; sys.exit(0 if any(os.scandir(sys.argv[1])) else 1)' "$OUTPUT"; then
        echo "error: benchmark output directory must be new or empty: $OUTPUT" >&2
        exit 2
    fi
fi
if ! printf '%s' "$SOURCE_REVISION" | grep -Eq '^[0-9a-fA-F]{40}$'; then
    echo "error: DOCUMENTKIT_BENCHMARK_SOURCE_REVISION must be an exact 40-character commit SHA" >&2
    exit 2
fi

REPO_ROOT=$(git -C "$ROOT" rev-parse --show-toplevel)
HEAD_REVISION=$(git -C "$REPO_ROOT" rev-parse HEAD)
if [ "$SOURCE_REVISION" != "$HEAD_REVISION" ]; then
    echo "error: source revision does not match the checked-out HEAD $HEAD_REVISION" >&2
    exit 2
fi
if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
    echo "error: release benchmarks require a clean tracked worktree" >&2
    exit 2
fi
if git -C "$REPO_ROOT" ls-files --others --exclude-standard | grep -q .; then
    echo "error: release benchmarks require no untracked source files" >&2
    exit 2
fi

"$ROOT/Scripts/assemble-v0.2-development.py" \
    --raw-binary "$RAW_BINARY" \
    --output "$MANIFEST_ABS"

OUTPUT_PARENT=$(dirname "$OUTPUT")
mkdir -p "$OUTPUT_PARENT"
TEMP_TIME_LOG=$(mktemp "${TMPDIR:-/tmp}/documentkit-benchmark-time.XXXXXX")
cleanup() {
    rm -f "$TEMP_TIME_LOG"
}
trap cleanup EXIT HUP INT TERM

TIME_LOG="$OUTPUT/resource-usage.txt"
RESOURCE_JSON="$OUTPUT/resource-usage.json"

swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH"
BIN=$(swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH" --show-bin-path)

# macOS time -l reports one process-lifetime peak RSS for the entire corpus run.
# It is intentionally not attributed to an individual engine or document.
set +e
/usr/bin/time -l "$BIN/documentkit-benchmark" --require-release "$@" 2>"$TEMP_TIME_LOG"
BENCHMARK_EXIT=$?
set -e
mkdir -p "$OUTPUT"
mv "$TEMP_TIME_LOG" "$TIME_LOG"
trap - EXIT HUP INT TERM

MAX_RSS=$(awk '/maximum resident set size/ { print $1; exit }' "$TIME_LOG")
case "$MAX_RSS" in
    ''|*[!0-9]*)
        echo "error: could not parse maximum resident set size from $TIME_LOG" >&2
        exit 1
        ;;
esac

LOG_SHA256=$(shasum -a 256 "$TIME_LOG" | awk '{ print $1 }')
SUMMARY="$OUTPUT/summary.json"
if [ -f "$SUMMARY" ]; then
    SUMMARY_SHA256=$(shasum -a 256 "$SUMMARY" | awk '{ print $1 }')
    printf '{\n  "schema_version": 1,\n  "scope": "entire-corpus-process",\n  "maximum_resident_set_size_bytes": %s,\n  "source_revision": "%s",\n  "summary_sha256": "%s",\n  "resource_log_sha256": "%s"\n}\n' \
        "$MAX_RSS" \
        "$SOURCE_REVISION" \
        "$SUMMARY_SHA256" \
        "$LOG_SHA256" \
        > "$RESOURCE_JSON"
    echo "Corpus-process resource evidence: $RESOURCE_JSON"
fi

exit "$BENCHMARK_EXIT"
