#!/bin/sh
set -eu
unset GIT_INDEX_FILE

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURE=

cleanup() {
    if [ -n "$FIXTURE" ]; then
        rm -rf "$FIXTURE"
    fi
}
trap cleanup 0
trap 'cleanup; exit 1' HUP INT TERM

FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/documentkit-engine-provenance.XXXXXX")
CORE="$FIXTURE/Native/DocumentKitCore"
ENGINE="$FIXTURE/Build/vendor/pdf-inspector"
MANIFEST="$CORE/Cargo.toml"
TARGET="$FIXTURE/target"

mkdir -p "$CORE/src" "$ENGINE/src" "$FIXTURE/Scripts"
cp "$ROOT/Native/DocumentKitCore/build.rs" "$CORE/build.rs"
cp "$ROOT/Scripts/prepare-engine.sh" "$FIXTURE/Scripts/prepare-engine.sh"
chmod +x "$FIXTURE/Scripts/prepare-engine.sh"

printf '%s\n' \
    '[package]' \
    'name = "documentkit-provenance-fixture"' \
    'version = "0.1.0"' \
    'edition = "2024"' \
    'build = "build.rs"' \
    '' \
    '[dependencies]' \
    'pdf-inspector = { path = "../../Build/vendor/pdf-inspector", version = "=1.0.0", optional = true }' \
    > "$MANIFEST"
printf '%s\n' 'pub fn fixture() {}' > "$CORE/src/lib.rs"

printf '%s\n' \
    '[package]' \
    'name = "pdf-inspector"' \
    'version = "1.0.0"' \
    'edition = "2024"' \
    > "$ENGINE/Cargo.toml"
printf '%s\n' 'pub const BASELINE: bool = true;' > "$ENGINE/src/lib.rs"
printf '%s\n' 'src/ignored/' > "$ENGINE/.gitignore"

git -C "$ENGINE" init -q
git -C "$ENGINE" config user.email provenance@example.invalid
git -C "$ENGINE" config user.name provenance-test
git -C "$ENGINE" add Cargo.toml src/lib.rs .gitignore
git -C "$ENGINE" commit -qm baseline
REVISION=$(git -C "$ENGINE" rev-parse HEAD)
printf '%s\n' "$REVISION" > "$FIXTURE/ENGINE_REVISION"

cargo generate-lockfile --offline --manifest-path "$MANIFEST"
"$FIXTURE/Scripts/prepare-engine.sh"

build() {
    CARGO_TARGET_DIR="$TARGET" cargo build --offline --locked --manifest-path "$MANIFEST" "$@"
}

expect_build_failure() {
    name=$1
    expected=$2
    log="$FIXTURE/$name.log"

    if build -vv > "$log" 2>&1; then
        echo "Expected $name nested file to rerun and fail provenance verification." >&2
        exit 1
    fi
    if ! grep -Fq 'build-script-build' "$log" || ! grep -Fq "$expected" "$log"; then
        echo "Cargo did not rerun build.rs for the $name nested file." >&2
        sed -n '1,240p' "$log" >&2
        exit 1
    fi
}

build

mkdir -p "$ENGINE/src/ordinary/nested"
printf '%s\n' 'pub const UNEXPECTED: bool = true;' \
    > "$ENGINE/src/ordinary/nested/unexpected.rs"
expect_build_failure ordinary 'does not match ENGINE_REVISION exactly'

rm -rf "$ENGINE/src/ordinary"
build

mkdir -p "$ENGINE/src/ignored/nested"
printf '%s\n' 'pub const UNEXPECTED: bool = true;' \
    > "$ENGINE/src/ignored/nested/unexpected.rs"
expect_build_failure ignored 'contains ignored untracked files'

echo "Verified Cargo reruns provenance checks for nested ordinary and ignored files."
