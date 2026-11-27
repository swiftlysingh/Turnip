#!/bin/bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ARTIFACT="${TURNIP_LOCAL_XCFRAMEWORK_PATH:-$ROOT/Artifacts/DocumentKitCore.xcframework}"
FIXTURE=$(mktemp -d "${TMPDIR:-/tmp}/turnip-artifact-tooling.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT

# 1. Verify set-release-artifact.sh updates Package.swift and swift package dump-package
#    resolves remote url+checksum by default and honors local override env vars.
PKG_COPY="$FIXTURE/pkg"
mkdir -p "$PKG_COPY/Sources/Turnip" "$PKG_COPY/Tests/TurnipTests"
cp "$ROOT/Package.swift" "$PKG_COPY/Package.swift"
printf '%s\n' 'public enum TurnipStub {}' > "$PKG_COPY/Sources/Turnip/Stub.swift"
printf '%s\n' '' > "$PKG_COPY/Tests/TurnipTests/Stub.swift"

TEST_VERSION="0.4.0"
TEST_CHECKSUM="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
EXPECTED_URL="https://github.com/swiftlysingh/Turnip/releases/download/v$TEST_VERSION/DocumentKitCore-$TEST_VERSION.xcframework.zip"

"$ROOT/Scripts/set-release-artifact.sh" --manifest "$PKG_COPY/Package.swift" "$TEST_VERSION" "$TEST_CHECKSUM"

dump_remote=$(env -u TURNIP_USE_LOCAL_XCFRAMEWORK -u TURNIP_LOCAL_XCFRAMEWORK_PATH \
    swift package --package-path "$PKG_COPY" dump-package)
jq -e --arg url "$EXPECTED_URL" --arg checksum "$TEST_CHECKSUM" '
    .targets[]
    | select(.name == "DocumentKitCore")
    | .type == "binary" and .url == $url and .checksum == $checksum
' <<< "$dump_remote" >/dev/null
echo "PASS remote-binary-target"

dump_local_flag=$(env -u TURNIP_LOCAL_XCFRAMEWORK_PATH TURNIP_USE_LOCAL_XCFRAMEWORK=1 \
    swift package --package-path "$PKG_COPY" dump-package)
jq -e '
    .targets[]
    | select(.name == "DocumentKitCore")
    | .type == "binary" and .path == "Artifacts/DocumentKitCore.xcframework" and (.url == null)
' <<< "$dump_local_flag" >/dev/null
echo "PASS local-flag-override"

dump_local_path=$(env -u TURNIP_USE_LOCAL_XCFRAMEWORK TURNIP_LOCAL_XCFRAMEWORK_PATH="Build/custom-doc.xcframework" \
    swift package --package-path "$PKG_COPY" dump-package)
jq -e '
    .targets[]
    | select(.name == "DocumentKitCore")
    | .type == "binary" and .path == "Build/custom-doc.xcframework" and (.url == null)
' <<< "$dump_local_path" >/dev/null
echo "PASS local-path-override"

# Reject invalid version or checksum inputs.
if "$ROOT/Scripts/set-release-artifact.sh" --manifest "$PKG_COPY/Package.swift" "v0.4.0" "$TEST_CHECKSUM" >/dev/null 2>&1; then
    echo "Expected set-release-artifact.sh to reject leading v in version" >&2
    exit 1
fi
if "$ROOT/Scripts/set-release-artifact.sh" --manifest "$PKG_COPY/Package.swift" "$TEST_VERSION" "not-a-sha256" >/dev/null 2>&1; then
    echo "Expected set-release-artifact.sh to reject invalid checksum" >&2
    exit 1
fi
echo "PASS invalid-input-rejection"

# 2. Verify negative checks in Scripts/verify-artifact.sh when a built artifact is present.
if [ -d "$ARTIFACT" ]; then
    "$ROOT/Scripts/verify-artifact.sh" --artifact "$ARTIFACT" >/dev/null
    echo "PASS verify-artifact-valid"

    # Inject a second object member with a leaked global symbol and DWARF debug info.
    BAD_XCF="$FIXTURE/Bad.xcframework"
    cp -R "$ARTIFACT" "$BAD_XCF"
    cat > "$FIXTURE/extra.c" <<'C'
int leaked_extra_symbol(void) { return 7; }
C
    xcrun clang -arch arm64 -g -c "$FIXTURE/extra.c" -o "$FIXTURE/extra.o"
    ar r "$BAD_XCF/macos-arm64/libdocumentkit_core.a" "$FIXTURE/extra.o" >/dev/null 2>&1
    if "$ROOT/Scripts/verify-artifact.sh" --artifact "$BAD_XCF" >/dev/null 2>&1; then
        echo "Expected verify-artifact.sh to reject multi-member / DWARF / leaked-symbol archive" >&2
        exit 1
    fi
    echo "PASS verify-artifact-rejects-unstripped-multi-member"

    # Verify a single-object archive with DWARF info is rejected specifically for __DWARF.
    BAD_DWARF_XCF="$FIXTURE/BadDwarf.xcframework"
    cp -R "$ARTIFACT" "$BAD_DWARF_XCF"
    cat > "$FIXTURE/dwarf_stub.c" <<'C'
void documentkit_inspect(void) {}
void documentkit_inspect_with_options(void) {}
void documentkit_extract(void) {}
void documentkit_extract_with_options(void) {}
void documentkit_extract_document(void) {}
void documentkit_extract_document_with_options(void) {}
void documentkit_buffer_free(void) {}
const char *documentkit_engine_version(void) { return "stub"; }
const char *documentkit_engine_revision(void) { return "stub"; }
C
    xcrun clang -arch arm64 -mmacosx-version-min=13.0 -g -c "$FIXTURE/dwarf_stub.c" -o "$FIXTURE/dwarf_stub.o"
    xcrun libtool -static -D -o "$BAD_DWARF_XCF/macos-arm64/libdocumentkit_core.a" "$FIXTURE/dwarf_stub.o"
    if "$ROOT/Scripts/verify-artifact.sh" --artifact "$BAD_DWARF_XCF" >"$FIXTURE/dwarf.out" 2>&1; then
        echo "Expected verify-artifact.sh to reject __DWARF sections in a single-object archive" >&2
        exit 1
    fi
    grep -Fq "Found unstripped __DWARF or __LLVM" "$FIXTURE/dwarf.out"
    echo "PASS verify-artifact-rejects-dwarf"

    # Verify a single-object archive with an __LLVM section (and no __DWARF) is rejected specifically for __LLVM.
    BAD_LLVM_XCF="$FIXTURE/BadLLVM.xcframework"
    cp -R "$ARTIFACT" "$BAD_LLVM_XCF"
    cat > "$FIXTURE/llvm_stub.c" <<'C'
__attribute__((section("__LLVM,__bitcode"), used))
static const char fake_bitcode[] = "bc";
void documentkit_inspect(void) {}
void documentkit_inspect_with_options(void) {}
void documentkit_extract(void) {}
void documentkit_extract_with_options(void) {}
void documentkit_extract_document(void) {}
void documentkit_extract_document_with_options(void) {}
void documentkit_buffer_free(void) {}
const char *documentkit_engine_version(void) { return "stub"; }
const char *documentkit_engine_revision(void) { return "stub"; }
C
    xcrun clang -arch arm64 -mmacosx-version-min=13.0 -c "$FIXTURE/llvm_stub.c" -o "$FIXTURE/llvm_stub.o"
    xcrun libtool -static -D -o "$BAD_LLVM_XCF/macos-arm64/libdocumentkit_core.a" "$FIXTURE/llvm_stub.o"
    if "$ROOT/Scripts/verify-artifact.sh" --artifact "$BAD_LLVM_XCF" >"$FIXTURE/llvm.out" 2>&1; then
        echo "Expected verify-artifact.sh to reject __LLVM sections in a single-object archive" >&2
        exit 1
    fi
    grep -Fq "Found unstripped __DWARF or __LLVM" "$FIXTURE/llvm.out"
    echo "PASS verify-artifact-rejects-llvm"

    # Verify a single-object archive with a leaked global symbol (no DWARF/LLVM) is rejected.
    BAD_SYM_XCF="$FIXTURE/BadSym.xcframework"
    cp -R "$ARTIFACT" "$BAD_SYM_XCF"
    mkdir -p "$FIXTURE/extracted"
    (cd "$FIXTURE/extracted" && ar x "$BAD_SYM_XCF/macos-arm64/libdocumentkit_core.a")
    SDK_VER=$(xcrun --sdk macosx --show-sdk-version)
    xcrun clang -arch arm64 -mmacosx-version-min=13.0 -c "$FIXTURE/extra.c" -o "$FIXTURE/extra_nodwarf.o"
    xcrun ld -r -S -arch arm64 -platform_version macos 13.0 "$SDK_VER" \
        "$FIXTURE/extracted"/*.o "$FIXTURE/extra_nodwarf.o" \
        -o "$FIXTURE/merged_leaked.o"
    xcrun strip -S "$FIXTURE/merged_leaked.o"
    xcrun libtool -static -D -o "$BAD_SYM_XCF/macos-arm64/libdocumentkit_core.a" "$FIXTURE/merged_leaked.o"
    if "$ROOT/Scripts/verify-artifact.sh" --artifact "$BAD_SYM_XCF" >"$FIXTURE/sym.out" 2>&1; then
        echo "Expected verify-artifact.sh to reject leaked global symbols" >&2
        exit 1
    fi
    grep -Fq "Exported global symbols" "$FIXTURE/sym.out"
    echo "PASS verify-artifact-rejects-leaked-symbol"
fi

echo "Verified artifact and release tooling."
