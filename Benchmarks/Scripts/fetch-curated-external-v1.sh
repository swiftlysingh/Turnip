#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DESTINATION=${1:-"$ROOT/Corpus/curated-v1"}

fetch() {
    relative_path=$1
    expected=$2
    url=$3
    destination="$DESTINATION/$relative_path"

    mkdir -p "$(dirname "$destination")"
    if [ -f "$destination" ]; then
        actual=$(shasum -a 256 "$destination" | awk '{print $1}')
        if [ "$actual" = "$expected" ]; then
            echo "Verified $relative_path"
            return
        fi
        echo "Checksum mismatch for existing $destination" >&2
        exit 1
    fi

    temporary=$(mktemp "$destination.download.XXXXXX")
    if ! curl --fail --location --silent --show-error "$url" --output "$temporary"; then
        rm -f -- "$temporary"
        exit 1
    fi
    actual=$(shasum -a 256 "$temporary" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        echo "Checksum mismatch for $relative_path: expected $expected, got $actual" >&2
        rm -f -- "$temporary"
        exit 1
    fi
    mv "$temporary" "$destination"
    echo "Fetched $relative_path"
}

fetch nist/NIST.SP.800-12r1.pdf \
    1baa0b89fc554c15b465b6a974be0a63b08124bf5d5987d34e0965fbafea4a2e \
    https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-12r1.pdf
fetch nasa/20150000884-enhanced-fan-noise-modeling.pdf \
    42ff00118bf0f1c0d10853aaa4a16f24a2dd105634c7ab62180fc9b4d6e7587e \
    https://ntrs.nasa.gov/api/citations/20150000884/downloads/20150000884.pdf
fetch gov/budget-fy2025-summary-tables.pdf \
    f28aff7412c9f6c7906e017a48f99e382470260e16b0371709f79c854b6ad5dd \
    https://www.govinfo.gov/content/pkg/BUDGET-2025-BUD/pdf/BUDGET-2025-BUD-26.pdf
fetch eu/the-digital-en.pdf \
    67ba49de6815e43b008fc061bc758c056fea1178c6dca16ca4302391ef8667c6 \
    'https://op.europa.eu/o/opportal-service/download-handler?format=pdf&identifier=f3556a65-88ea-11ee-99ba-01aa75ed71a1&language=en&productionSystem=cellar'

echo "Corpus ready at $DESTINATION"
