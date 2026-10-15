#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/turnip-release-checks.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/bin"
cat > "$fixture/bin/gh" <<'SH'
#!/bin/bash
set -euo pipefail
if [ "${TEST_API_FAILURE:-0}" = 1 ]; then exit 1; fi
cat "$TEST_CHECKS"
SH
chmod +x "$fixture/bin/gh"
export PATH="$fixture/bin:$PATH"
export GH_REPO=fixture/Turnip
export GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export TEST_CHECKS="$fixture/checks.json"

check() {
  local name=$1 expected=$2 filter=$3
  jq "$filter" "$fixture/baseline.json" > "$TEST_CHECKS"
  if bash "$root/Scripts/verify-release-checks.sh" > "$fixture/output" 2>&1; then
    actual=pass
  else
    actual=fail
  fi
  if [ "$actual" != "$expected" ]; then
    cat "$fixture/output" >&2
    echo "Unexpected result for $name: $actual" >&2
    exit 1
  fi
  echo "PASS $name"
}

jq -n --arg sha "$GITHUB_SHA" '[{check_runs: [
  {id: 1, name: "SDK", head_sha: $sha, app: {slug: "codemagic-ci-cd"}, status: "completed", conclusion: "success"},
  {id: 2, name: "Rust", head_sha: $sha, app: {slug: "codemagic-ci-cd"}, status: "completed", conclusion: "success"}
]}]' > "$fixture/baseline.json"
check passing pass '.'
check missing-sdk fail '.[0].check_runs |= map(select(.name != "SDK"))'
check missing-rust fail '.[0].check_runs |= map(select(.name != "Rust"))'
check pending fail '.[0].check_runs[0] |= (.status = "in_progress" | .conclusion = null)'
check failed fail '.[0].check_runs[1].conclusion = "failure"'
check cancelled fail '.[0].check_runs[0].conclusion = "cancelled"'
check skipped fail '.[0].check_runs[0].conclusion = "skipped"'
check wrong-provider fail '.[0].check_runs[0].app.slug = "another-app"'
check wrong-commit fail '.[0].check_runs[0].head_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
check newer-failure fail '.[0].check_runs += [ (.[0].check_runs[0] | .id = 3 | .conclusion = "failure") ]'
check newer-success pass '.[0].check_runs += [ (.[0].check_runs[0] | .id = 3) ] | .[0].check_runs[0].conclusion = "failure"'
check paginated pass '[{check_runs: [.[0].check_runs[0]]}, {check_runs: [.[0].check_runs[1]]}]'
TEST_API_FAILURE=1 check api-failure fail '.'
