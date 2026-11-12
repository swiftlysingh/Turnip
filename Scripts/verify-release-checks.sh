#!/bin/bash
set -euo pipefail

: "${GH_REPO:?Set GH_REPO to the GitHub repository}"
: "${GITHUB_SHA:?Set GITHUB_SHA to the release commit}"
if [[ ! "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo 'Expected a full release commit SHA.' >&2
  exit 1
fi

checks=$(gh api --paginate --slurp \
  "repos/$GH_REPO/commits/$GITHUB_SHA/check-runs?filter=all&per_page=100")
for name in SDK Rust; do
  # Codemagic creates separate start and completion entries for each build.
  # Choose the newest start, breaking same-second ties by its first check ID.
  latest=$(jq -c --arg name "$name" --arg sha "$GITHUB_SHA" '
    [.[].check_runs[] | select(.name == $name and .head_sha == $sha
      and .app.slug == "codemagic-ci-cd")]
    | group_by(.external_id)
    | (max_by(min_by(.id) | [.started_at, .id]) // [])
    | max_by(.id)
  ' <<< "$checks")
  if ! jq -e '.status == "completed" and .conclusion == "success"' \
      <<< "$latest" >/dev/null; then
    echo "Release blocked: the latest Codemagic $name check must pass for $GITHUB_SHA." >&2
    echo "$latest" >&2
    exit 1
  fi
done
echo "Codemagic SDK and Rust checks passed for $GITHUB_SHA."
