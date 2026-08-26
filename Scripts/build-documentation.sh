#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <output.doccarchive>" >&2
    exit 64
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=$1
CATALOG="$ROOT/Sources/Turnip/Turnip.docc"
HOSTING_BASE_PATH=${TURNIP_DOCC_HOSTING_BASE_PATH:-/Turnip}

case "$HOSTING_BASE_PATH" in
    /*) ;;
    *)
        echo "TURNIP_DOCC_HOSTING_BASE_PATH must begin with /." >&2
        exit 64
        ;;
esac

if [ -e "$OUTPUT" ]; then
    echo "Refusing to overwrite existing documentation output: $OUTPUT" >&2
    exit 1
fi

test -d "$CATALOG"
mkdir -p "$(dirname -- "$OUTPUT")"

TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/turnip-docc.XXXXXX")
SYMBOL_GRAPHS="$TEMP_ROOT/symbol-graphs"
MACOS_SYMBOL_GRAPHS="$TEMP_ROOT/macos-symbol-graphs"
IOS_SYMBOL_GRAPHS="$TEMP_ROOT/ios-symbol-graphs"
MACOS_SWIFTPM_SCRATCH="$TEMP_ROOT/macos-swiftpm"
IOS_SWIFTPM_SCRATCH="$TEMP_ROOT/ios-swiftpm"
MACOS_CLANG_MODULE_CACHE="$TEMP_ROOT/macos-clang-module-cache"
IOS_CLANG_MODULE_CACHE="$TEMP_ROOT/ios-clang-module-cache"
STAGED_OUTPUT="$TEMP_ROOT/Turnip.doccarchive"

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
    --target Turnip \
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
    --target Turnip \
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

test -f "$MACOS_SYMBOL_GRAPHS/Turnip.symbols.json"
test -f "$IOS_SYMBOL_GRAPHS/Turnip.symbols.json"
cp "$MACOS_SYMBOL_GRAPHS/Turnip.symbols.json" "$SYMBOL_GRAPHS/Turnip.macos.symbols.json"
cp "$IOS_SYMBOL_GRAPHS/Turnip.symbols.json" "$SYMBOL_GRAPHS/Turnip.ios.symbols.json"

xcrun docc convert "$CATALOG" \
    --additional-symbol-graph-dir "$SYMBOL_GRAPHS" \
    --output-path "$STAGED_OUTPUT" \
    --fallback-bundle-identifier com.swiftlysingh.turnip \
    --fallback-display-name Turnip \
    --fallback-default-module-kind Framework \
    --default-code-listing-language swift \
    --platform name=iOS,version=16.0 \
    --platform name=macOS,version=13.0 \
    --checkout-path "$ROOT" \
    --source-service github \
    --source-service-base-url https://github.com/swiftlysingh/Turnip/blob/main \
    --hosting-base-path "$HOSTING_BASE_PATH" \
    --transform-for-static-hosting \
    --warnings-as-errors

test -f "$STAGED_OUTPUT/index.html"
test -d "$STAGED_OUTPUT/documentation/turnip"

# DocC's router has no route for the archive root, so visitors landing on the
# base URL see "The page you're looking for can't be found". Replace the root
# shell with a redirect to the framework's landing page.
LANDING_PAGE="documentation/turnip/"
cat > "$STAGED_OUTPUT/index.html" <<HTML
<!doctype html>
<html lang="en-US">
<head>
    <meta charset="utf-8">
    <title>Turnip Documentation</title>
    <meta http-equiv="refresh" content="0; url=$LANDING_PAGE">
    <script>window.location.replace("$LANDING_PAGE");</script>
</head>
<body></body>
</html>
HTML

mv "$STAGED_OUTPUT" "$OUTPUT"

echo "Created $OUTPUT"
