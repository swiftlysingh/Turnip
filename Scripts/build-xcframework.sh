#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST="$ROOT/Native/DocumentKitCore/Cargo.toml"
HEADERS="$ROOT/Native/DocumentKitCore/include"
OUTPUT="$ROOT/Artifacts/DocumentKitCore.xcframework"
BUILD="$ROOT/Build/DocumentKitCore"
STAGED_OUTPUT="$BUILD/DocumentKitCore.xcframework"
DOCUMENTKIT_RUST_TOOLCHAIN=$(rustup show active-toolchain | awk 'NR == 1 { print $1 }')
DOCUMENTKIT_CARGO=$(rustup which --toolchain "$DOCUMENTKIT_RUST_TOOLCHAIN" cargo)
DOCUMENTKIT_RUSTC=$(rustup which --toolchain "$DOCUMENTKIT_RUST_TOOLCHAIN" rustc)
DOCUMENTKIT_CARGO_HOME=${CARGO_HOME:-$HOME/.cargo}
DOCUMENTKIT_RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=$HOME=/BuildUser --remap-path-prefix=$DOCUMENTKIT_CARGO_HOME=/Cargo --remap-path-prefix=$ROOT=/DocumentKit"

"$ROOT/Scripts/prepare-engine.sh"

build_target() {
    target=$1
    destination=$2
    target_dir="$BUILD/cargo/$target"

    IPHONEOS_DEPLOYMENT_TARGET=16.0 \
        MACOSX_DEPLOYMENT_TARGET=13.0 \
        CARGO_TARGET_DIR="$target_dir" \
        RUSTFLAGS="$DOCUMENTKIT_RUSTFLAGS" \
        "$DOCUMENTKIT_CARGO" build --config "build.rustc = '$DOCUMENTKIT_RUSTC'" \
            --locked --release --manifest-path "$MANIFEST" --target "$target"
    mkdir -p "$(dirname "$destination")"
    cp "$target_dir/$target/release/libdocumentkit_core.a" "$destination"
    rm -rf -- "$target_dir"
}

make_universal() {
    output=$1
    shift
    mkdir -p "$(dirname "$output")"
    xcrun lipo -create "$@" -output "$output"
}

rm -rf -- "$ROOT/Native/DocumentKitCore/target" "$BUILD"
mkdir -p "$BUILD"

build_target aarch64-apple-darwin "$BUILD/slices/macos-arm64.a"
build_target x86_64-apple-darwin "$BUILD/slices/macos-x86_64.a"
build_target aarch64-apple-ios "$BUILD/slices/ios-arm64.a"
build_target aarch64-apple-ios-sim "$BUILD/slices/ios-simulator-arm64.a"
build_target x86_64-apple-ios "$BUILD/slices/ios-simulator-x86_64.a"

make_universal "$BUILD/macos/libdocumentkit_core.a" \
    "$BUILD/slices/macos-arm64.a" \
    "$BUILD/slices/macos-x86_64.a"
cp "$BUILD/slices/ios-arm64.a" "$BUILD/libdocumentkit_core-ios.a"
make_universal "$BUILD/ios-simulator/libdocumentkit_core.a" \
    "$BUILD/slices/ios-simulator-arm64.a" \
    "$BUILD/slices/ios-simulator-x86_64.a"

xcodebuild -create-xcframework \
    -library "$BUILD/macos/libdocumentkit_core.a" -headers "$HEADERS" \
    -library "$BUILD/libdocumentkit_core-ios.a" -headers "$HEADERS" \
    -library "$BUILD/ios-simulator/libdocumentkit_core.a" -headers "$HEADERS" \
    -output "$STAGED_OUTPUT"

rm -rf -- "$OUTPUT"
mv "$STAGED_OUTPUT" "$OUTPUT"

(cd "$ROOT" && shasum -a 256 \
    ENGINE_REVISION \
    rust-toolchain.toml \
    Patches/pdf-inspector-embed-apple-cmaps.patch \
    Scripts/build-xcframework.sh \
    Scripts/prepare-engine.sh \
    Native/DocumentKitCore/Cargo.toml \
    Native/DocumentKitCore/Cargo.lock \
    Native/DocumentKitCore/build.rs \
    Native/DocumentKitCore/src/lib.rs \
    Native/DocumentKitCore/include/DocumentKitCore.h \
    Artifacts/BUILD_INFO.md \
    Artifacts/DocumentKitCore.xcframework/macos-arm64_x86_64/libdocumentkit_core.a \
    Artifacts/DocumentKitCore.xcframework/ios-arm64/libdocumentkit_core-ios.a \
    Artifacts/DocumentKitCore.xcframework/ios-arm64_x86_64-simulator/libdocumentkit_core.a \
    > Artifacts/SHA256SUMS)

"$ROOT/Scripts/verify-artifact.sh"
echo "Created $OUTPUT"
