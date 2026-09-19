#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/codex-review-reusable.yml"
TMP_ROOT=${TMPDIR:-/tmp}/codex-review-workflow-test.$$
STEPS_DIR="$TMP_ROOT/steps"
STUB_DIR="$TMP_ROOT/bin"

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
  if ! grep -Fq "$pattern" "$file"; then
    echo "Expected to find '$pattern' in $file" >&2
    sed -n '1,160p' "$file" >&2 || true
    fail "missing expected text"
  fi
}

assert_file_not_contains() {
  local file=$1
  local pattern=$2
  if grep -Fq "$pattern" "$file"; then
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

materialize_post_step() {
  local output_file=$1

  cp "$STEPS_DIR/post-codex-review.sh" "$output_file"
  perl -0pi -e '
    s/\$\{\{ steps\.review_prepare\.outputs\.base_ref \}\}/$ENV{GHA_BASE_REF}/g;
    s/\$\{\{ steps\.review_prepare\.outputs\.head_ref \}\}/$ENV{GHA_HEAD_REF}/g;
    s/\$\{\{ steps\.review_prepare\.outputs\.base_sha \}\}/$ENV{GHA_BASE_SHA}/g;
    s/\$\{\{ steps\.review_prepare\.outputs\.head_sha \}\}/$ENV{GHA_HEAD_SHA}/g;
    s/\$\{\{ steps\.review_prepare\.outputs\.merge_base \}\}/$ENV{GHA_MERGE_BASE}/g;
    s/\$\{\{ steps\.review_prepare\.outputs\.prompt_chars \}\}/$ENV{GHA_PROMPT_CHARS}/g;
    s/\$\{\{ steps\.review_prepare\.outputs\.prompt_limit \}\}/$ENV{GHA_PROMPT_LIMIT}/g;
  ' "$output_file"
}

materialize_failure_step() {
  local output_file=$1

  cp "$STEPS_DIR/report-codex-review-failure.sh" "$output_file"
  perl -0pi -e 's/\$\{\{ steps\.codex_review\.outputs\.exit_code \|\| '\''unknown'\'' \}\}/$ENV{GHA_CODEX_EXIT_CODE}/g' "$output_file"
}

install_stubs() {
  mkdir -p "$STUB_DIR"

  cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1" = "api" ]; then
  base_ref=${BASE_REF:-main}
  head_ref=${HEAD_REF:-feature}
  base_sha=${BASE_SHA:?BASE_SHA is required}
  head_sha=${HEAD_SHA:?HEAD_SHA is required}

  if [ "${GH_LIVE_MODE:-match}" = "moved" ]; then
    base_ref=${CURRENT_BASE_REF:-$base_ref}
    head_ref=${CURRENT_HEAD_REF:-$head_ref}
    base_sha=${CURRENT_BASE_SHA:-1111111111111111111111111111111111111111}
    head_sha=${CURRENT_HEAD_SHA:-2222222222222222222222222222222222222222}
  fi

  jq -n \
    --arg title "Synthetic PR" \
    --arg url "https://github.invalid/example/pull/1" \
    --arg author "reviewer" \
    --arg base_ref "$base_ref" \
    --arg head_ref "$head_ref" \
    --arg base_sha "$base_sha" \
    --arg head_sha "$head_sha" \
    '{
      title: $title,
      html_url: $url,
      user: {login: $author},
      base: {ref: $base_ref, sha: $base_sha},
      head: {ref: $head_ref, sha: $head_sha}
    }'
  exit 0
fi

if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
  body_file=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --body-file)
        body_file=$2
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  if [ -z "$body_file" ]; then
    echo "missing --body-file" >&2
    exit 2
  fi

  {
    echo "--- comment ---"
    cat "$body_file"
    echo
  } >> "${GH_COMMENT_LOG:?GH_COMMENT_LOG is required}"
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 2
STUB
  chmod +x "$STUB_DIR/gh"

  cat > "$STUB_DIR/npx" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

echo "npx invoked" >> "${NPX_INVOKED_LOG:?NPX_INVOKED_LOG is required}"

review_file=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-last-message)
      review_file=$2
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

case "${CODEX_STUB_MODE:-success}" in
  success)
    printf "Didn't find any major issues.\n" > "${review_file:?missing review file}"
    echo "thread.started"
    exit 0
    ;;
  fail)
    echo "input_too_large from stderr-only path" >&2
    exit 37
    ;;
  missing)
    echo "thread.started"
    exit 0
    ;;
  *)
    echo "unknown CODEX_STUB_MODE: ${CODEX_STUB_MODE:-}" >&2
    exit 2
    ;;
esac
STUB
  chmod +x "$STUB_DIR/npx"
}

extract_steps() {
  mkdir -p "$STEPS_DIR"
  extract_step "Build review prompt" "$STEPS_DIR/build-review-prompt.sh"
  extract_step "Run Codex review" "$STEPS_DIR/run-codex-review.sh"
  extract_step "Report Codex review failure" "$STEPS_DIR/report-codex-review-failure.sh"
  extract_step "Post Codex review" "$STEPS_DIR/post-codex-review.sh"
}

configure_git_repo() {
  git config user.email "tests@example.invalid"
  git config user.name "Workflow Test"
}

create_multi_commit_fixture() {
  local repo=$1

  rm -rf "$repo"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  (
    cd "$repo"
    configure_git_repo
    printf "keep original\n" > keep.txt
    printf "rename me\n" > rename-me.txt
    printf "delete me\n" > delete-me.txt
    printf "one\ntwo\nthree\n" > partial.txt
    git add .
    git commit -q -m "base"

    git checkout -q -b feature
    printf "new final file\n" > added.txt
    git add added.txt
    git commit -q -m "add file"

    printf "keep changed\n" > keep.txt
    printf "one\ntwo changed\nthree changed\n" > partial.txt
    git add keep.txt partial.txt
    git commit -q -m "edit files"

    printf "one\ntwo changed\nthree\n" > partial.txt
    git add partial.txt
    git commit -q -m "partially revert edit"

    rm delete-me.txt
    git rm -q delete-me.txt
    git commit -q -m "delete file"

    git mv rename-me.txt renamed.txt
    git commit -q -m "rename file"

    git checkout -q main
    git merge -q --no-ff -m "merge pr" feature
  )
}

create_empty_diff_fixture() {
  local repo=$1

  rm -rf "$repo"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  (
    cd "$repo"
    configure_git_repo
    printf "same\n" > same.txt
    git add same.txt
    git commit -q -m "base"

    git checkout -q -b feature
    git commit -q --allow-empty -m "empty head"

    git checkout -q main
    git merge -q --no-ff -m "merge pr" feature
  )
}

create_unicode_fixture() {
  local repo=$1
  local char_count=$2

  rm -rf "$repo"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  (
    cd "$repo"
    configure_git_repo
    : > unicode.txt
    git add unicode.txt
    git commit -q -m "base"

    git checkout -q -b feature
    perl -CS -e 'binmode STDOUT, ":utf8"; print chr(0xE9) x $ARGV[0], "\n"' "$char_count" > unicode.txt
    git add unicode.txt
    git commit -q -m "unicode diff"

    git checkout -q main
    git merge -q --no-ff -m "merge pr" feature
  )
}

set_common_env() {
  local runner_temp=$1

  export PATH="$STUB_DIR:$PATH"
  export RUNNER_TEMP="$runner_temp"
  export GITHUB_OUTPUT="$runner_temp/github-output"
  export GH_COMMENT_LOG="$runner_temp/gh-comments.md"
  export NPX_INVOKED_LOG="$runner_temp/npx-invoked.log"
  export PR_NUMBER=1
  export REPO="example/caller"
  export COMMENT_ID=10
  export RUN_URL="https://github.invalid/example/actions/runs/1"
  export CODEX_CLI_PACKAGE="@openai/codex@0.154.0"
  export BASE_REF=main
  export HEAD_REF=feature
  export GH_LIVE_MODE=match

  mkdir -p "$runner_temp"
  : > "$GITHUB_OUTPUT"
  : > "$GH_COMMENT_LOG"
  : > "$NPX_INVOKED_LOG"
}

run_prepare() {
  local repo=$1
  local runner_temp=$2

  set_common_env "$runner_temp"
  (
    cd "$repo"
    bash "$STEPS_DIR/build-review-prompt.sh"
  )
}

read_output() {
  local key=$1
  awk -F= -v wanted="$key" '$1 == wanted {print substr($0, length($1) + 2)}' "$GITHUB_OUTPUT" | tail -n 1
}

load_prepare_outputs_for_expressions() {
  export GHA_BASE_REF
  export GHA_HEAD_REF
  export GHA_BASE_SHA
  export GHA_HEAD_SHA
  export GHA_MERGE_BASE
  export GHA_PROMPT_CHARS
  export GHA_PROMPT_LIMIT

  GHA_BASE_REF=$(read_output base_ref)
  GHA_HEAD_REF=$(read_output head_ref)
  GHA_BASE_SHA=$(read_output base_sha)
  GHA_HEAD_SHA=$(read_output head_sha)
  GHA_MERGE_BASE=$(read_output merge_base)
  GHA_PROMPT_CHARS=$(read_output prompt_chars)
  GHA_PROMPT_LIMIT=$(read_output prompt_limit)
}

test_cumulative_diff_and_manifest() {
  local repo="$TMP_ROOT/multi"
  local runner_temp="$TMP_ROOT/runner-multi"

  create_multi_commit_fixture "$repo"
  export BASE_SHA HEAD_SHA
  BASE_SHA=$(git -C "$repo" rev-parse HEAD^1)
  HEAD_SHA=$(git -C "$repo" rev-parse HEAD^2)

  run_prepare "$repo" "$runner_temp"

  assert_file_contains "$runner_temp/pr.diff" "new final file"
  assert_file_contains "$runner_temp/pr.diff" "keep changed"
  assert_file_contains "$runner_temp/pr.diff" "two changed"
  assert_file_not_contains "$runner_temp/pr.diff" "three changed"
  assert_file_contains "$runner_temp/pr.diff" "deleted file mode"
  assert_file_contains "$runner_temp/pr.name-status" "A"$'\t'"added.txt"
  assert_file_contains "$runner_temp/pr.name-status" "M"$'\t'"keep.txt"
  assert_file_contains "$runner_temp/pr.name-status" "M"$'\t'"partial.txt"
  assert_file_contains "$runner_temp/pr.name-status" "D"$'\t'"delete-me.txt"
  assert_file_contains "$runner_temp/pr.name-status" "R100"$'\t'"rename-me.txt"$'\t'"renamed.txt"
  assert_file_contains "$runner_temp/codex-review-prompt.md" "Reviewed base: main @ $BASE_SHA"
  assert_file_contains "$runner_temp/codex-review-prompt.md" "Reviewed head: feature @ $HEAD_SHA"

  pass "cumulative diff and manifest preserve final PR changes"
}

test_caller_context_has_no_production_helper_dependency() {
  local repo="$TMP_ROOT/caller-context"
  local runner_temp="$TMP_ROOT/runner-caller-context"

  if grep -Eq '(^|[[:space:]])(\./)?(tests/|scripts/|\.github/scripts/)' "$WORKFLOW_FILE"; then
    fail "workflow references repo-local test/helper paths"
  fi

  create_multi_commit_fixture "$repo"
  export BASE_SHA HEAD_SHA
  BASE_SHA=$(git -C "$repo" rev-parse HEAD^1)
  HEAD_SHA=$(git -C "$repo" rev-parse HEAD^2)

  if [ -e "$repo/tests" ] || [ -e "$repo/scripts" ] || [ -e "$repo/.github/scripts" ]; then
    fail "caller fixture unexpectedly contains helper paths"
  fi

  run_prepare "$repo" "$runner_temp"
  assert_file_contains "$runner_temp/codex-review-prompt.md" "Synthetic PR"

  pass "workflow shell runs from caller checkout without repo-local helpers"
}

test_empty_diff_and_revision_mismatch_fail_prepare() {
  local repo_empty="$TMP_ROOT/empty"
  local runner_empty="$TMP_ROOT/runner-empty"
  local repo_mismatch="$TMP_ROOT/mismatch"
  local runner_mismatch="$TMP_ROOT/runner-mismatch"

  create_empty_diff_fixture "$repo_empty"
  export BASE_SHA HEAD_SHA
  BASE_SHA=$(git -C "$repo_empty" rev-parse HEAD^1)
  HEAD_SHA=$(git -C "$repo_empty" rev-parse HEAD^2)
  if run_prepare "$repo_empty" "$runner_empty"; then
    fail "empty cumulative diff should fail preparation"
  fi
  assert_file_contains "$runner_empty/codex-review-prepare.log" "Cumulative PR diff is empty"

  create_multi_commit_fixture "$repo_mismatch"
  export BASE_SHA HEAD_SHA
  BASE_SHA=$(git -C "$repo_mismatch" rev-parse HEAD^2)
  HEAD_SHA=$(git -C "$repo_mismatch" rev-parse HEAD^2)
  if run_prepare "$repo_mismatch" "$runner_mismatch"; then
    fail "checkout parent mismatch should fail preparation"
  fi
  assert_file_contains "$runner_mismatch/codex-review-prepare.log" "merge base parent does not match"

  pass "empty diff and revision mismatch fail before Codex"
}

prepare_unicode_count() {
  local requested_chars=$1
  local repo="$TMP_ROOT/unicode-$requested_chars"
  local runner_temp="$TMP_ROOT/runner-unicode-$requested_chars"

  create_unicode_fixture "$repo" "$requested_chars"
  export BASE_SHA HEAD_SHA
  BASE_SHA=$(git -C "$repo" rev-parse HEAD^1)
  HEAD_SHA=$(git -C "$repo" rev-parse HEAD^2)

  if run_prepare "$repo" "$runner_temp" >/dev/null; then
    awk '/Prompt Unicode characters:/ { split($4, parts, "/"); print parts[1] }' "$runner_temp/codex-review-prepare.log" | tail -n 1
    return 0
  fi

  awk '/Prompt Unicode characters:/ { split($4, parts, "/"); print parts[1] }' "$runner_temp/codex-review-prepare.log" | tail -n 1
  return 1
}

test_unicode_prompt_limit_boundaries() {
  local one_char_prompt
  local target
  local required_chars
  local measured
  local status

  one_char_prompt=$(prepare_unicode_count 1)
  if [ -z "$one_char_prompt" ]; then
    fail "could not measure one-character unicode prompt"
  fi

  for target in 1048575 1048576; do
    required_chars=$((target - one_char_prompt + 1))
    if [ "$required_chars" -le 0 ]; then
      fail "unicode fixture overhead unexpectedly exceeds target"
    fi

    measured=$(prepare_unicode_count "$required_chars")
    if [ "$measured" != "$target" ]; then
      fail "expected prompt size $target, measured $measured"
    fi
  done

  target=1048577
  required_chars=$((target - one_char_prompt + 1))
  set +e
  measured=$(prepare_unicode_count "$required_chars")
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    fail "prompt over Codex limit should fail"
  fi
  if [ "$measured" != "$target" ]; then
    fail "expected oversized prompt size $target, measured $measured"
  fi

  pass "Unicode prompt limit allows limit and fails limit plus one"
}

prepare_runtime_fixture() {
  local repo="$TMP_ROOT/runtime"
  local runner_temp="$TMP_ROOT/runner-runtime"

  create_multi_commit_fixture "$repo"
  export BASE_SHA HEAD_SHA
  BASE_SHA=$(git -C "$repo" rev-parse HEAD^1)
  HEAD_SHA=$(git -C "$repo" rev-parse HEAD^2)
  run_prepare "$repo" "$runner_temp"
  load_prepare_outputs_for_expressions
}

test_codex_exit_capture_and_diagnostics() {
  local runner_temp="$TMP_ROOT/runner-runtime"
  local status
  local failure_step="$TMP_ROOT/report-failure-materialized.sh"

  prepare_runtime_fixture
  export CODEX_STUB_MODE=fail

  set +e
  bash "$STEPS_DIR/run-codex-review.sh"
  status=$?
  set -e

  if [ "$status" -ne 37 ]; then
    fail "expected Codex stub exit 37, got $status"
  fi
  assert_file_contains "$GITHUB_OUTPUT" "exit_code=37"
  assert_file_contains "$runner_temp/codex-review.log" "input_too_large from stderr-only path"

  export GHA_CODEX_EXIT_CODE=37
  materialize_failure_step "$failure_step"
  set +e
  bash "$failure_step"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    fail "failure reporting step should exit nonzero"
  fi
  assert_file_contains "$GH_COMMENT_LOG" "Exit code: 37"
  assert_file_contains "$GH_COMMENT_LOG" "input_too_large from stderr-only path"

  pass "Codex nonzero exit is captured with stderr diagnostics"
}

test_missing_output_cannot_reuse_stale_review() {
  local runner_temp="$TMP_ROOT/runner-runtime"
  local status

  prepare_runtime_fixture
  export CODEX_STUB_MODE=missing
  printf "stale clean verdict\n" > "$runner_temp/codex-review.md"

  set +e
  bash "$STEPS_DIR/run-codex-review.sh"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    fail "missing Codex output should fail"
  fi
  if [ -e "$runner_temp/codex-review.md" ]; then
    assert_file_not_contains "$runner_temp/codex-review.md" "stale clean verdict"
  fi
  assert_file_contains "$runner_temp/codex-review.log" "thread.started"

  pass "missing output cannot reuse stale review file"
}

test_success_and_stale_posting() {
  local runner_temp="$TMP_ROOT/runner-runtime"
  local status
  local post_step="$TMP_ROOT/post-materialized.sh"

  prepare_runtime_fixture
  export CODEX_STUB_MODE=success
  bash "$STEPS_DIR/run-codex-review.sh"

  materialize_post_step "$post_step"
  bash "$post_step"
  assert_file_contains "$GH_COMMENT_LOG" "## Codex Review"
  assert_file_contains "$GH_COMMENT_LOG" "Didn't find any major issues."
  assert_file_contains "$GH_COMMENT_LOG" "Reviewed revision metadata:"
  assert_file_contains "$GH_COMMENT_LOG" "Prompt Unicode characters: $GHA_PROMPT_CHARS/$GHA_PROMPT_LIMIT"

  : > "$GH_COMMENT_LOG"
  export GH_LIVE_MODE=moved
  export CURRENT_BASE_SHA="$GHA_BASE_SHA"
  export CURRENT_HEAD_SHA="3333333333333333333333333333333333333333"
  set +e
  bash "$post_step"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    fail "stale PR movement should fail posting"
  fi
  assert_file_contains "$GH_COMMENT_LOG" "pull request changed before the result could be posted as current"
  assert_file_not_contains "$GH_COMMENT_LOG" "Didn't find any major issues."

  pass "success posts metadata and moved PR posts stale failure"
}

main() {
  mkdir -p "$TMP_ROOT"
  extract_steps
  install_stubs

  test_cumulative_diff_and_manifest
  test_caller_context_has_no_production_helper_dependency
  test_empty_diff_and_revision_mismatch_fail_prepare
  test_unicode_prompt_limit_boundaries
  test_codex_exit_capture_and_diagnostics
  test_missing_output_cannot_reuse_stale_review
  test_success_and_stale_posting

  echo "1..$pass_count"
}

main "$@"
