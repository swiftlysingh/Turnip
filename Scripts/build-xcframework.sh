#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST="$ROOT/Native/DocumentKitCore/Cargo.toml"
HEADERS="$ROOT/Native/DocumentKitCore/include"
EXPORTS="$ROOT/Native/DocumentKitCore/exports.txt"
OUTPUT="$ROOT/Artifacts/DocumentKitCore.xcframework"
ZIP_OUTPUT=
INCLUDE_X86_64=${DOCUMENTKIT_INCLUDE_X86_64:-0}
BUILD="$ROOT/Build/DocumentKitCore"

usage() {
    cat <<'EOF' >&2
Usage: Scripts/build-xcframework.sh [--include-x86-64] [--output <path>] [--zip <path>]

Options:
  --include-x86-64   Also build Intel x86_64 macOS and iOS Simulator slices
                     (defaults to arm64-only: macOS, iOS device, iOS Simulator).
  --output <path>    Destination path for DocumentKitCore.xcframework
                     (default: Artifacts/DocumentKitCore.xcframework).
  --zip <path>       Also create a SwiftPM-ready zip archive at <path> and
                     print its SHA-256 checksum.
EOF
    exit 64
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --include-x86-64)
            INCLUDE_X86_64=1
            shift
            ;;
        --output)
            [ "$#" -ge 2 ] || usage
            OUTPUT=$2
            shift 2
            ;;
        --zip)
            [ "$#" -ge 2 ] || usage
            ZIP_OUTPUT=$2
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

case "$INCLUDE_X86_64" in
    0|1) ;;
    *)
        echo "DOCUMENTKIT_INCLUDE_X86_64 must be 0 or 1." >&2
        exit 64
        ;;
esac

test -f "$EXPORTS"

STAGED_OUTPUT="$BUILD/DocumentKitCore.xcframework"
DOCUMENTKIT_RUST_TOOLCHAIN=$(rustup show active-toolchain | awk 'NR == 1 { print $1 }')
DOCUMENTKIT_CARGO=$(rustup which --toolchain "$DOCUMENTKIT_RUST_TOOLCHAIN" cargo)
DOCUMENTKIT_RUSTC=$(rustup which --toolchain "$DOCUMENTKIT_RUST_TOOLCHAIN" rustc)
DOCUMENTKIT_CARGO_HOME=${CARGO_HOME:-$HOME/.cargo}
DOCUMENTKIT_RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=$HOME=/BuildUser --remap-path-prefix=$DOCUMENTKIT_CARGO_HOME=/Cargo --remap-path-prefix=$ROOT=/DocumentKit"

if [ "$INCLUDE_X86_64" = 1 ]; then
    installed_targets=$(rustup target list --toolchain "$DOCUMENTKIT_RUST_TOOLCHAIN" --installed)
    for target in x86_64-apple-darwin x86_64-apple-ios; do
        if ! printf '%s\n' "$installed_targets" | grep -qx "$target"; then
            echo "Missing Rust target $target for --include-x86-64. Install it with:" >&2
            echo "  rustup target add --toolchain $DOCUMENTKIT_RUST_TOOLCHAIN $target" >&2
            exit 1
        fi
    done
fi

"$ROOT/Scripts/prepare-engine.sh"

MACOS_SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
IOS_SDK_VERSION=$(xcrun --sdk iphoneos --show-sdk-version)
IOS_SIM_SDK_VERSION=$(xcrun --sdk iphonesimulator --show-sdk-version)

prelink_thin_archive() {
    raw_archive=$1
    destination=$2
    arch=$3
    ld_platform=$4
    min_os=$5
    sdk_version=$6
    merged_object="$BUILD/prelink/$ld_platform-$arch.o"

    mkdir -p "$(dirname "$merged_object")" "$(dirname "$destination")"

    # Cargo ignores `strip` for staticlib crates, leaving unstripped Rust stdlib
    # __DWARF debug info and dead __LLVM,__bitcode sections in archive members.
    xcrun strip -S "$raw_archive"

    # Pre-link only reachable archive members into a single relocatable object
    # and localize every symbol outside Native/DocumentKitCore/exports.txt.
    # Keep `_rust_eh_personality` external during `ld -r -S -x` so `__eh_frame`
    # `PTRTGOT` relocations retain an external symbol on Xcode 26.4, then mark
    # `_rust_eh_personality` private external with `nmedit -p` (matching Rust's
    # original visibility) so only the 9 `_documentkit_*` symbols stay exported.
    prelink_exports="$BUILD/prelink/$ld_platform-$arch.exports"
    {
        awk '!/^[[:space:]]*(#|$)/ { print $1 }' "$EXPORTS"
        printf '_rust_eh_personality\n'
    } > "$prelink_exports"

    set --
    while IFS= read -r symbol || [ -n "$symbol" ]; do
        case "$symbol" in
            ""|\#*) continue ;;
        esac
        set -- "$@" -u "$symbol"
    done < "$EXPORTS"

    xcrun ld -r -S -x \
        -arch "$arch" \
        -platform_version "$ld_platform" "$min_os" "$sdk_version" \
        -exported_symbols_list "$prelink_exports" \
        "$@" \
        "$raw_archive" \
        -o "$merged_object"

    xcrun nmedit -s "$EXPORTS" -p "$merged_object"
    xcrun libtool -static -D -o "$destination" "$merged_object"
    rm -f "$merged_object" "$prelink_exports"
}

build_target() {
    target=$1
    destination=$2
    arch=$3
    ld_platform=$4
    min_os=$5
    sdk_version=$6
    target_dir="$BUILD/cargo/$target"

    IPHONEOS_DEPLOYMENT_TARGET=16.0 \
        MACOSX_DEPLOYMENT_TARGET=13.0 \
        CARGO_TARGET_DIR="$target_dir" \
        RUSTFLAGS="$DOCUMENTKIT_RUSTFLAGS" \
        "$DOCUMENTKIT_CARGO" build --config "build.rustc = '$DOCUMENTKIT_RUSTC'" \
            --locked --release --manifest-path "$MANIFEST" --target "$target"

    raw_copy="$BUILD/raw/$ld_platform-$arch.a"
    mkdir -p "$(dirname "$raw_copy")"
    cp "$target_dir/$target/release/libdocumentkit_core.a" "$raw_copy"
    rm -rf -- "$target_dir"

    prelink_thin_archive "$raw_copy" "$destination" "$arch" "$ld_platform" "$min_os" "$sdk_version"
    rm -f "$raw_copy"
}

make_universal() {
    output=$1
    shift
    mkdir -p "$(dirname "$output")"
    xcrun lipo -create "$@" -output "$output"
}

rm -rf -- "$ROOT/Native/DocumentKitCore/target" "$BUILD"
mkdir -p "$BUILD"

build_target aarch64-apple-darwin "$BUILD/slices/macos-arm64.a" arm64 macos 13.0 "$MACOS_SDK_VERSION"
build_target aarch64-apple-ios "$BUILD/slices/ios-arm64.a" arm64 ios 16.0 "$IOS_SDK_VERSION"
build_target aarch64-apple-ios-sim "$BUILD/slices/ios-simulator-arm64.a" arm64 ios-simulator 16.0 "$IOS_SIM_SDK_VERSION"

mkdir -p "$BUILD/macos" "$BUILD/ios" "$BUILD/ios-simulator"
cp "$BUILD/slices/ios-arm64.a" "$BUILD/ios/libdocumentkit_core.a"

if [ "$INCLUDE_X86_64" = 1 ]; then
    build_target x86_64-apple-darwin "$BUILD/slices/macos-x86_64.a" x86_64 macos 13.0 "$MACOS_SDK_VERSION"
    build_target x86_64-apple-ios "$BUILD/slices/ios-simulator-x86_64.a" x86_64 ios-simulator 16.0 "$IOS_SIM_SDK_VERSION"

    make_universal "$BUILD/macos/libdocumentkit_core.a" \
        "$BUILD/slices/macos-arm64.a" \
        "$BUILD/slices/macos-x86_64.a"
    make_universal "$BUILD/ios-simulator/libdocumentkit_core.a" \
        "$BUILD/slices/ios-simulator-arm64.a" \
        "$BUILD/slices/ios-simulator-x86_64.a"
else
    cp "$BUILD/slices/macos-arm64.a" "$BUILD/macos/libdocumentkit_core.a"
    cp "$BUILD/slices/ios-simulator-arm64.a" "$BUILD/ios-simulator/libdocumentkit_core.a"
fi

xcodebuild -create-xcframework \
    -library "$BUILD/macos/libdocumentkit_core.a" -headers "$HEADERS" \
    -library "$BUILD/ios/libdocumentkit_core.a" -headers "$HEADERS" \
    -library "$BUILD/ios-simulator/libdocumentkit_core.a" -headers "$HEADERS" \
    -output "$STAGED_OUTPUT"

mkdir -p "$(dirname "$OUTPUT")"
rm -rf -- "$OUTPUT"
mv "$STAGED_OUTPUT" "$OUTPUT"

if [ "$INCLUDE_X86_64" = 1 ]; then
    "$ROOT/Scripts/verify-artifact.sh" --include-x86-64 --artifact "$OUTPUT"
else
    "$ROOT/Scripts/verify-artifact.sh" --artifact "$OUTPUT"
fi

echo "Created $OUTPUT"

if [ -n "$ZIP_OUTPUT" ]; then
    mkdir -p "$(dirname "$ZIP_OUTPUT")"
    rm -f -- "$ZIP_OUTPUT"
    ditto -c -k --sequesterRsrc --keepParent "$OUTPUT" "$ZIP_OUTPUT"
    checksum=$(swift package compute-checksum "$ZIP_OUTPUT")
    echo "Created $ZIP_OUTPUT"
    echo "SHA-256 checksum: $checksum"
fi
