#!/bin/sh
set -eu
unset GIT_INDEX_FILE

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPOSITORY=https://github.com/swiftlysingh/pdf-inspector.git
REVISION=$(tr -d '[:space:]' < "$ROOT/ENGINE_REVISION")
ENGINE="$ROOT/Build/vendor/pdf-inspector"
PATCH="$ROOT/Patches/pdf-inspector-embed-apple-cmaps.patch"
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

if git -C "$ENGINE" apply --check "$PATCH" >/dev/null 2>&1; then
    git -C "$ENGINE" apply "$PATCH"
elif ! git -C "$ENGINE" apply --reverse --check "$PATCH" >/dev/null 2>&1; then
    echo "The Apple CMap patch does not apply cleanly to pdf-inspector $REVISION." >&2
    exit 1
fi

EXPECTED_INDEX=
ACTUAL_INDEX=
cleanup_indexes() {
    if [ -n "$EXPECTED_INDEX" ]; then
        rm -f "$EXPECTED_INDEX" "$EXPECTED_INDEX.lock"
    fi
    if [ -n "$ACTUAL_INDEX" ]; then
        rm -f "$ACTUAL_INDEX" "$ACTUAL_INDEX.lock"
    fi
}
trap cleanup_indexes 0
trap 'cleanup_indexes; exit 1' HUP INT TERM

EXPECTED_INDEX=$(mktemp "${TMPDIR:-/tmp}/documentkit-pdf-inspector-expected.XXXXXX")
ACTUAL_INDEX=$(mktemp "${TMPDIR:-/tmp}/documentkit-pdf-inspector-actual.XXXXXX")

if ! GIT_INDEX_FILE="$EXPECTED_INDEX" git -C "$ENGINE" read-tree HEAD || \
    ! GIT_INDEX_FILE="$EXPECTED_INDEX" git -C "$ENGINE" apply --cached -- "$PATCH"; then
    echo "Could not apply the tracked Apple CMap patch to pdf-inspector $REVISION." >&2
    exit 1
fi
if ! EXPECTED_TREE=$(GIT_INDEX_FILE="$EXPECTED_INDEX" git -C "$ENGINE" write-tree); then
    echo "Could not create the expected pdf-inspector tree." >&2
    exit 1
fi

if ! GIT_INDEX_FILE="$ACTUAL_INDEX" git -C "$ENGINE" read-tree HEAD || \
    ! GIT_INDEX_FILE="$ACTUAL_INDEX" git -C "$ENGINE" add -A -- .; then
    echo "Could not stage the prepared pdf-inspector tree." >&2
    exit 1
fi
if ! ACTUAL_TREE=$(GIT_INDEX_FILE="$ACTUAL_INDEX" git -C "$ENGINE" write-tree); then
    echo "Could not create the prepared pdf-inspector tree." >&2
    exit 1
fi
if [ "$EXPECTED_TREE" != "$ACTUAL_TREE" ]; then
    echo "Prepared pdf-inspector must match $REVISION plus $PATCH exactly." >&2
    exit 1
fi
# `git add -A` above stages ordinary untracked files. That allows patch-added
# files only when they match the expected tree, and makes any unexpected file
# fail the tree comparison. Ignored files are not staged, so reject them here.
if [ -n "$(git -C "$ENGINE" ls-files --others --ignored --exclude-standard)" ]; then
    echo "Prepared pdf-inspector must not contain ignored untracked files." >&2
    exit 1
fi

echo "Prepared pdf-inspector $EXPECTED_VERSION@$REVISION"
