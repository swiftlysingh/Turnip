#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPOSITORY=https://github.com/swiftlysingh/pdf-inspector.git
REVISION=$(tr -d '[:space:]' < "$ROOT/ENGINE_REVISION")
ENGINE="$ROOT/Build/vendor/pdf-inspector"
PATCH="$ROOT/Patches/pdf-inspector-embed-apple-cmaps.patch"

if [ ! -d "$ENGINE/.git" ]; then
    mkdir -p "$(dirname "$ENGINE")"
    git clone --no-checkout "$REPOSITORY" "$ENGINE"
    git -C "$ENGINE" checkout --detach "$REVISION"
fi

ACTUAL=$(git -C "$ENGINE" rev-parse HEAD)
if [ "$ACTUAL" != "$REVISION" ]; then
    echo "Expected pdf-inspector $REVISION but found $ACTUAL in $ENGINE" >&2
    echo "Remove the ignored Build/vendor directory and run this script again." >&2
    exit 1
fi

if git -C "$ENGINE" apply --check "$PATCH" >/dev/null 2>&1; then
    git -C "$ENGINE" apply "$PATCH"
elif ! git -C "$ENGINE" apply --reverse --check "$PATCH" >/dev/null 2>&1; then
    echo "The Apple CMap patch does not apply cleanly to pdf-inspector $REVISION." >&2
    exit 1
fi

echo "Prepared pdf-inspector $REVISION"
