#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

cargo tree \
    --locked \
    --target aarch64-apple-ios \
    --edges normal,build \
    --prefix none \
    --no-dedupe \
    --format '{p}\t{l}\t{r}' \
    --manifest-path "$ROOT/Native/DocumentKitCore/Cargo.toml" |
    sort -u
