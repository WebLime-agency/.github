#!/usr/bin/env bash
#
# Tests for .github/workflows/release-anchored-reusable.yml.
#
# Follows the pattern in tests/codex-review-workflow.sh: extract each named
# `run:` block out of the workflow YAML, execute it against stubbed tooling and
# a real throwaway git repository, and assert on the behaviour.
#
# Covers the branching logic — the gate's verdicts, the empty-range guard, the
# tag guard, the verify comparison, dry-run write suppression — and the
# shared-runner hardening: a planted fsmonitor command, a planted hook and a
# fake binary earlier on PATH must none of them run.
#
# What it cannot cover: a real workflow_run payload, a real deployed SHA, and
# release-drafter's actual output. That is proven by a dry run from a caller
# repository pinned at this branch's head SHA.
#
# Requires: jq (as tests/codex-review-workflow.sh already does).
#
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/release-anchored-reusable.yml"
TMP_ROOT=${TMPDIR:-/tmp}/release-anchored-workflow-test.$$
STEPS_DIR="$TMP_ROOT/steps"
STUB_DIR="$TMP_ROOT/bin"
WORK_DIR="$TMP_ROOT/work"
MARKER_DIR="$TMP_ROOT/markers"

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

assert_no_marker() {
  local marker=$1
  local what=$2
  if [ -e "$MARKER_DIR/$marker" ]; then
    echo "Marker $marker exists: $what executed" >&2
    cat "$MARKER_DIR/$marker" >&2 || true
    fail "$what ran"
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

REAL_GIT=$(command -v git)
REAL_JQ=$(command -v jq)
GIT_SAFE_VALUE="$REAL_GIT -c core.hooksPath=/dev/null -c core.fsmonitor=false"

install_stubs() {
  mkdir -p "$STUB_DIR" "$MARKER_DIR"

  # Emulates `gh api [-f k=v] [--jq EXPR]` by serving a canned body and, when
  # --jq is given, piping it through the real jq exactly as gh would. Every
  # invocation is logged so tests can assert on what was called.
  cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
set -euo pipefail

echo "\$*" >> "\${GH_CALL_LOG:-/dev/null}"

if [ "\$1" = "api" ]; then
  target=\$2
  shift 2

  jq_expr=
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --jq) jq_expr=\$2; shift 2 ;;
      *) shift ;;
    esac
  done

  body=
  case "\$target" in
    *git/ref/heads/*)
      body=\$($REAL_JQ -n --arg sha "\${STUB_TIP_SHA:?STUB_TIP_SHA is required}" '{object: {sha: \$sha}}')
      ;;
    *actions/workflows/*/runs*)
      workflow=\${target#*actions/workflows/}
      workflow=\${workflow%%/runs*}
      var="STUB_CONCLUSION_\$(printf %s "\$workflow" | tr '.-' '__')"
      conclusion=\${!var:-success}
      event=\${STUB_RUN_EVENT:-push}
      head_repo=\${STUB_RUN_HEAD_REPO:-acme/app}
      if [ "\$conclusion" = "missing" ]; then
        body=\$($REAL_JQ -n '{workflow_runs: []}')
      else
        body=\$($REAL_JQ -n --arg c "\$conclusion" --arg e "\$event" --arg r "\$head_repo" \\
          '{workflow_runs: [{conclusion: \$c, event: \$e, head_repository: {full_name: \$r}, html_url: "https://github.invalid/run/1"}]}')
      fi
      ;;
    *commits/*/pulls)
      body=\${STUB_COMMIT_PULLS:-'[]'}
      ;;
    *git/tags)
      body=\$($REAL_JQ -n '{sha: "aaaabbbbccccddddeeeeffff0000111122223333"}')
      ;;
    *git/refs)
      body=\$($REAL_JQ -n '{ref: "refs/tags/created"}')
      ;;
    *)
      echo "unexpected gh api target: \$target" >&2
      exit 2
      ;;
  esac

  if [ -n "\$jq_expr" ]; then
    printf '%s' "\$body" | $REAL_JQ -r "\$jq_expr"
  else
    printf '%s' "\$body"
  fi
  exit 0
fi

if [ "\$1" = "release" ]; then
  echo "\$*" >> "\${GH_RELEASE_LOG:-/dev/null}"
  if [ "\$2" = "view" ]; then
    exit "\${GH_RELEASE_VIEW_EXIT:-1}"
  fi
  exit 0
fi

if [ "\$1" = "label" ]; then
  if [ "\${STUB_LABEL_EXISTS:-true}" = "true" ]; then
    echo "release-automation"
  fi
  exit 0
fi

if [ "\$1" = "issue" ]; then
  echo "\$*" >> "\${GH_ISSUE_LOG:-/dev/null}"
  exit 0
fi

echo "unexpected gh invocation: \$*" >&2
exit 2
STUB
  chmod +x "$STUB_DIR/gh"
}

new_github_output() {
  local file="$TMP_ROOT/github_output.$RANDOM"
  : > "$file"
  echo "$file"
}

# Runs an extracted step with the tool paths the workflow's preflight would
# have set. Defaults come first so a test can override any of them.
run_step() {
  local script=$1
  local log=$2
  shift 2

  (
    cd "$WORK_DIR"
    PATH="$STUB_DIR:$PATH"
    export PATH
    env \
      "GIT_SAFE=$GIT_SAFE_VALUE" \
      "GH_BIN=$STUB_DIR/gh" \
      "JQ_BIN=$REAL_JQ" \
      "GIT_CONFIG_NOSYSTEM=1" \
      "$@" bash "$script"
  ) > "$log" 2>&1
}

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
  "$REAL_GIT" -C "$WORK_DIR" init -q -b main
  "$REAL_GIT" -C "$WORK_DIR" config user.email "test@example.invalid"
  "$REAL_GIT" -C "$WORK_DIR" config user.name "Test"
  "$REAL_GIT" -C "$WORK_DIR" commit -q --allow-empty -m "first"
  "$REAL_GIT" -C "$WORK_DIR" tag -a "v2020.1.1" -m "baseline"
  "$REAL_GIT" -C "$WORK_DIR" commit -q --allow-empty -m "second"
}

mkdir -p "$STEPS_DIR"
install_stubs

extract_step "Gate on a proven production deploy" "$STEPS_DIR/gate.sh"
extract_step "Verify the checkout" "$STEPS_DIR/verify-checkout.sh"
extract_step "Compute release range" "$STEPS_DIR/range.sh"
extract_step "Resolve and create the release tag" "$STEPS_DIR/tag.sh"
extract_step "Verify the notes cover the whole range" "$STEPS_DIR/verify.sh"
extract_step "Create or update the release" "$STEPS_DIR/release.sh"
extract_step "Report failure" "$STEPS_DIR/notify.sh"
extract_step "Verify the toolchain" "$STEPS_DIR/tools.sh"

TIP=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222

# ---------------------------------------------------------------- gate ------

setup_repo

out=$(new_github_output)
run_step_ok "$STEPS_DIR/gate.sh" "$TMP_ROOT/gate-ok.log" \
  "GITHUB_OUTPUT=$out" "STUB_TIP_SHA=$TIP" \
  "REPO=acme/app" "EVENT_NAME=workflow_run" "TRIGGER_SHA=$TIP" "INPUT_SHA=" \
  "PRODUCTION_BRANCH=main" "REQUIRED_WORKFLOWS=deploy.yml,vercel-production.yml"
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

# A pull_request run of the same workflow file, from a fork whose head branch
# happens to be named `main`, must not satisfy the gate.
out=$(new_github_output)
run_step_ok "$STEPS_DIR/gate.sh" "$TMP_ROOT/gate-pr-event.log" \
  "GITHUB_OUTPUT=$out" "STUB_TIP_SHA=$TIP" \
  "REPO=acme/app" "EVENT_NAME=workflow_run" "TRIGGER_SHA=$TIP" "INPUT_SHA=" \
  "PRODUCTION_BRANCH=main" "REQUIRED_WORKFLOWS=deploy.yml" \
  "STUB_RUN_EVENT=pull_request"
assert_file_contains "$out" "skip=true"
pass "a pull_request run of the deploy workflow cannot satisfy the gate"

out=$(new_github_output)
run_step_ok "$STEPS_DIR/gate.sh" "$TMP_ROOT/gate-fork.log" \
  "GITHUB_OUTPUT=$out" "STUB_TIP_SHA=$TIP" \
  "REPO=acme/app" "EVENT_NAME=workflow_run" "TRIGGER_SHA=$TIP" "INPUT_SHA=" \
  "PRODUCTION_BRANCH=main" "REQUIRED_WORKFLOWS=deploy.yml" \
  "STUB_RUN_HEAD_REPO=attacker/app"
assert_file_contains "$out" "skip=true"
pass "a deploy run from another repository cannot satisfy the gate"

# ------------------------------------------------------------ hardening -----

# core.fsmonitor makes git execute an arbitrary command on `git status`. A
# previous job on a shared runner can plant one in .git/config. Every git call
# passes -c core.fsmonitor=false, so it must never run.
setup_repo
HEAD_SHA=$("$REAL_GIT" -C "$WORK_DIR" rev-parse HEAD)
cat > "$TMP_ROOT/evil-fsmonitor" <<EVIL
#!/usr/bin/env bash
echo "fsmonitor executed" > "$MARKER_DIR/fsmonitor"
EVIL
chmod +x "$TMP_ROOT/evil-fsmonitor"
"$REAL_GIT" -C "$WORK_DIR" config core.fsmonitor "$TMP_ROOT/evil-fsmonitor"

run_step_ok "$STEPS_DIR/verify-checkout.sh" "$TMP_ROOT/harden-fsmonitor.log" \
  "SHA=$HEAD_SHA"
assert_no_marker fsmonitor "a planted core.fsmonitor command"
pass "a planted core.fsmonitor command never executes"

# A planted hook must not run either. The tag step creates tags through the
# API rather than `git push`, so no push hook is reachable, and every git call
# disables hooksPath regardless.
setup_repo
HEAD_SHA=$("$REAL_GIT" -C "$WORK_DIR" rev-parse HEAD)
mkdir -p "$WORK_DIR/.git/hooks"
cat > "$WORK_DIR/.git/hooks/pre-push" <<EVIL
#!/usr/bin/env bash
echo "pre-push executed" > "$MARKER_DIR/pre-push"
EVIL
chmod +x "$WORK_DIR/.git/hooks/pre-push"
cat > "$WORK_DIR/.git/hooks/post-checkout" <<EVIL
#!/usr/bin/env bash
echo "post-checkout executed" > "$MARKER_DIR/post-checkout"
EVIL
chmod +x "$WORK_DIR/.git/hooks/post-checkout"

out=$(new_github_output)
GH_CALL_LOG="$TMP_ROOT/gh-calls.log"
: > "$GH_CALL_LOG"
run_step_ok "$STEPS_DIR/tag.sh" "$TMP_ROOT/harden-hooks.log" \
  "GITHUB_OUTPUT=$out" "GH_CALL_LOG=$GH_CALL_LOG" \
  "REPO=acme/app" "SHA=$HEAD_SHA" "TAG_PREFIX=v" "MODE=publish"
assert_no_marker pre-push "a planted pre-push hook"
assert_no_marker post-checkout "a planted post-checkout hook"
assert_file_not_contains "$TMP_ROOT/harden-hooks.log" "git push"
pass "planted git hooks never execute; the tag is created without a push"

# The tag is created through the API, so no credential is written into any git
# config where a hook could read it.
assert_file_contains "$GH_CALL_LOG" "api repos/acme/app/git/tags"
assert_file_contains "$GH_CALL_LOG" "api repos/acme/app/git/refs"
pass "the tag is created via the API, not via an authenticated git push"

# A fake binary earlier on PATH must be ignored: the workflow uses the
# absolute paths its preflight resolved.
setup_repo
HEAD_SHA=$("$REAL_GIT" -C "$WORK_DIR" rev-parse HEAD)
cat > "$STUB_DIR/git" <<EVIL
#!/usr/bin/env bash
echo "fake git executed" > "$MARKER_DIR/fake-git"
exit 0
EVIL
chmod +x "$STUB_DIR/git"
cat > "$STUB_DIR/jq" <<EVIL
#!/usr/bin/env bash
echo "fake jq executed" > "$MARKER_DIR/fake-jq"
exit 0
EVIL
chmod +x "$STUB_DIR/jq"

out=$(new_github_output)
summary="$TMP_ROOT/summary.md"
: > "$summary"
run_step_ok "$STEPS_DIR/range.sh" "$TMP_ROOT/harden-path.log" \
  "GITHUB_OUTPUT=$out" "GITHUB_STEP_SUMMARY=$summary" \
  "REPO=acme/app" "SHA=$HEAD_SHA" "TAG_PREFIX=v" "MAX_COMMITS=300" \
  "STUB_COMMIT_PULLS=[{\"number\":7,\"title\":\"Add a thing\",\"labels\":[{\"name\":\"release/new\"}]}]"
assert_no_marker fake-git "a fake git earlier on PATH"
assert_no_marker fake-jq "a fake jq earlier on PATH"
assert_file_contains "$out" "skip=false"
pass "fake git and jq earlier on PATH are never used"
rm -f "$STUB_DIR/git" "$STUB_DIR/jq"

# The preflight's own logic, executed rather than grepped. The first version
# of this step called resolve_tool inside a command substitution, which runs it
# in a subshell: every diagnostic, including the error saying what went wrong,
# was captured into the variable instead of printed, and the step failed with a
# completely silent log. These tests exercise the real function.
sed -n '/^RESOLVED_TOOL=""/,/^require_tool git/p' "$STEPS_DIR/tools.sh" | sed '$d' > "$TMP_ROOT/tool-funcs.sh"
[ -s "$TMP_ROOT/tool-funcs.sh" ] || fail "could not extract the tool resolution functions"

# A stat that reports whatever the test needs. In production STAT_BIN is
# resolved to an absolute path before anything else, precisely so a planted
# stat cannot vouch for a planted binary.
cat > "$TMP_ROOT/fake-stat" <<'FAKESTAT'
#!/usr/bin/env bash
case "$2" in
  '%U') echo "${FAKE_OWNER:-root}" ;;
  '%a') echo "${FAKE_PERMS:-755}" ;;
esac
FAKESTAT
chmod +x "$TMP_ROOT/fake-stat"

TOOL_FIXTURE="$TMP_ROOT/fixture-tool"
printf '#!/bin/sh
' > "$TOOL_FIXTURE"
chmod +x "$TOOL_FIXTURE"

tool_case() {  # owner perms candidate -> prints "rc|resolved|output"
  (
    STAT_BIN="$TMP_ROOT/fake-stat"
    export FAKE_OWNER="$1" FAKE_PERMS="$2"
    # shellcheck disable=SC1090
    . "$TMP_ROOT/tool-funcs.sh"
    # Deliberately NOT a command substitution: that is the subshell trap this
    # whole block exists to catch, and it would swallow RESOLVED_TOOL here too.
    resolve_tool probe "$3" > "$TMP_ROOT/tool-out" 2>&1 && RC=0 || RC=$?
    printf '%s|%s|%s' "$RC" "$RESOLVED_TOOL" "$(cat "$TMP_ROOT/tool-out")"
  )
}

RESULT=$(tool_case root 755 "$TOOL_FIXTURE")
[ "${RESULT%%|*}" = "0" ] || fail "a root-owned, non-writable tool should resolve: $RESULT"
RESOLVED=$(printf '%s' "$RESULT" | cut -d'|' -f2)
[ "$RESOLVED" = "$TOOL_FIXTURE" ]   || fail "RESOLVED_TOOL must be exactly the path, with no diagnostic text: '$RESOLVED'"
printf '%s' "$RESULT" | cut -d'|' -f3- | grep -q 'probe:'   || fail "the success path must still report which binary it chose"
pass "a trusted tool resolves to exactly its path, and still reports itself"

RESULT=$(tool_case notroot 755 "$TOOL_FIXTURE")
[ "${RESULT%%|*}" != "0" ] || fail "a non-root-owned tool must be rejected: $RESULT"
printf '%s' "$RESULT" | grep -q 'is owned by notroot, not root'   || fail "rejection must say why, visibly: $RESULT"
pass "a tool not owned by root is rejected, with a visible reason"

RESULT=$(tool_case root 777 "$TOOL_FIXTURE")
[ "${RESULT%%|*}" != "0" ] || fail "a world-writable tool must be rejected: $RESULT"
printf '%s' "$RESULT" | grep -q 'group- or world-writable'   || fail "rejection must say why, visibly: $RESULT"
pass "a group- or world-writable tool is rejected, with a visible reason"

RESULT=$(tool_case root 755 "$TMP_ROOT/does-not-exist")
[ "${RESULT%%|*}" != "0" ] || fail "a missing tool must be rejected: $RESULT"
printf '%s' "$RESULT" | grep -q 'no trusted binary'   || fail "a missing tool must say so, visibly: $RESULT"
pass "a missing tool fails closed, naming the paths it looked in"

grep -q 'GIT_CONFIG_NOSYSTEM=1' "$STEPS_DIR/tools.sh"   || fail "preflight must neutralise system git config"
grep -q 'DATE_BIN' "$STEPS_DIR/tools.sh"   && fail "the workflow must not depend on /usr/bin/date; use bash strftime"
grep -q "printf -v CAL_Y" "$STEPS_DIR/tag.sh"   || fail "the CalVer tag must come from bash strftime, not an external binary"
grep -qE 'STAT_BIN=.*|/usr/bin/stat' "$STEPS_DIR/tools.sh"   || fail "stat itself must be resolved absolutely"
pass "the preflight pins stat absolutely and neutralises system git config"

grep -q 'persist-credentials: false' "$WORKFLOW_FILE" \
  || fail "checkout must not persist credentials into .git/config"
grep -qE 'uses: actions/checkout@[0-9a-f]{40}' "$WORKFLOW_FILE" \
  || fail "actions/checkout must be pinned to a full commit SHA"
grep -q 'CHECKOUT_DIR: .release-anchored/' "$WORKFLOW_FILE" \
  || fail "checkout must use a per-run directory, not the reused workspace"
pass "checkout is SHA-pinned, credential-free and lands in a per-run directory"

# --------------------------------------------------------------- range ------

setup_repo
HEAD_SHA=$("$REAL_GIT" -C "$WORK_DIR" rev-parse HEAD)

out=$(new_github_output)
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
# the entire history.
setup_repo
BASELINE_SHA=$("$REAL_GIT" -C "$WORK_DIR" rev-parse HEAD)
"$REAL_GIT" -C "$WORK_DIR" tag -d v2020.1.1 >/dev/null
"$REAL_GIT" -C "$WORK_DIR" tag -a v0.0.0 -m "baseline" "$BASELINE_SHA"

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
HEAD_SHA=$("$REAL_GIT" -C "$WORK_DIR" rev-parse HEAD)

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
HEAD_SHA=$("$REAL_GIT" -C "$WORK_DIR" rev-parse HEAD)
PARENT_SHA=$("$REAL_GIT" -C "$WORK_DIR" rev-parse HEAD^)

out=$(new_github_output)
: > "$GH_CALL_LOG"
run_step_ok "$STEPS_DIR/tag.sh" "$TMP_ROOT/tag-dryrun.log" \
  "GITHUB_OUTPUT=$out" "GH_CALL_LOG=$GH_CALL_LOG" \
  "REPO=acme/app" "SHA=$HEAD_SHA" "TAG_PREFIX=v" "MODE=dry-run"
assert_file_contains "$TMP_ROOT/tag-dryrun.log" "[dry-run] would create annotated tag"
assert_file_not_contains "$GH_CALL_LOG" "git/tags"
pass "dry-run resolves a tag name without creating it"

out=$(new_github_output)
: > "$GH_CALL_LOG"
run_step_ok "$STEPS_DIR/tag.sh" "$TMP_ROOT/tag-create.log" \
  "GITHUB_OUTPUT=$out" "GH_CALL_LOG=$GH_CALL_LOG" \
  "REPO=acme/app" "SHA=$HEAD_SHA" "TAG_PREFIX=v" "MODE=publish"
assert_file_contains "$GH_CALL_LOG" "-f type=commit"
assert_file_contains "$GH_CALL_LOG" "api repos/acme/app/git/refs"
TAG_NAME=$(grep '^tag=' "$out" | cut -d= -f2)
[ -n "$TAG_NAME" ] || fail "tag step must output a tag name"
pass "publish mode creates an annotated tag object and its ref via the API"

# The tag now exists remotely but not locally, which is what a re-run sees
# after checkout fetches it.
"$REAL_GIT" -C "$WORK_DIR" tag -a "$TAG_NAME" -m "Release $TAG_NAME" "$HEAD_SHA"
out=$(new_github_output)
: > "$GH_CALL_LOG"
run_step_ok "$STEPS_DIR/tag.sh" "$TMP_ROOT/tag-rerun.log" \
  "GITHUB_OUTPUT=$out" "GH_CALL_LOG=$GH_CALL_LOG" \
  "REPO=acme/app" "SHA=$HEAD_SHA" "TAG_PREFIX=v" "MODE=publish"
assert_file_contains "$TMP_ROOT/tag-rerun.log" "Reusing existing tag"
assert_file_contains "$out" "tag=$TAG_NAME"
assert_file_not_contains "$GH_CALL_LOG" "git/tags"
pass "re-running against an already-tagged SHA reuses it and creates nothing"

"$REAL_GIT" -C "$WORK_DIR" tag -d "$TAG_NAME" >/dev/null
TZ=UTC printf -v CAL_Y '%(%Y)T' -1; TZ=UTC printf -v CAL_M '%(%m)T' -1; TZ=UTC printf -v CAL_D '%(%d)T' -1
BASE_TAG="v${CAL_Y}.$((10#${CAL_M})).$((10#${CAL_D}))"
"$REAL_GIT" -C "$WORK_DIR" tag -a "$BASE_TAG" -m "wrong place" "$PARENT_SHA"
out=$(new_github_output)
: > "$GH_CALL_LOG"
run_step_ok "$STEPS_DIR/tag.sh" "$TMP_ROOT/tag-conflict.log" \
  "GITHUB_OUTPUT=$out" "GH_CALL_LOG=$GH_CALL_LOG" \
  "REPO=acme/app" "SHA=$HEAD_SHA" "TAG_PREFIX=v" "MODE=publish"
if [ "$("$REAL_GIT" -C "$WORK_DIR" rev-list -n 1 "$BASE_TAG")" != "$PARENT_SHA" ]; then
  fail "an existing tag must never be moved"
fi
assert_file_contains "$out" "tag=${BASE_TAG}.2"
pass "an occupied tag name is never moved; a free suffix is taken instead"

# -------------------------------------------------------------- verify ------

setup_repo
printf '7\n8\n' > "$WORK_DIR/expected_prs.txt"

run_step_ok "$STEPS_DIR/verify.sh" "$TMP_ROOT/verify-ok.log" \
  "BODY=- Add a thing (#7)
- Fix a thing (#8)"
assert_file_contains "$TMP_ROOT/verify-ok.log" "Verified"
pass "verify passes when the notes cover every PR in the range"

# An issue reference inside a PR title must not be counted as a PR number.
printf '7\n' > "$WORK_DIR/expected_prs.txt"
run_step_ok "$STEPS_DIR/verify.sh" "$TMP_ROOT/verify-issue-ref.log" \
  "BODY=- Fix the thing reported in #4321 (#7)"
assert_file_contains "$TMP_ROOT/verify-issue-ref.log" "Verified"
pass "an issue reference in a title is not mistaken for a pull request"

printf '7\n8\n' > "$WORK_DIR/expected_prs.txt"
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

DRAFTED_BODY="## New

- Add a thing (#7)

## Security & reliability

- Tighten access checks (#9)"

run_step_ok "$STEPS_DIR/release.sh" "$TMP_ROOT/release-dryrun.log" \
  "GITHUB_STEP_SUMMARY=$TMP_ROOT/summary3.md" "GH_RELEASE_LOG=$RELEASE_LOG" \
  "REPO=acme/app" "SHA=$TIP" "TAG=v2026.9.24" "PREV_TAG=v2026.9.23" \
  "MODE=dry-run" "DEPLOY_SUMMARY=- deploy.yml: success" "BODY=$DRAFTED_BODY"
if [ -s "$RELEASE_LOG" ]; then
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
  "MODE=publish" "DEPLOY_SUMMARY=- deploy.yml: success" "BODY=$DRAFTED_BODY"
assert_file_contains "$RELEASE_LOG" "release create v2026.9.24"
assert_file_contains "$RELEASE_LOG" "release upload v2026.9.24 release.json --clobber"
assert_file_not_contains "$RELEASE_LOG" "--draft"
pass "publish mode creates the release and uploads the payload"

: > "$RELEASE_LOG"
run_step_ok "$STEPS_DIR/release.sh" "$TMP_ROOT/release-existing.log" \
  "GITHUB_STEP_SUMMARY=$TMP_ROOT/summary5.md" "GH_RELEASE_LOG=$RELEASE_LOG" \
  "GH_RELEASE_VIEW_EXIT=0" \
  "REPO=acme/app" "SHA=$TIP" "TAG=v2026.9.24" "PREV_TAG=v2026.9.23" \
  "MODE=publish" "DEPLOY_SUMMARY=- deploy.yml: success" "BODY=$DRAFTED_BODY"
assert_file_contains "$RELEASE_LOG" "release edit v2026.9.24"
assert_file_not_contains "$RELEASE_LOG" "release create"
pass "an existing release is edited in place rather than duplicated"

: > "$RELEASE_LOG"
run_step_ok "$STEPS_DIR/release.sh" "$TMP_ROOT/release-draft.log" \
  "GITHUB_STEP_SUMMARY=$TMP_ROOT/summary6.md" "GH_RELEASE_LOG=$RELEASE_LOG" \
  "REPO=acme/app" "SHA=$TIP" "TAG=v2026.9.24" "PREV_TAG=" \
  "MODE=draft" "DEPLOY_SUMMARY=- deploy.yml: success" "BODY=$DRAFTED_BODY"
assert_file_contains "$RELEASE_LOG" "--draft"
pass "draft mode creates the release as a draft"

# --------------------------------------------------------------- labels -----

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
done < <(sed -n "s/^  '\(release[/-][a-z-]*\)|\([0-9a-f]*\)|\(.*\)'$/\1|\2|\3/p" "$LABEL_SCRIPT")
pass "every label description fits GitHub's 100 character limit"

# -------------------------------------------------------------- notify -----

PERMS=$(awk '/^permissions:/{f=1;next} /^[a-z]/{f=0} f' "$WORKFLOW_FILE")
printf '%s' "$PERMS" | grep -q 'actions: read' \
  || fail "the workflow must declare actions: read, or the gate cannot list deploy runs"
pass "the workflow requests actions: read for the gate's run lookups"

ISSUE_LOG="$TMP_ROOT/gh-issue.log"
: > "$ISSUE_LOG"
run_step_ok "$STEPS_DIR/notify.sh" "$TMP_ROOT/notify-labelled.log" \
  "GH_ISSUE_LOG=$ISSUE_LOG" \
  "REPO=acme/app" "SHA=$TIP" "TAG=v2026.9.24" "MODE=publish" \
  "RUN_URL=https://github.invalid/run/1"
assert_file_contains "$ISSUE_LOG" "--label release-automation"
pass "a failure opens a labelled release-automation issue"

: > "$ISSUE_LOG"
run_step_ok "$STEPS_DIR/notify.sh" "$TMP_ROOT/notify-unlabelled.log" \
  "GH_ISSUE_LOG=$ISSUE_LOG" "STUB_LABEL_EXISTS=false" \
  "REPO=acme/app" "SHA=$TIP" "TAG=v2026.9.24" "MODE=publish" \
  "RUN_URL=https://github.invalid/run/1"
assert_file_contains "$ISSUE_LOG" "issue create"
assert_file_not_contains "$ISSUE_LOG" "--label"
assert_file_contains "$TMP_ROOT/notify-unlabelled.log" "Missing label"
pass "a missing release-automation label still opens the alert, unlabelled"

echo
echo "All $pass_count checks passed."
