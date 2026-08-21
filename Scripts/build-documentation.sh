#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <output.doccarchive>" >&2
    exit 64
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=$1
CATALOG="$ROOT/Sources/DocumentKit/DocumentKit.docc"
HOSTING_BASE_PATH=${DOCUMENTKIT_DOCC_HOSTING_BASE_PATH:-/DocumentKit}

case "$HOSTING_BASE_PATH" in
    /*) ;;
    *)
        echo "DOCUMENTKIT_DOCC_HOSTING_BASE_PATH must begin with /." >&2
        exit 64
        ;;
esac

if [ -e "$OUTPUT" ]; then
    echo "Refusing to overwrite existing documentation output: $OUTPUT" >&2
    exit 1
fi

test -d "$CATALOG"
mkdir -p "$(dirname -- "$OUTPUT")"

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/documentkit-docc.XXXXXX")
SYMBOL_GRAPHS="$TEMP_ROOT/symbol-graphs"
MACOS_SYMBOL_GRAPHS="$TEMP_ROOT/macos-symbol-graphs"
IOS_SYMBOL_GRAPHS="$TEMP_ROOT/ios-symbol-graphs"
MACOS_SWIFTPM_SCRATCH="$TEMP_ROOT/macos-swiftpm"
IOS_SWIFTPM_SCRATCH="$TEMP_ROOT/ios-swiftpm"
MACOS_CLANG_MODULE_CACHE="$TEMP_ROOT/macos-clang-module-cache"
IOS_CLANG_MODULE_CACHE="$TEMP_ROOT/ios-clang-module-cache"
STAGED_OUTPUT="$TEMP_ROOT/DocumentKit.doccarchive"

cleanup() {
    rm -rf -- "$TEMP_ROOT"
}
trap cleanup 0
trap 'cleanup; exit 1' HUP INT TERM

mkdir -p \
    "$SYMBOL_GRAPHS" \
    "$MACOS_SYMBOL_GRAPHS" \
    "$IOS_SYMBOL_GRAPHS" \
    "$MACOS_SWIFTPM_SCRATCH" \
    "$IOS_SWIFTPM_SCRATCH" \
    "$MACOS_CLANG_MODULE_CACHE" \
    "$IOS_CLANG_MODULE_CACHE"

CLANG_MODULE_CACHE_PATH="$MACOS_CLANG_MODULE_CACHE" swift build \
    --package-path "$ROOT" \
    --scratch-path "$MACOS_SWIFTPM_SCRATCH" \
    --target DocumentKit \
    -Xswiftc -emit-symbol-graph \
    -Xswiftc -emit-symbol-graph-dir \
    -Xswiftc "$MACOS_SYMBOL_GRAPHS" \
    -Xswiftc -symbol-graph-minimum-access-level \
    -Xswiftc public \
    -Xswiftc -symbol-graph-skip-synthesized-members \
    -Xswiftc -symbol-graph-skip-inherited-docs \
    -Xswiftc -omit-extension-block-symbols \
    --configuration debug

IOS_SIMULATOR_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)

CLANG_MODULE_CACHE_PATH="$IOS_CLANG_MODULE_CACHE" swift build \
    --package-path "$ROOT" \
    --scratch-path "$IOS_SWIFTPM_SCRATCH" \
    --target DocumentKit \
    --triple arm64-apple-ios16.0-simulator \
    --sdk "$IOS_SIMULATOR_SDK" \
    -Xswiftc -emit-symbol-graph \
    -Xswiftc -emit-symbol-graph-dir \
    -Xswiftc "$IOS_SYMBOL_GRAPHS" \
    -Xswiftc -symbol-graph-minimum-access-level \
    -Xswiftc public \
    -Xswiftc -symbol-graph-skip-synthesized-members \
    -Xswiftc -symbol-graph-skip-inherited-docs \
    -Xswiftc -omit-extension-block-symbols \
    --configuration debug

test -f "$MACOS_SYMBOL_GRAPHS/DocumentKit.symbols.json"
test -f "$IOS_SYMBOL_GRAPHS/DocumentKit.symbols.json"
cp "$MACOS_SYMBOL_GRAPHS/DocumentKit.symbols.json" "$SYMBOL_GRAPHS/DocumentKit.macos.symbols.json"
cp "$IOS_SYMBOL_GRAPHS/DocumentKit.symbols.json" "$SYMBOL_GRAPHS/DocumentKit.ios.symbols.json"

xcrun docc convert "$CATALOG" \
    --additional-symbol-graph-dir "$SYMBOL_GRAPHS" \
    --output-path "$STAGED_OUTPUT" \
    --fallback-bundle-identifier com.swiftlysingh.documentkit \
    --fallback-display-name DocumentKit \
    --fallback-default-module-kind Framework \
    --default-code-listing-language swift \
    --platform name=iOS,version=16.0 \
    --platform name=macOS,version=13.0 \
    --checkout-path "$ROOT" \
    --source-service github \
    --source-service-base-url https://github.com/swiftlysingh/DocumentKit/blob/main \
    --hosting-base-path "$HOSTING_BASE_PATH" \
    --transform-for-static-hosting \
    --warnings-as-errors

test -f "$STAGED_OUTPUT/index.html"
test -d "$STAGED_OUTPUT/documentation/documentkit"
mv "$STAGED_OUTPUT" "$OUTPUT"

echo "Created $OUTPUT"
