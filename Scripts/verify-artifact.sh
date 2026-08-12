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
