#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LICENSES=
TAB=$(printf '\t')

cleanup() {
    if [ -n "$LICENSES" ]; then
        rm -f "$LICENSES"
    fi
}
trap cleanup 0
trap 'cleanup; exit 1' HUP INT TERM

LICENSES=$(mktemp "${TMPDIR:-/tmp}/documentkit-rust-licenses.XXXXXX")

cargo tree \
    --locked \
    --target aarch64-apple-ios \
    --edges normal,build \
    --prefix none \
    --no-dedupe \
    --format "{p}${TAB}{l}${TAB}{r}" \
    --manifest-path "$ROOT/Native/DocumentKitCore/Cargo.toml" \
    > "$LICENSES"

awk -F '\t' '
    $2 == "" {
        print "Missing license declaration: " $1 > "/dev/stderr"
        missing = 1
    }
    END { exit missing }
' "$LICENSES"

sed -E 's# \(/[^)]*\)##' "$LICENSES" | sort -u
