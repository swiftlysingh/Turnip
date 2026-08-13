#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ARTIFACT="$ROOT/Artifacts/DocumentKitCore.xcframework"

(cd "$ROOT" && shasum -a 256 -c Artifacts/SHA256SUMS)

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
            _documentkit_buffer_free \
            _documentkit_engine_version; do
            xcrun nm -gU "$file" 2>/dev/null | awk '{print $NF}' | grep -qx "$symbol"
        done
        return
    fi

    for architecture in arm64 x86_64; do
        if echo "$info" | grep -q "$architecture"; then
            thin=$(mktemp "${TMPDIR:-/tmp}/documentkit-symbols.XXXXXX")
            xcrun lipo "$file" -thin "$architecture" -output "$thin"
            for symbol in \
                _documentkit_inspect \
                _documentkit_extract \
                _documentkit_inspect_with_options \
                _documentkit_extract_with_options \
                _documentkit_buffer_free \
                _documentkit_engine_version; do
                xcrun nm -gU "$thin" 2>/dev/null | awk '{print $NF}' | grep -qx "$symbol"
            done
            rm -f "$thin"
        fi
    done
}

expect_symbols "$ARTIFACT/macos-arm64_x86_64/libdocumentkit_core.a"
expect_symbols "$ARTIFACT/ios-arm64/libdocumentkit_core-ios.a"
expect_symbols "$ARTIFACT/ios-arm64_x86_64-simulator/libdocumentkit_core.a"

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
