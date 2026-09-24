#!/usr/bin/env bash
#
# Tests for .github/workflows/release-anchored-reusable.yml.
#
# Follows the pattern in tests/codex-review-workflow.sh: extract each named
# `run:` block out of the workflow YAML, execute it against stubbed `gh` and a
# real throwaway git repository, and assert on the behaviour.
#
# What this covers: the branching logic — the gate's verdicts, the empty-range
# guard, the tag guard, the verify comparison, and dry-run write suppression.
# What it cannot cover: a real workflow_run payload, a real deployed SHA, and
# release-drafter's actual output. That is proven by a dry run from a caller
# repository pinned at this branch.
#
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/release-anchored-reusable.yml"
TMP_ROOT=${TMPDIR:-/tmp}/release-anchored-workflow-test.$$
STEPS_DIR="$TMP_ROOT/steps"
STUB_DIR="$TMP_ROOT/bin"
WORK_DIR="$TMP_ROOT/work"

pass_count=0

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "not ok - $*" >&2
  exit 1
}

pass() {
  pass_count=$((pass_count + 1))
  echo "ok $pass_count - $*"
}

assert_file_contains() {
  local file=$1
  local pattern=$2
  if ! grep -Fq -e "$pattern" "$file"; then
    echo "Expected to find '$pattern' in $file" >&2
    sed -n '1,160p' "$file" >&2 || true
    fail "missing expected text"
  fi
}

assert_file_not_contains() {
  local file=$1
  local pattern=$2
  if grep -Fq -e "$pattern" "$file"; then
    echo "Did not expect to find '$pattern' in $file" >&2
    sed -n '1,160p' "$file" >&2 || true
    fail "unexpected text present"
  fi
}

extract_step() {
  local step_name=$1
  local output_file=$2

  awk -v step="$step_name" '
    /^      - name: / {
      if (in_run) {
        exit
      }
      in_step = ($0 == "      - name: " step)
      next
    }
    in_step && /^        run: \|/ {
      in_run = 1
      next
    }
    in_run {
      print substr($0, 11)
    }
  ' "$WORKFLOW_FILE" > "$output_file"

  if [ ! -s "$output_file" ]; then
    fail "could not extract workflow step: $step_name"
  fi
}

install_stubs() {
  mkdir -p "$STUB_DIR"

  # Emulates `gh api [--jq EXPR]` by serving a canned body and, when --jq is
  # given, piping it through the real jq exactly as gh would.
  cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1" = "api" ]; then
  target=$2
  shift 2

  jq_expr=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --jq)
        jq_expr=$2
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  body=
  case "$target" in
    *git/ref/heads/*)
      body=$(jq -n --arg sha "${STUB_TIP_SHA:?STUB_TIP_SHA is required}" '{object: {sha: $sha}}')
      ;;
    *actions/workflows/*/runs*)
      workflow=${target#*actions/workflows/}
      workflow=${workflow%%/runs*}
      var="STUB_CONCLUSION_$(printf %s "$workflow" | tr '.-' '__')"
      conclusion=${!var:-success}
      if [ "$conclusion" = "missing" ]; then
        body=$(jq -n '{workflow_runs: []}')
      else
        body=$(jq -n --arg c "$conclusion" \
          '{workflow_runs: [{conclusion: $c, html_url: "https://github.invalid/run/1"}]}')
      fi
      ;;
    *commits/*/pulls)
      body=${STUB_COMMIT_PULLS:-'[]'}
      ;;
    *)
      echo "unexpected gh api target: $target" >&2
      exit 2
      ;;
  esac

  if [ -n "$jq_expr" ]; then
    printf '%s' "$body" | jq -r "$jq_expr"
  else
    printf '%s' "$body"
  fi
  exit 0
fi

if [ "$1" = "release" ]; then
  echo "$*" >> "${GH_RELEASE_LOG:?GH_RELEASE_LOG is required}"
  # `release view` decides create-vs-edit; default to "not found".
  if [ "$2" = "view" ]; then
    exit "${GH_RELEASE_VIEW_EXIT:-1}"
  fi
  exit 0
fi

if [ "$1" = "label" ]; then
  if [ "${STUB_LABEL_EXISTS:-true}" = "true" ]; then
    echo "release-automation"
  fi
  exit 0
fi

if [ "$1" = "issue" ]; then
  echo "$*" >> "${GH_ISSUE_LOG:-/dev/null}"
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 2
STUB
  chmod +x "$STUB_DIR/gh"
}

new_github_output() {
  local file="$TMP_ROOT/github_output.$RANDOM"
  : > "$file"
  echo "$file"
}

# Runs an extracted step. Prints nothing on success; captures stdout+stderr.
run_step() {
  local script=$1
  local log=$2
  shift 2

  (
    cd "$WORK_DIR"
    PATH="$STUB_DIR:$PATH"
    export PATH
    env "$@" bash "$script"
  ) > "$log" 2>&1
}

# Same as run_step, but a non-zero exit is reported with its log rather than
# aborting the suite silently under `set -e`.
run_step_ok() {
  local script=$1
  local log=$2
  shift 2

  if ! run_step "$script" "$log" "$@"; then
    echo "Step exited non-zero: $script" >&2
    cat "$log" >&2
    fail "unexpected step failure"
  fi
}

setup_repo() {
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"
  git -C "$WORK_DIR" init -q -b main
  git -C "$WORK_DIR" config user.email "test@example.invalid"
  git -C "$WORK_DIR" config user.name "Test"
  git -C "$WORK_DIR" commit -q --allow-empty -m "first"
  git -C "$WORK_DIR" tag -a "v2020.1.1" -m "baseline"
  git -C "$WORK_DIR" commit -q --allow-empty -m "second"

  git init -q --bare "$TMP_ROOT/remote.git"
  git -C "$WORK_DIR" remote add origin "$TMP_ROOT/remote.git"
}

mkdir -p "$STEPS_DIR"
install_stubs

extract_step "Gate on a proven production deploy" "$STEPS_DIR/gate.sh"
extract_step "Compute release range" "$STEPS_DIR/range.sh"
extract_step "Resolve and create the release tag" "$STEPS_DIR/tag.sh"
extract_step "Verify the notes cover the whole range" "$STEPS_DIR/verify.sh"
extract_step "Create or update the release" "$STEPS_DIR/release.sh"
extract_step "Report failure" "$STEPS_DIR/notify.sh"

TIP=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222

# ---------------------------------------------------------------- gate ------

setup_repo

out=$(new_github_output)
run_step_ok "$STEPS_DIR/gate.sh" "$TMP_ROOT/gate-ok.log" \
  "GITHUB_OUTPUT=$out" "STUB_TIP_SHA=$TIP" \
  "REPO=acme/app" "EVENT_NAME=workflow_run" "TRIGGER_SHA=$TIP" "INPUT_SHA=" \
  "PRODUCTION_BRANCH=main" "REQUIRED_DEPLOY=" \
  "REQUIRED_WORKFLOWS=deploy.yml,vercel-production.yml"
assert_file_contains "$out" "skip=false"
assert_file_contains "$out" "sha=$TIP"
pass "gate passes when every required deploy workflow succeeded for the tip"

out=$(new_github_output)
run_step_ok "$STEPS_DIR/gate.sh" "$TMP_ROOT/gate-stale.log" \
  "GITHUB_OUTPUT=$out" "STUB_TIP_SHA=$TIP" \
  "REPO=acme/app" "EVENT_NAME=workflow_run" "TRIGGER_SHA=$OTHER" "INPUT_SHA=" \
  "PRODUCTION_BRANCH=main" "REQUIRED_WORKFLOWS=deploy.yml"
assert_file_contains "$out" "skip=true"
assert_file_not_contains "$out" "skip=false"
pass "gate skips a superseded workflow_run instead of releasing an old commit"

out=$(new_github_output)
if run_step "$STEPS_DIR/gate.sh" "$TMP_ROOT/gate-refuse.log" \
  "GITHUB_OUTPUT=$out" "STUB_TIP_SHA=$TIP" \
  "REPO=acme/app" "EVENT_NAME=workflow_dispatch" "TRIGGER_SHA=" "INPUT_SHA=$OTHER" \
  "PRODUCTION_BRANCH=main" "REQUIRED_WORKFLOWS=deploy.yml"; then
  fail "gate should refuse an explicit SHA that is not the production tip"
fi
assert_file_contains "$TMP_ROOT/gate-refuse.log" "Not a production commit"
pass "gate refuses an explicit SHA that is not on the production branch tip"

out=$(new_github_output)
run_step_ok "$STEPS_DIR/gate.sh" "$TMP_ROOT/gate-pending.log" \
  "GITHUB_OUTPUT=$out" "STUB_TIP_SHA=$TIP" \
  "REPO=acme/app" "EVENT_NAME=workflow_run" "TRIGGER_SHA=$TIP" "INPUT_SHA=" \
  "PRODUCTION_BRANCH=main" "REQUIRED_WORKFLOWS=deploy.yml,vercel-production.yml" \
  "STUB_CONCLUSION_vercel_production_yml=missing"
assert_file_contains "$out" "skip=true"
assert_file_contains "$TMP_ROOT/gate-pending.log" "Production deploy not proven"
pass "a missing deploy run is a no-op, not a failure"

out=$(new_github_output)
run_step_ok "$STEPS_DIR/gate.sh" "$TMP_ROOT/gate-failed.log" \
  "GITHUB_OUTPUT=$out" "STUB_TIP_SHA=$TIP" \
  "REPO=acme/app" "EVENT_NAME=workflow_run" "TRIGGER_SHA=$TIP" "INPUT_SHA=" \
  "PRODUCTION_BRANCH=main" "REQUIRED_WORKFLOWS=deploy.yml" \
  "STUB_CONCLUSION_deploy_yml=failure"
assert_file_contains "$out" "skip=true"
pass "a failed deploy run is a no-op, not a release"

# --------------------------------------------------------------- range ------

setup_repo
HEAD_SHA=$(git -C "$WORK_DIR" rev-parse HEAD)

out=$(new_github_output)
summary="$TMP_ROOT/summary.md"
: > "$summary"
run_step_ok "$STEPS_DIR/range.sh" "$TMP_ROOT/range-internal.log" \
  "GITHUB_OUTPUT=$out" "GITHUB_STEP_SUMMARY=$summary" \
  "REPO=acme/app" "SHA=$HEAD_SHA" "TAG_PREFIX=v" "MAX_COMMITS=300" \
  "STUB_COMMIT_PULLS=[{\"number\":7,\"title\":\"Bump deps\",\"labels\":[{\"name\":\"release/internal\"}]}]"
assert_file_contains "$out" "skip=true"
assert_file_contains "$TMP_ROOT/range-internal.log" "Nothing to release"
pass "a range of only internal work produces no tag and no release"

out=$(new_github_output)
: > "$summary"
run_step_ok "$STEPS_DIR/range.sh" "$TMP_ROOT/range-ok.log" \
  "GITHUB_OUTPUT=$out" "GITHUB_STEP_SUMMARY=$summary" \
  "REPO=acme/app" "SHA=$HEAD_SHA" "TAG_PREFIX=v" "MAX_COMMITS=300" \
  "STUB_COMMIT_PULLS=[{\"number\":7,\"title\":\"Add a thing\",\"labels\":[{\"name\":\"release/new\"}]},{\"number\":8,\"title\":\"Tidy\",\"labels\":[{\"name\":\"release/skip\"}]}]"
assert_file_contains "$out" "skip=false"
assert_file_contains "$out" "prev_tag=v2020.1.1"
assert_file_contains "$WORK_DIR/expected_prs.txt" "7"
assert_file_not_contains "$WORK_DIR/expected_prs.txt" "8"
pass "skipped PRs are excluded from the expected set, releasable work is kept"

# The baseline case: the only release tag in the repository sits on the commit
# being released. Production has not moved, so this is a no-op — not a walk of
# the entire history, which is what the `^` in the previous-tag lookup would
# otherwise cause.
setup_repo
BASELINE_SHA=$(git -C "$WORK_DIR" rev-parse HEAD)
git -C "$WORK_DIR" tag -d v2020.1.1 >/dev/null
git -C "$WORK_DIR" tag -a v0.0.0 -m "baseline" "$BASELINE_SHA"

out=$(new_github_output)
: > "$summary"
run_step_ok "$STEPS_DIR/range.sh" "$TMP_ROOT/range-baseline.log" \
  "GITHUB_OUTPUT=$out" "GITHUB_STEP_SUMMARY=$summary" \
  "REPO=acme/app" "SHA=$BASELINE_SHA" "TAG_PREFIX=v" "MAX_COMMITS=300" \
  "STUB_COMMIT_PULLS=[]"
assert_file_contains "$out" "skip=true"
assert_file_contains "$TMP_ROOT/range-baseline.log" "already marks"
assert_file_not_contains "$TMP_ROOT/range-baseline.log" "Walking the full history"
pass "a commit carrying the only release tag is a no-op, not a full-history walk"

setup_repo
HEAD_SHA=$(git -C "$WORK_DIR" rev-parse HEAD)

out=$(new_github_output)
: > "$summary"
if run_step "$STEPS_DIR/range.sh" "$TMP_ROOT/range-toobig.log" \
  "GITHUB_OUTPUT=$out" "GITHUB_STEP_SUMMARY=$summary" \
  "REPO=acme/app" "SHA=$HEAD_SHA" "TAG_PREFIX=v" "MAX_COMMITS=0" \
  "STUB_COMMIT_PULLS=[]"; then
  fail "range should refuse a range larger than max_commits"
fi
assert_file_contains "$TMP_ROOT/range-toobig.log" "Range too large"
pass "an oversized range fails rather than risking truncated notes"

# ----------------------------------------------------------------- tag ------

setup_repo
HEAD_SHA=$(git -C "$WORK_DIR" rev-parse HEAD)
PARENT_SHA=$(git -C "$WORK_DIR" rev-parse HEAD^)

out=$(new_github_output)
run_step_ok "$STEPS_DIR/tag.sh" "$TMP_ROOT/tag-dryrun.log" \
  "GITHUB_OUTPUT=$out" "SHA=$HEAD_SHA" "TAG_PREFIX=v" "MODE=dry-run"
assert_file_contains "$TMP_ROOT/tag-dryrun.log" "[dry-run] would create annotated tag"
if [ -n "$(git -C "$WORK_DIR" tag --points-at "$HEAD_SHA")" ]; then
  fail "dry-run must not create a tag"
fi
pass "dry-run resolves a tag name without creating or pushing it"

out=$(new_github_output)
run_step_ok "$STEPS_DIR/tag.sh" "$TMP_ROOT/tag-create.log" \
  "GITHUB_OUTPUT=$out" "SHA=$HEAD_SHA" "TAG_PREFIX=v" "MODE=publish"
TAG_CREATED=$(git -C "$WORK_DIR" tag --points-at "$HEAD_SHA" --list 'v[0-9]*' | head -n 1)
[ -n "$TAG_CREATED" ] || fail "publish mode should create an annotated tag"
[ "$(git -C "$WORK_DIR" cat-file -t "$TAG_CREATED")" = "tag" ] || fail "tag must be annotated"
assert_file_contains "$out" "tag=$TAG_CREATED"
pass "publish mode creates an annotated tag and pushes it"

out=$(new_github_output)
run_step_ok "$STEPS_DIR/tag.sh" "$TMP_ROOT/tag-rerun.log" \
  "GITHUB_OUTPUT=$out" "SHA=$HEAD_SHA" "TAG_PREFIX=v" "MODE=publish"
assert_file_contains "$TMP_ROOT/tag-rerun.log" "Reusing existing tag"
assert_file_contains "$out" "tag=$TAG_CREATED"
COUNT=$(git -C "$WORK_DIR" tag --list 'v[0-9]*' | wc -l)
[ "$COUNT" -eq 2 ] || fail "a re-run must not create a second tag (found $COUNT)"
pass "re-running against an already-tagged SHA reuses the tag"

# Point today's computed tag at a different commit, then demand our SHA.
BASE_TAG="v$(date -u +%Y.%-m.%-d)"
git -C "$WORK_DIR" tag -d "$TAG_CREATED" >/dev/null
git -C "$WORK_DIR" tag -a "$BASE_TAG" -m "wrong place" "$PARENT_SHA"
out=$(new_github_output)
if run_step "$STEPS_DIR/tag.sh" "$TMP_ROOT/tag-conflict.log" \
  "GITHUB_OUTPUT=$out" "SHA=$HEAD_SHA" "TAG_PREFIX=v" "MODE=publish"; then
  : # a free suffix is fine; the conflict case is asserted below
fi
assert_file_not_contains "$TMP_ROOT/tag-conflict.log" "error"
if [ "$(git -C "$WORK_DIR" rev-list -n 1 "$BASE_TAG")" != "$PARENT_SHA" ]; then
  fail "an existing tag must never be moved"
fi
pass "an occupied tag name is never moved; a free suffix is taken instead"

# -------------------------------------------------------------- verify ------

setup_repo
printf '7\n8\n' > "$WORK_DIR/expected_prs.txt"

run_step_ok "$STEPS_DIR/verify.sh" "$TMP_ROOT/verify-ok.log" \
  "BODY=- Add a thing (#7)
- Fix a thing (#8)"
assert_file_contains "$TMP_ROOT/verify-ok.log" "Verified"
pass "verify passes when the notes cover every PR in the range"

if run_step "$STEPS_DIR/verify.sh" "$TMP_ROOT/verify-short.log" \
  "GITHUB_STEP_SUMMARY=$TMP_ROOT/summary2.md" \
  "BODY=- Add a thing (#7)"; then
  fail "verify should fail when release-drafter truncates the range"
fi
assert_file_contains "$TMP_ROOT/verify-short.log" "do not match the commit range"
pass "a truncated PR set fails the run instead of shipping short notes"

# ------------------------------------------------------------- release ------

setup_repo
cat > "$WORK_DIR/prs.json" <<'JSON'
[
  {"number": 7, "title": "Add a thing", "labels": ["release/new"]},
  {"number": 9, "title": "Tighten access checks", "labels": ["release/security"]},
  {"number": 10, "title": "Bump deps", "labels": ["release/internal"]}
]
JSON

RELEASE_LOG="$TMP_ROOT/gh-release.log"
: > "$RELEASE_LOG"

# The prose body and release.json are built from the SAME two sources — the
# notes release-drafter rendered, and prs.json — so asserting on both proves
# the split is real rather than an artefact of the fixture.
DRAFTED_BODY="## New

- Add a thing (#7)

## Security & reliability

- Tighten access checks (#9)"

run_step_ok "$STEPS_DIR/release.sh" "$TMP_ROOT/release-dryrun.log" \
  "GITHUB_STEP_SUMMARY=$TMP_ROOT/summary3.md" "GH_RELEASE_LOG=$RELEASE_LOG" \
  "REPO=acme/app" "SHA=$TIP" "TAG=v2026.9.24" "PREV_TAG=v2026.9.23" \
  "MODE=dry-run" "DEPLOY_SUMMARY=- deploy.yml: success" "BODY=$DRAFTED_BODY"
if [ -s "$RELEASE_LOG" ]; then
  echo "gh was called:" >&2
  cat "$RELEASE_LOG" >&2
  fail "dry-run must not issue any gh release write"
fi
pass "dry-run renders the body and payload without any gh release call"

assert_file_contains "$WORK_DIR/release.json" '"pr": 7'
assert_file_not_contains "$WORK_DIR/release.json" '"pr": 9'
assert_file_not_contains "$WORK_DIR/release.json" '"pr": 10'
pass "release.json carries customer-facing work only, never security or internal"

assert_file_contains "$WORK_DIR/release_body.md" "Tighten access checks"
assert_file_contains "$WORK_DIR/release_body.md" "compare/v2026.9.23...v2026.9.24"
pass "the prose body keeps security lines and links the full changelog"

: > "$RELEASE_LOG"
run_step_ok "$STEPS_DIR/release.sh" "$TMP_ROOT/release-publish.log" \
  "GITHUB_STEP_SUMMARY=$TMP_ROOT/summary4.md" "GH_RELEASE_LOG=$RELEASE_LOG" \
  "REPO=acme/app" "SHA=$TIP" "TAG=v2026.9.24" "PREV_TAG=v2026.9.23" \
  "MODE=publish" "DEPLOY_SUMMARY=- deploy.yml: success" "BODY=- Add a thing (#7)"
assert_file_contains "$RELEASE_LOG" "release create v2026.9.24"
assert_file_contains "$RELEASE_LOG" "release upload v2026.9.24 release.json --clobber"
assert_file_not_contains "$RELEASE_LOG" "--draft"
pass "publish mode creates the release and uploads the payload"

: > "$RELEASE_LOG"
run_step_ok "$STEPS_DIR/release.sh" "$TMP_ROOT/release-existing.log" \
  "GITHUB_STEP_SUMMARY=$TMP_ROOT/summary5.md" "GH_RELEASE_LOG=$RELEASE_LOG" \
  "GH_RELEASE_VIEW_EXIT=0" \
  "REPO=acme/app" "SHA=$TIP" "TAG=v2026.9.24" "PREV_TAG=v2026.9.23" \
  "MODE=publish" "DEPLOY_SUMMARY=- deploy.yml: success" "BODY=- Add a thing (#7)"
assert_file_contains "$RELEASE_LOG" "release edit v2026.9.24"
assert_file_not_contains "$RELEASE_LOG" "release create"
pass "an existing release is edited in place rather than duplicated"

: > "$RELEASE_LOG"
run_step_ok "$STEPS_DIR/release.sh" "$TMP_ROOT/release-draft.log" \
  "GITHUB_STEP_SUMMARY=$TMP_ROOT/summary6.md" "GH_RELEASE_LOG=$RELEASE_LOG" \
  "REPO=acme/app" "SHA=$TIP" "TAG=v2026.9.24" "PREV_TAG=" \
  "MODE=draft" "DEPLOY_SUMMARY=- deploy.yml: success" "BODY=- Add a thing (#7)"
assert_file_contains "$RELEASE_LOG" "--draft"
pass "draft mode creates the release as a draft"

# --------------------------------------------------------------- labels -----

# GitHub rejects a label description over 100 characters with HTTP 422, part
# way through the loop, leaving the repository with some labels created and
# some missing. The script checks every entry before writing anything.
LABEL_SCRIPT="$ROOT_DIR/scripts/sync-release-labels.sh"

if ! bash "$LABEL_SCRIPT" --dry-run acme/app > "$TMP_ROOT/labels-dryrun.log" 2>&1; then
  cat "$TMP_ROOT/labels-dryrun.log" >&2
  fail "label sync dry-run should succeed"
fi
for L in release/new release/improved release/fixed release/api release/security release/internal release/skip release-automation; do
  assert_file_contains "$TMP_ROOT/labels-dryrun.log" "$L"
done
assert_file_contains "$TMP_ROOT/labels-dryrun.log" "Done."
pass "label sync lists every label in dry-run and writes nothing"

while IFS='|' read -r name _ description; do
  [ -n "$name" ] || continue
  if [ "${#description}" -gt 100 ]; then
    fail "label description for $name is ${#description} characters; GitHub allows 100"
  fi
done < <(sed -n "s/^  '\(release[/-][a-z-]*\)|\([0-9a-f]*\)|\(.*\)'$/||/p" "$LABEL_SCRIPT")
pass "every label description fits GitHub's 100 character limit"

# -------------------------------------------------------------- notify -----

# The gate reads deploy run conclusions, which needs `actions: read`. Without
# it every run dies with HTTP 403 before it can tell pending from successful.
PERMS=$(awk '/^permissions:/{f=1;next} /^[a-z]/{f=0} f' "$WORKFLOW_FILE")
printf '%s' "$PERMS" | grep -q 'actions: read'   || fail "the workflow must declare actions: read, or the gate cannot list deploy runs"
pass "the workflow requests actions: read for the gate's run lookups"

ISSUE_LOG="$TMP_ROOT/gh-issue.log"
: > "$ISSUE_LOG"
run_step_ok "$STEPS_DIR/notify.sh" "$TMP_ROOT/notify-labelled.log"   "GH_ISSUE_LOG=$ISSUE_LOG" "GH_RELEASE_LOG=$TMP_ROOT/unused.log"   "REPO=acme/app" "SHA=$TIP" "TAG=v2026.9.24" "MODE=publish"   "RUN_URL=https://github.invalid/run/1"
assert_file_contains "$ISSUE_LOG" "--label release-automation"
pass "a failure opens a labelled release-automation issue"

# An absent label must not swallow the alert: gh validates labels before
# creating anything, so this would otherwise mean no issue at all.
: > "$ISSUE_LOG"
run_step_ok "$STEPS_DIR/notify.sh" "$TMP_ROOT/notify-unlabelled.log"   "GH_ISSUE_LOG=$ISSUE_LOG" "GH_RELEASE_LOG=$TMP_ROOT/unused.log"   "STUB_LABEL_EXISTS=false"   "REPO=acme/app" "SHA=$TIP" "TAG=v2026.9.24" "MODE=publish"   "RUN_URL=https://github.invalid/run/1"
assert_file_contains "$ISSUE_LOG" "issue create"
assert_file_not_contains "$ISSUE_LOG" "--label"
assert_file_contains "$TMP_ROOT/notify-unlabelled.log" "Missing label"
pass "a missing release-automation label still opens the alert, unlabelled"

echo
echo "All $pass_count checks passed."
