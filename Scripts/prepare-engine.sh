#!/bin/sh
set -eu
unset GIT_INDEX_FILE

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPOSITORY=https://github.com/swiftlysingh/pdf-inspector.git
REVISION=$(tr -d '[:space:]' < "$ROOT/ENGINE_REVISION")
ENGINE="$ROOT/Build/vendor/pdf-inspector"
MANIFEST="$ROOT/Native/DocumentKitCore/Cargo.toml"

case "$REVISION" in
    ""|*[!0-9a-f]*)
        echo "ENGINE_REVISION must contain one lowercase 40-character Git revision." >&2
        exit 1
        ;;
esac
if [ "${#REVISION}" -ne 40 ]; then
    echo "ENGINE_REVISION must contain one lowercase 40-character Git revision." >&2
    exit 1
fi

EXPECTED_VERSION=$(sed -n 's/^pdf-inspector = {.*version = "=\([^"]*\)".*}$/\1/p' "$MANIFEST")
if [ -z "$EXPECTED_VERSION" ]; then
    echo "pdf-inspector must use an exact version pin in $MANIFEST" >&2
    exit 1
fi

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

ACTUAL_VERSION=$(awk '
    $0 == "[package]" { package = 1; next }
    package && /^\[/ { exit }
    package && /^version = "/ {
        sub(/^version = "/, "")
        sub(/"$/, "")
        print
        exit
    }
' "$ENGINE/Cargo.toml")
if [ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]; then
    echo "Expected pdf-inspector version $EXPECTED_VERSION but found $ACTUAL_VERSION." >&2
    exit 1
fi

ACTUAL_INDEX=
cleanup_indexes() {
    if [ -n "$ACTUAL_INDEX" ]; then
        rm -f "$ACTUAL_INDEX" "$ACTUAL_INDEX.lock"
    fi
}
trap cleanup_indexes 0
trap 'cleanup_indexes; exit 1' HUP INT TERM

ACTUAL_INDEX=$(mktemp "${TMPDIR:-/tmp}/documentkit-pdf-inspector-actual.XXXXXX")

if ! GIT_INDEX_FILE="$ACTUAL_INDEX" git -C "$ENGINE" read-tree HEAD; then
    echo "Could not prepare the expected pdf-inspector tree." >&2
    exit 1
fi
if ! EXPECTED_TREE=$(GIT_INDEX_FILE="$ACTUAL_INDEX" git -C "$ENGINE" write-tree); then
    echo "Could not create the expected pdf-inspector tree." >&2
    exit 1
fi

if ! GIT_INDEX_FILE="$ACTUAL_INDEX" git -C "$ENGINE" add -A -- .; then
    echo "Could not stage the prepared pdf-inspector tree." >&2
    exit 1
fi
if ! ACTUAL_TREE=$(GIT_INDEX_FILE="$ACTUAL_INDEX" git -C "$ENGINE" write-tree); then
    echo "Could not create the prepared pdf-inspector tree." >&2
    exit 1
fi
if [ "$EXPECTED_TREE" != "$ACTUAL_TREE" ]; then
    echo "Prepared pdf-inspector must match $REVISION exactly." >&2
    exit 1
fi
# `git add -A` above stages ordinary untracked files, so any unexpected file
# fails the tree comparison. Ignored files are not staged, so reject them here.
if [ -n "$(git -C "$ENGINE" ls-files --others --ignored --exclude-standard)" ]; then
    echo "Prepared pdf-inspector must not contain ignored untracked files." >&2
    exit 1
fi

echo "Prepared pdf-inspector $EXPECTED_VERSION@$REVISION"
