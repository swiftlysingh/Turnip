#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODULE_CACHE="$ROOT/.cache/fixture-module-cache"

mkdir -p "$MODULE_CACHE"
xcrun swift \
    -module-cache-path "$MODULE_CACHE" \
    "$ROOT/Fixtures/Smoke/generate-fixture.swift"

cd "$ROOT/Fixtures/Smoke"
shasum -a 256 -c SHA256SUMS
