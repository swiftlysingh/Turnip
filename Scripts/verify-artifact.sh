#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ARTIFACT="${TURNIP_LOCAL_XCFRAMEWORK_PATH:-$ROOT/Artifacts/DocumentKitCore.xcframework}"
INCLUDE_X86_64=0
MANIFEST="$ROOT/Native/DocumentKitCore/Cargo.toml"
LOCKFILE="$ROOT/Native/DocumentKitCore/Cargo.lock"
EXPORTS="$ROOT/Native/DocumentKitCore/exports.txt"
RUST_SOURCE="$ROOT/Native/DocumentKitCore/src/lib.rs"
SWIFT_SOURCE="$ROOT/Sources/Turnip/Turnip.swift"
ENGINE_REVISION=$(tr -d '[:space:]' < "$ROOT/ENGINE_REVISION")
ENGINE_VERSION=$(sed -n 's/^pdf-inspector = {.*version = "=\([^"]*\)".*}$/\1/p' "$MANIFEST")
THIN_FILE=
STRINGS_FILE=
EXPECTED_EXPORTS_FILE=
ACTUAL_EXPORTS_FILE=

usage() {
    cat <<'EOF' >&2
Usage: Scripts/verify-artifact.sh [--include-x86-64] [--artifact <path>]
EOF
    exit 64
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --include-x86-64)
            INCLUDE_X86_64=1
            shift
            ;;
        --artifact)
            [ "$#" -ge 2 ] || usage
            ARTIFACT=$2
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

cleanup_temp_files() {
    if [ -n "$THIN_FILE" ]; then
        rm -f "$THIN_FILE"
    fi
    if [ -n "$STRINGS_FILE" ]; then
        rm -f "$STRINGS_FILE"
    fi
    if [ -n "$EXPECTED_EXPORTS_FILE" ]; then
        rm -f "$EXPECTED_EXPORTS_FILE"
    fi
    if [ -n "$ACTUAL_EXPORTS_FILE" ]; then
        rm -f "$ACTUAL_EXPORTS_FILE"
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

test -f "$EXPORTS"
EXPECTED_EXPORTS_FILE=$(mktemp "${TMPDIR:-/tmp}/documentkit-expected-exports.XXXXXX")
ACTUAL_EXPORTS_FILE=$(mktemp "${TMPDIR:-/tmp}/documentkit-actual-exports.XXXXXX")
awk '!/^[[:space:]]*(#|$)/ { print $1 }' "$EXPORTS" | LC_ALL=C sort -u > "$EXPECTED_EXPORTS_FILE"
[ -s "$EXPECTED_EXPORTS_FILE" ] || {
    echo "Exported symbol list $EXPORTS is empty." >&2
    exit 1
}

grep -Fq -- "- pdf-inspector version: \`$ENGINE_VERSION\`" "$ROOT/Artifacts/BUILD_INFO.md"
grep -Fq -- "- pdf-inspector upstream source revision: \`$ENGINE_REVISION\`" "$ROOT/Artifacts/BUILD_INFO.md"
grep -Fq "pinned to version $ENGINE_VERSION and source commit" "$ROOT/THIRD_PARTY_NOTICES.md"
grep -Fq "\`$ENGINE_REVISION\`" "$ROOT/THIRD_PARTY_NOTICES.md"
grep -Fq 'env!("DOCUMENTKIT_PDF_INSPECTOR_VERSION")' "$RUST_SOURCE"
grep -Fq 'env!("DOCUMENTKIT_PDF_INSPECTOR_REVISION")' "$RUST_SOURCE"
grep -Fq 'documentkit_engine_revision()' "$SWIFT_SOURCE"

test -f "$ARTIFACT/Info.plist"

if [ "$INCLUDE_X86_64" = 1 ]; then
    MACOS_SLICE="$ARTIFACT/macos-arm64_x86_64/libdocumentkit_core.a"
    IOS_SLICE="$ARTIFACT/ios-arm64/libdocumentkit_core.a"
    IOS_SIM_SLICE="$ARTIFACT/ios-arm64_x86_64-simulator/libdocumentkit_core.a"
    MACOS_ARCHS="arm64 x86_64"
    IOS_SIM_ARCHS="arm64 x86_64"
else
    MACOS_SLICE="$ARTIFACT/macos-arm64/libdocumentkit_core.a"
    IOS_SLICE="$ARTIFACT/ios-arm64/libdocumentkit_core.a"
    IOS_SIM_SLICE="$ARTIFACT/ios-arm64-simulator/libdocumentkit_core.a"
    MACOS_ARCHS="arm64"
    IOS_SIM_ARCHS="arm64"
fi

test -f "$MACOS_SLICE"
test -f "$IOS_SLICE"
test -f "$IOS_SIM_SLICE"

expect_architectures() {
    file=$1
    expected=$2
    actual=$(xcrun lipo -archs "$file" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
    want=$(printf '%s\n' $expected | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
    if [ "$actual" != "$want" ]; then
        echo "Unexpected architectures in $file: got '$actual', expected '$want'." >&2
        exit 1
    fi
}

expect_architectures "$MACOS_SLICE" "$MACOS_ARCHS"
expect_architectures "$IOS_SLICE" "arm64"
expect_architectures "$IOS_SIM_SLICE" "$IOS_SIM_ARCHS"

verify_thin_slice() {
    thin_file=$1
    label=$2

    # 1. Single-object pre-linked static archive (one .o member, excluding __.SYMDEF*).
    member_count=$(ar t "$thin_file" | awk '!/^__\.SYMDEF/ && NF > 0 { count++ } END { print count + 0 }')
    if [ "$member_count" -ne 1 ]; then
        echo "Expected 1 object member in $label, found $member_count." >&2
        exit 1
    fi

    # 2. Zero __DWARF and zero __LLVM sections (verified via otool -l and size -m).
    bad_sections=$(xcrun otool -l "$thin_file" | grep -E 'segname __(DWARF|LLVM)([[:space:]]|$)' || true)
    if [ -n "$bad_sections" ]; then
        echo "Found unstripped __DWARF or __LLVM segment in $label:" >&2
        echo "$bad_sections" >&2
        exit 1
    fi
    bad_size_sections=$(xcrun size -m "$thin_file" | grep -E 'Section \(__(DWARF|LLVM),' || true)
    if [ -n "$bad_size_sections" ]; then
        echo "Found unstripped __DWARF or __LLVM section in $label:" >&2
        echo "$bad_size_sections" >&2
        exit 1
    fi

    # 3. Exact exported global symbol set (no missing symbols, zero leaked symbols).
    (xcrun nm -gU "$thin_file" 2>/dev/null || true) |
        awk 'NF >= 3 && $2 ~ /^[TDSBCAI]$/ { print $3 }' |
        LC_ALL=C sort -u > "$ACTUAL_EXPORTS_FILE"
    if ! cmp -s "$EXPECTED_EXPORTS_FILE" "$ACTUAL_EXPORTS_FILE"; then
        echo "Exported global symbols in $label do not match $EXPORTS:" >&2
        diff -u "$EXPECTED_EXPORTS_FILE" "$ACTUAL_EXPORTS_FILE" >&2 || true
        exit 1
    fi

    # 4. Embedded engine identity (version and exact upstream revision).
    STRINGS_FILE=$(mktemp "${TMPDIR:-/tmp}/turnip-strings.XXXXXX")
    if ! strings "$thin_file" > "$STRINGS_FILE"; then
        echo "Could not inspect strings in $label." >&2
        exit 1
    fi
    if ! grep -Fqx "pdf-inspector/$ENGINE_VERSION" "$STRINGS_FILE" || \
        ! grep -Fqx "$ENGINE_REVISION" "$STRINGS_FILE"; then
        echo "Packaged engine identity does not match $ENGINE_VERSION@$ENGINE_REVISION in $label." >&2
        exit 1
    fi

    # 5. Zero local build paths.
    # Rust's prebuilt standard-library objects retain this public toolchain CI path.
    paths=$(grep -Eo '(/Users|/home|/DocBuild)/[^[:space:]]+|/[^[:space:]]*/\.t3/worktrees/[^[:space:]]+|t3code-[0-9a-f]+' "$STRINGS_FILE" |
        grep -Ev '^/Users/runner/work/rust/rust/' || true)
    rm -f "$STRINGS_FILE"
    STRINGS_FILE=
    if [ -n "$paths" ]; then
        echo "Packaged engine contains local build paths in $label:" >&2
        echo "$paths" | sort -u >&2
        exit 1
    fi
}

verify_slice() {
    file=$1
    info=$(xcrun lipo -info "$file")
    if echo "$info" | grep -q "Non-fat file"; then
        verify_thin_slice "$file" "$file"
        return
    fi

    for architecture in $(xcrun lipo -archs "$file"); do
        THIN_FILE=$(mktemp "${TMPDIR:-/tmp}/documentkit-thin.XXXXXX")
        xcrun lipo "$file" -thin "$architecture" -output "$THIN_FILE"
        verify_thin_slice "$THIN_FILE" "$file ($architecture)"
        rm -f "$THIN_FILE"
        THIN_FILE=
    done
}

verify_slice "$MACOS_SLICE"
verify_slice "$IOS_SLICE"
verify_slice "$IOS_SIM_SLICE"

slice_count=0
for headers in "$ARTIFACT"/*/Headers; do
    slice_count=$((slice_count + 1))
    test -f "$headers/DocumentKitCore.h"
    test -f "$headers/module.modulemap"
    cmp -s "$ROOT/Native/DocumentKitCore/include/DocumentKitCore.h" \
        "$headers/DocumentKitCore.h"
    cmp -s "$ROOT/Native/DocumentKitCore/include/module.modulemap" \
        "$headers/module.modulemap"
done
[ "$slice_count" -eq 3 ] || {
    echo "Expected 3 XCFramework slices, found $slice_count." >&2
    exit 1
}

available_libraries=$(plutil -extract AvailableLibraries json -o - "$ARTIFACT/Info.plist")
for key in '"macos"' '"ios"' '"simulator"'; do
    printf '%s\n' "$available_libraries" | grep -Fq "$key"
done

echo "Verified DocumentKitCore.xcframework"
