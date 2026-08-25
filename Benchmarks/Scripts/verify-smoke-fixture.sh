#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURE_DIR="$ROOT/Fixtures/Smoke"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/turnip-smoke-fixture.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM

(cd "$FIXTURE_DIR" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1)
xcrun swift \
    -module-cache-path "$TEMP_DIR/module-cache" \
    "$FIXTURE_DIR/generate-fixture.swift" \
    --output-dir "$TEMP_DIR/generated" >/dev/null 2>&1

(cd "$TEMP_DIR/generated" && shasum -a 256 -c "$FIXTURE_DIR/SHA256SUMS" >/dev/null 2>&1)
cmp -s "$FIXTURE_DIR/synthetic-amex-standard.pdf" "$TEMP_DIR/generated/synthetic-amex-standard.pdf"
cmp -s "$FIXTURE_DIR/synthetic-amex-screen-reader.pdf" "$TEMP_DIR/generated/synthetic-amex-screen-reader.pdf"
printf '%s\n' 'Synthetic AMEX smoke fixture verified.'
