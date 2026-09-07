#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ARTIFACT="$ROOT/Artifacts/DocumentKitCore.xcframework"
MANIFEST="$ROOT/Native/DocumentKitCore/Cargo.toml"
LOCKFILE="$ROOT/Native/DocumentKitCore/Cargo.lock"
RUST_SOURCE="$ROOT/Native/DocumentKitCore/src/lib.rs"
SWIFT_SOURCE="$ROOT/Sources/Turnip/Turnip.swift"
PATCH="$ROOT/Patches/pdf-inspector-embed-apple-cmaps.patch"
ENGINE_REVISION=$(tr -d '[:space:]' < "$ROOT/ENGINE_REVISION")
ENGINE_VERSION=$(sed -n 's/^pdf-inspector = {.*version = "=\([^"]*\)".*}$/\1/p' "$MANIFEST")
PATCH_DIGEST=$(shasum -a 256 "$PATCH" | awk '{print $1}')
THIN_FILE=
STRINGS_FILE=

cleanup_temp_files() {
    if [ -n "$THIN_FILE" ]; then
        rm -f "$THIN_FILE"
    fi
    if [ -n "$STRINGS_FILE" ]; then
        rm -f "$STRINGS_FILE"
    fi
}
trap cleanup_temp_files 0
trap 'cleanup_temp_files; exit 1' HUP INT TERM

LOCKED_VERSION=$(awk '
    $0 == "[[package]]" { package = 0 }
    $0 == "name = \"pdf-inspector\"" { package = 1; next }
    package && /^version = "/ {
        sub(/^version = "/, "")
        sub(/"$/, "")
        print
        exit
    }
' "$LOCKFILE")

case "$ENGINE_REVISION" in
    ""|*[!0-9a-f]*)
        echo "ENGINE_REVISION must contain one lowercase 40-character Git revision." >&2
        exit 1
        ;;
esac
[ "${#ENGINE_REVISION}" -eq 40 ] || {
    echo "ENGINE_REVISION must contain one lowercase 40-character Git revision." >&2
    exit 1
}
[ -n "$ENGINE_VERSION" ] || {
    echo "pdf-inspector must use an exact version pin in $MANIFEST" >&2
    exit 1
}
[ "$ENGINE_VERSION" = "$LOCKED_VERSION" ] || {
    echo "pdf-inspector is pinned to $ENGINE_VERSION but Cargo.lock contains $LOCKED_VERSION" >&2
    exit 1
}

grep -Fq -- "- pdf-inspector version: \`$ENGINE_VERSION\`" "$ROOT/Artifacts/BUILD_INFO.md"
grep -Fq -- "- pdf-inspector upstream source revision: \`$ENGINE_REVISION\`" "$ROOT/Artifacts/BUILD_INFO.md"
grep -Fq -- "- Turnip patch SHA-256: \`$PATCH_DIGEST\`" "$ROOT/Artifacts/BUILD_INFO.md"
grep -Fq "pinned to version $ENGINE_VERSION and source commit" "$ROOT/THIRD_PARTY_NOTICES.md"
grep -Fq "\`$ENGINE_REVISION\`" "$ROOT/THIRD_PARTY_NOTICES.md"
grep -Fq 'env!("DOCUMENTKIT_PDF_INSPECTOR_VERSION")' "$RUST_SOURCE"
grep -Fq 'env!("DOCUMENTKIT_PDF_INSPECTOR_REVISION")' "$RUST_SOURCE"
grep -Fq 'documentkit_engine_revision()' "$SWIFT_SOURCE"

test -f "$ARTIFACT/Info.plist"
test -f "$ARTIFACT/macos-arm64_x86_64/libdocumentkit_core.a"
test -f "$ARTIFACT/ios-arm64/libdocumentkit_core-ios.a"
test -f "$ARTIFACT/ios-arm64_x86_64-simulator/libdocumentkit_core.a"

expect_architectures() {
    file=$1
    shift
    output=$(xcrun lipo -info "$file")
    for architecture in "$@"; do
        echo "$output" | grep -q "$architecture"
    done
}

expect_architectures "$ARTIFACT/macos-arm64_x86_64/libdocumentkit_core.a" arm64 x86_64
expect_architectures "$ARTIFACT/ios-arm64/libdocumentkit_core-ios.a" arm64
expect_architectures "$ARTIFACT/ios-arm64_x86_64-simulator/libdocumentkit_core.a" arm64 x86_64

expect_symbols() {
    file=$1
    info=$(xcrun lipo -info "$file")
    if echo "$info" | grep -q "Non-fat file"; then
        for symbol in \
            _documentkit_inspect \
            _documentkit_extract \
            _documentkit_inspect_with_options \
            _documentkit_extract_with_options \
            _documentkit_extract_document \
            _documentkit_extract_document_with_options \
            _documentkit_buffer_free \
            _documentkit_engine_version \
            _documentkit_engine_revision; do
            xcrun nm -gU "$file" 2>/dev/null | awk '{print $NF}' | grep -qx "$symbol"
        done
        return
    fi

    for architecture in arm64 x86_64; do
        if echo "$info" | grep -q "$architecture"; then
            THIN_FILE=$(mktemp "${TMPDIR:-/tmp}/documentkit-symbols.XXXXXX")
            xcrun lipo "$file" -thin "$architecture" -output "$THIN_FILE"
            for symbol in \
                _documentkit_inspect \
                _documentkit_extract \
                _documentkit_inspect_with_options \
                _documentkit_extract_with_options \
                _documentkit_extract_document \
                _documentkit_extract_document_with_options \
                _documentkit_buffer_free \
                _documentkit_engine_version \
                _documentkit_engine_revision; do
                xcrun nm -gU "$THIN_FILE" 2>/dev/null | awk '{print $NF}' | grep -qx "$symbol"
            done
            rm -f "$THIN_FILE"
            THIN_FILE=
        fi
    done
}

expect_symbols "$ARTIFACT/macos-arm64_x86_64/libdocumentkit_core.a"
expect_symbols "$ARTIFACT/ios-arm64/libdocumentkit_core-ios.a"
expect_symbols "$ARTIFACT/ios-arm64_x86_64-simulator/libdocumentkit_core.a"

expect_identity() {
    file=$1
    info=$(xcrun lipo -info "$file")
    if echo "$info" | grep -q "Non-fat file"; then
        if ! strings "$file" | grep -Fqx "pdf-inspector/$ENGINE_VERSION" || \
            ! strings "$file" | grep -Fqx "$ENGINE_REVISION"; then
            echo "Packaged engine identity does not match $ENGINE_VERSION@$ENGINE_REVISION in $file" >&2
            exit 1
        fi
        return
    fi

    for architecture in arm64 x86_64; do
        if echo "$info" | grep -q "$architecture"; then
            THIN_FILE=$(mktemp "${TMPDIR:-/tmp}/documentkit-identity.XXXXXX")
            xcrun lipo "$file" -thin "$architecture" -output "$THIN_FILE"
            if ! strings "$THIN_FILE" | grep -Fqx "pdf-inspector/$ENGINE_VERSION" || \
                ! strings "$THIN_FILE" | grep -Fqx "$ENGINE_REVISION"; then
                echo "Packaged engine identity does not match $ENGINE_VERSION@$ENGINE_REVISION in $file ($architecture)" >&2
                exit 1
            fi
            rm -f "$THIN_FILE"
            THIN_FILE=
        fi
    done
}

expect_identity "$ARTIFACT/macos-arm64_x86_64/libdocumentkit_core.a"
expect_identity "$ARTIFACT/ios-arm64/libdocumentkit_core-ios.a"
expect_identity "$ARTIFACT/ios-arm64_x86_64-simulator/libdocumentkit_core.a"

expect_no_local_build_paths() {
    file=$1
    STRINGS_FILE=$(mktemp "${TMPDIR:-/tmp}/turnip-strings.XXXXXX")
    if ! strings "$file" > "$STRINGS_FILE"; then
        echo "Could not inspect strings in $file." >&2
        exit 1
    fi
    # Rust's prebuilt standard-library objects retain this public toolchain CI path.
    paths=$(grep -Eo '(/Users|/home|/DocBuild)/[^[:space:]]+|/[^[:space:]]*/\.t3/worktrees/[^[:space:]]+|t3code-[0-9a-f]+' "$STRINGS_FILE" |
        grep -Ev '^/Users/runner/work/rust/rust/' || true)
    rm -f "$STRINGS_FILE"
    STRINGS_FILE=
    if [ -n "$paths" ]; then
        echo "Packaged engine contains local build paths in $file:" >&2
        echo "$paths" | sort -u >&2
        exit 1
    fi
}

expect_no_local_build_paths "$ARTIFACT/macos-arm64_x86_64/libdocumentkit_core.a"
expect_no_local_build_paths "$ARTIFACT/ios-arm64/libdocumentkit_core-ios.a"
expect_no_local_build_paths "$ARTIFACT/ios-arm64_x86_64-simulator/libdocumentkit_core.a"

for headers in "$ARTIFACT"/*/Headers; do
    test -f "$headers/DocumentKitCore.h"
    test -f "$headers/module.modulemap"
    cmp -s "$ROOT/Native/DocumentKitCore/include/DocumentKitCore.h" \
        "$headers/DocumentKitCore.h"
    cmp -s "$ROOT/Native/DocumentKitCore/include/module.modulemap" \
        "$headers/module.modulemap"
done

for key in macos ios; do
    plutil -extract AvailableLibraries json -o - "$ARTIFACT/Info.plist" | grep -q "\"$key\""
done

echo "Verified DocumentKitCore.xcframework"
