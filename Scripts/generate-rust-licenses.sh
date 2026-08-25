#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST="$ROOT/Native/DocumentKitCore/Cargo.toml"
CONFIG="$ROOT/Native/DocumentKitCore/about.toml"
RENDERER="$ROOT/Scripts/render-rust-licenses.rb"
OUTPUT="$ROOT/RUST_THIRD_PARTY_LICENSES.md"
ENGINE="$ROOT/Build/vendor/pdf-inspector/Cargo.toml"
CARGO_ABOUT_VERSION=0.9.1
MODE=${1:---write}
DISCOVERY=
GENERATED=

cleanup() {
    if [ -n "$DISCOVERY" ]; then
        rm -f "$DISCOVERY"
    fi
    if [ -n "$GENERATED" ]; then
        rm -f "$GENERATED"
    fi
}
trap cleanup 0
trap 'cleanup; exit 1' HUP INT TERM

case "$MODE" in
    --write|--check) ;;
    *)
        echo "Usage: $0 [--write|--check]" >&2
        exit 2
        ;;
esac

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [--write|--check]" >&2
    exit 2
fi

if [ ! -f "$ENGINE" ]; then
    echo "Run Scripts/prepare-engine.sh before generating Rust licenses." >&2
    exit 1
fi

if ! command -v cargo-about >/dev/null 2>&1; then
    echo "Install cargo-about $CARGO_ABOUT_VERSION with:" >&2
    echo "  cargo install --locked --features cli cargo-about --version $CARGO_ABOUT_VERSION" >&2
    exit 1
fi

ACTUAL_VERSION=$(cargo-about --version)
if [ "$ACTUAL_VERSION" != "cargo-about $CARGO_ABOUT_VERSION" ]; then
    echo "Expected cargo-about $CARGO_ABOUT_VERSION but found $ACTUAL_VERSION." >&2
    exit 1
fi

cargo fetch --locked --manifest-path "$MANIFEST"

DISCOVERY=$(mktemp "${TMPDIR:-/tmp}/documentkit-rust-license-discovery.XXXXXX")
GENERATED=$(mktemp "${TMPDIR:-/tmp}/documentkit-rust-licenses.XXXXXX")
cargo-about about generate \
    --manifest-path "$MANIFEST" \
    --config "$CONFIG" \
    --locked \
    --offline \
    --fail \
    --format json \
    --output-file "$DISCOVERY"

ruby "$RENDERER" "$ROOT" "$DISCOVERY" "$GENERATED"

if [ "$MODE" = "--write" ]; then
    cp "$GENERATED" "$OUTPUT"
    chmod 644 "$OUTPUT"
    echo "Generated ${OUTPUT#$ROOT/}."
elif ! cmp -s "$OUTPUT" "$GENERATED"; then
    echo "Rust third-party licenses are stale. Regenerate them with:" >&2
    echo "  Scripts/generate-rust-licenses.sh --write" >&2
    diff -u "$OUTPUT" "$GENERATED" || true
    exit 1
else
    echo "Rust third-party licenses verified."
fi
