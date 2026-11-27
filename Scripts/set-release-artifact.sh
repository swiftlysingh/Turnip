#!/bin/bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST="$ROOT/Package.swift"
REPOSITORY="swiftlysingh/Turnip"

usage() {
    cat <<'EOF' >&2
Usage: Scripts/set-release-artifact.sh [--repository <owner/repo>] [--manifest <path>] <version> <checksum>

Updates Package.swift so DocumentKitCore points to the GitHub Releases
DocumentKitCore-<version>.xcframework.zip binary target and SHA-256 checksum.
EOF
    exit 64
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repository)
            [ "$#" -ge 2 ] || usage
            REPOSITORY=$2
            shift 2
            ;;
        --manifest)
            [ "$#" -ge 2 ] || usage
            MANIFEST=$2
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        --*)
            echo "Unknown option: $1" >&2
            usage
            ;;
        *)
            break
            ;;
    esac
done

[ "$#" -eq 2 ] || usage
VERSION=$1
CHECKSUM=$2

if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "Version must be semantic version X.Y.Z without a leading v: $VERSION" >&2
    exit 1
fi

if [[ ! "$CHECKSUM" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Checksum must be a 64-character lowercase hexadecimal SHA-256 digest." >&2
    exit 1
fi

if [[ ! "$REPOSITORY" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    echo "Repository must have owner/name form: $REPOSITORY" >&2
    exit 1
fi

test -f "$MANIFEST"

URL="https://github.com/$REPOSITORY/releases/download/v$VERSION/DocumentKitCore-$VERSION.xcframework.zip"

python3 - "$MANIFEST" "$URL" "$CHECKSUM" <<'PY'
import re
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
url = sys.argv[2]
checksum = sys.argv[3]

text = manifest_path.read_text(encoding="utf-8")

url_pattern = re.compile(r'^let releaseArtifactURL: String\? = .*$', re.MULTILINE)
checksum_pattern = re.compile(r'^let releaseArtifactChecksum: String\? = .*$', re.MULTILINE)

updated, url_count = url_pattern.subn(f'let releaseArtifactURL: String? = "{url}"', text)
if url_count != 1:
    sys.stderr.write(f"Expected exactly 1 releaseArtifactURL declaration in {manifest_path}, found {url_count}.\n")
    sys.exit(1)

updated, checksum_count = checksum_pattern.subn(f'let releaseArtifactChecksum: String? = "{checksum}"', updated)
if checksum_count != 1:
    sys.stderr.write(f"Expected exactly 1 releaseArtifactChecksum declaration in {manifest_path}, found {checksum_count}.\n")
    sys.exit(1)

manifest_path.write_text(updated, encoding="utf-8")
PY

echo "Updated $MANIFEST for v$VERSION ($URL)"
