#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRATCH=${DOCUMENTKIT_BENCHMARK_SCRATCH:-"$ROOT/.cache/release-build"}
SOURCE_REVISION=${DOCUMENTKIT_BENCHMARK_SOURCE_REVISION:-}
OUTPUT=
EXPECT_OUTPUT=0

for ARG in "$@"; do
    if [ "$EXPECT_OUTPUT" -eq 1 ]; then
        OUTPUT=$ARG
        EXPECT_OUTPUT=0
    elif [ "$ARG" = "--output" ]; then
        EXPECT_OUTPUT=1
    fi
done

if [ -z "$OUTPUT" ]; then
    echo "error: --output is required" >&2
    exit 2
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
/usr/bin/time -l "$BIN/documentkit-benchmark" --require-release "$@" 2>"$TEMP_TIME_LOG"
mv "$TEMP_TIME_LOG" "$TIME_LOG"
trap - EXIT HUP INT TERM

MAX_RSS=$(awk '/maximum resident set size/ { print $1; exit }' "$TIME_LOG")
case "$MAX_RSS" in
    ''|*[!0-9]*)
        echo "error: could not parse maximum resident set size from $TIME_LOG" >&2
        exit 1
        ;;
esac

SUMMARY="$OUTPUT/summary.json"
SUMMARY_SHA256=$(shasum -a 256 "$SUMMARY" | awk '{ print $1 }')
LOG_SHA256=$(shasum -a 256 "$TIME_LOG" | awk '{ print $1 }')
printf '{\n  "schema_version": 1,\n  "scope": "entire-corpus-process",\n  "maximum_resident_set_size_bytes": %s,\n  "source_revision": "%s",\n  "summary_sha256": "%s",\n  "resource_log_sha256": "%s"\n}\n' \
    "$MAX_RSS" \
    "$SOURCE_REVISION" \
    "$SUMMARY_SHA256" \
    "$LOG_SHA256" \
    > "$RESOURCE_JSON"

echo "Corpus-process resource evidence: $RESOURCE_JSON"
