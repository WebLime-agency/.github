#!/usr/bin/env bash
# shellcheck disable=SC2016 # Single-quoted GitHub expression literals are assertions, not expansions.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/vercel-staging-reusable.yml"
TMP_ROOT=${TMPDIR:-/tmp}/vercel-staging-workflow-test.$$
STEPS_DIR="$TMP_ROOT/steps"
STUB_DIR="$TMP_ROOT/bin"
export STUB_DIR

pass_count=0

cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    echo "keeping $TMP_ROOT" >&2
  else
    rm -rf "$TMP_ROOT"
  fi
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
    sed -n '1,220p' "$file" >&2 || true
    fail "missing expected text"
  fi
}

assert_file_not_contains() {
  local file=$1
  local pattern=$2
  if grep -Fq "$pattern" "$file"; then
    echo "Did not expect to find '$pattern' in $file" >&2
    sed -n '1,220p' "$file" >&2 || true
    fail "unexpected text present"
  fi
}

read_output() {
  local file=$1
  local key=$2
  awk -F= -v wanted="$key" '$1 == wanted {print substr($0, length($1) + 2)}' "$file" | tail -n 1
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

extract_step_block() {
  local step_name=$1
  local output_file=$2

  awk -v step="$step_name" '
    /^      - name: / {
      if (in_step) {
        exit
      }
      in_step = ($0 == "      - name: " step)
    }
    in_step {
      print
    }
  ' "$WORKFLOW_FILE" > "$output_file"

  if [ ! -s "$output_file" ]; then
    fail "could not extract workflow step block: $step_name"
  fi
}

extract_workflow_call_secrets() {
  awk '
    /^    secrets:/ {
      in_secrets = 1
      next
    }
    in_secrets && /^[^ ]/ {
      exit
    }
    in_secrets {
      print
    }
  ' "$WORKFLOW_FILE"
}

extract_steps() {
  mkdir -p "$STEPS_DIR"
  extract_step "Preflight trusted tools" "$STEPS_DIR/preflight.sh"
  extract_step "Verify exact source" "$STEPS_DIR/verify-source.sh"
  extract_step "Prepare staging aliases" "$STEPS_DIR/prepare-aliases.sh"
  extract_step "Vercel control-plane deploy/promote" "$STEPS_DIR/control-plane.sh"
  extract_step "Smoke staging candidate and aliases" "$STEPS_DIR/smoke.sh"
  extract_step "Finalize staging result" "$STEPS_DIR/finalize.sh"
}

materialize_preflight() {
  local output_file=$1

  cp "$STEPS_DIR/preflight.sh" "$output_file"
  perl -0pi -e '
    s#/usr/bin/stat#$ENV{STUB_DIR}/stat#g;
    s#/usr/bin/sha256sum#$ENV{STUB_DIR}/sha256sum#g;
    s#/usr/bin/python3#$ENV{STUB_DIR}/python3-trusted#g;
    s#/opt/weblime/vercel/56\.3\.1/vercel#$ENV{STUB_DIR}/vercel-trusted#g;
  ' "$output_file"
}

materialize_production_alias_prepare() {
  local output_file=$1

  cp "$STEPS_DIR/prepare-aliases.sh" "$output_file"
  perl -0pi -e 's/pythonlife\.org,staging\.lm\.fm/lm.fm,staging.lm.fm/g' "$output_file"
}

install_stubs() {
  mkdir -p "$STUB_DIR"

  cat > "$STUB_DIR/stat" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
path=${@: -1}
if [ "${BAD_OWNER_PATH:-}" = "$path" ]; then
  echo "1000 755"
  exit 0
fi
if [ "${BAD_MODE_PATH:-}" = "$path" ]; then
  echo "0 777"
  exit 0
fi
echo "0 755"
STUB
  chmod +x "$STUB_DIR/stat"

  cat > "$STUB_DIR/sha256sum" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${SHA_MODE:-match}" = "mismatch" ]; then
  echo "0000000000000000000000000000000000000000000000000000000000000000  $1"
else
  echo "c0e8cfad56746ea7a496604fc8b1e9ef71624d1784f07415a41777bdddb2536f  $1"
fi
STUB
  chmod +x "$STUB_DIR/sha256sum"

  cat > "$STUB_DIR/python3-trusted" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/bin/python3 "$@"
STUB
  chmod +x "$STUB_DIR/python3-trusted"

  cat > "$STUB_DIR/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  fetch)
    exit 0
    ;;
  rev-parse)
    case "$2" in
      HEAD)
        echo "${GIT_HEAD_SHA:-1111111111111111111111111111111111111111}"
        ;;
      refs/remotes/origin/dev)
        echo "${GIT_ORIGIN_DEV_SHA:-1111111111111111111111111111111111111111}"
        ;;
      *)
        echo "unexpected rev-parse target: $2" >&2
        exit 2
        ;;
    esac
    ;;
  status)
    printf '%s' "${GIT_STATUS_OUTPUT:-}"
    ;;
  *)
    echo "unexpected git invocation: $*" >&2
    exit 2
    ;;
esac
STUB
  chmod +x "$STUB_DIR/git"

  cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

args=("$@")
url=${!#}
write_out=""
config_requested=0
for ((i = 0; i < ${#args[@]}; i++)); do
  if [ "${args[$i]}" = "--write-out" ]; then
    write_out=${args[$((i + 1))]:-}
  fi
  if [ "${args[$i]}" = "--config" ] && [ "${args[$((i + 1))]:-}" = "-" ]; then
    config_requested=1
  fi
done

config=""
if [ "$config_requested" = "1" ]; then
  config="$(cat)"
fi

bypass_header=no
bypass_value=absent
if printf '%s\n' "$config" | grep -Fq 'x-vercel-protection-bypass:'; then
  bypass_header=yes
  header_line=$(printf '%s\n' "$config" | grep -F 'x-vercel-protection-bypass:' | head -n 1)
  if [ "$header_line" = "header = \"x-vercel-protection-bypass: ${EXPECTED_BYPASS_SECRET:?}\"" ]; then
    bypass_value=correct
  else
    bypass_value=incorrect
  fi
fi

env_has_secret=no
if [ -n "${VERCEL_AUTOMATION_BYPASS_SECRET:-}" ]; then
  env_has_secret=yes
fi

printf 'url=%s bypass_header=%s bypass_value=%s env_has_secret=%s\n' \
  "$url" "$bypass_header" "$bypass_value" "$env_has_secret" >> "${CURL_LOG:?}"
for arg in "${args[@]}"; do
  printf '%s\n' "$arg" >> "${CURL_ARGV_LOG:?}"
done

scenario=${CURL_SCENARIO:-success}
if [ "$scenario" = "fail" ]; then
  echo "curl: (22) synthetic failure" >&2
  exit 22
fi

candidate_url=${STUB_CANDIDATE_URL:-https://candidate.vercel.app}
if [ "$scenario" = "alias_login" ]; then
  if [ "$url" = "$candidate_url" ]; then
    printf '200 %s\n' "$url"
  else
    printf '200 https://vercel.com/login?sso=1\n'
  fi
  exit 0
fi
if [ "$scenario" = "candidate_login" ]; then
  printf '200 https://vercel.com/login?sso=1\n'
  exit 0
fi
if [ "$scenario" = "candidate_login_3xx" ]; then
  printf '307 https://vercel.com/login?sso=1\n'
  exit 0
fi

printf '200 %s\n' "$url"
STUB
  chmod +x "$STUB_DIR/curl"

  cat > "$STUB_DIR/vercel" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "PATH-resolved vercel must not run" >> "${PATH_VERCEL_MARKER:?}"
exit 96
STUB
  chmod +x "$STUB_DIR/vercel"

  cat > "$STUB_DIR/vercel-trusted" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

state_dir=${VERCEL_STATE_DIR:?}
log_file=${VERCEL_LOG:?}
mkdir -p "$state_dir"

alias_file() {
  local alias=$1
  alias=${alias//./_}
  printf '%s/%s.target\n' "$state_dir" "$alias"
}

if [ "${1:-}" = "--version" ]; then
  echo "${VERCEL_STUB_VERSION:-56.3.1}"
  exit 0
fi

case "${1:-}" in
  build)
    mkdir -p .vercel/output
    printf '{}\n' > .vercel/output/config.json
    echo "build" >> "$log_file"
    ;;
  deploy)
    echo "deploy" >> "$log_file"
    if [ "${VERCEL_MODE:-success}" = "deploy_malformed" ]; then
      echo "no deployment url here"
    else
      echo "https://candidate.vercel.app"
    fi
    ;;
  inspect)
    target=${2:?}
    echo "inspect $target" >> "$log_file"
    if [ "${VERCEL_MODE:-success}" = "malformed_inspect" ]; then
      echo "not json"
      exit 0
    fi
    case "$target" in
      https://candidate.vercel.app)
        printf '{"readyState":"READY","url":"candidate.vercel.app"}\n'
        ;;
      https://pythonlife.org|https://staging.lm.fm)
        alias=${target#https://}
        file=$(alias_file "$alias")
        if [ ! -f "$file" ]; then
          printf 'https://old-%s.vercel.app\n' "$alias" > "$file"
        fi
        read -r current < "$file"
        printf '{"readyState":"READY","target":"%s"}\n' "$current"
        ;;
      *)
        printf '{"readyState":"READY","target":"%s"}\n' "$target"
        ;;
    esac
    ;;
  alias)
    if [ "${2:-}" != "set" ]; then
      echo "unexpected alias invocation: $*" >&2
      exit 2
    fi
    target=${3:?}
    alias=${4:?}
    echo "alias set $target $alias" >> "$log_file"
    if [ "${FAIL_SECOND_ALIAS:-0}" = "1" ] && [ "$alias" = "staging.lm.fm" ] && [ "$target" = "https://candidate.vercel.app" ]; then
      exit 44
    fi
    if [ "${ROLLBACK_FAIL:-0}" = "1" ]; then
      case "$target" in
        https://old-*.vercel.app)
          exit 45
          ;;
      esac
    fi
    printf '%s\n' "$target" > "$(alias_file "$alias")"
    ;;
  *)
    echo "unexpected vercel invocation: $*" >&2
    exit 2
    ;;
esac
STUB
  chmod +x "$STUB_DIR/vercel-trusted"
}

run_script() {
  local script=$1
  local out_file=$2
  shift 2

  set +e
  ( env "$@" bash --noprofile --norc -e -o pipefail "$script" ) >"$out_file" 2>&1
  local status=$?
  set -e
  return "$status"
}

common_preflight_env() {
  export PATH="$STUB_DIR:$PATH"
  export GITHUB_OUTPUT="$TMP_ROOT/github-output"
  export EXPECTED_VERCEL_CLI_VERSION=56.3.1
  export VERCEL_STATE_DIR="$TMP_ROOT/vercel-state"
  export VERCEL_LOG="$TMP_ROOT/vercel.log"
  export PATH_VERCEL_MARKER="$TMP_ROOT/path-vercel-marker"
  unset BAD_OWNER_PATH BAD_MODE_PATH SHA_MODE VERCEL_STUB_VERSION
  : > "$GITHUB_OUTPUT"
  : > "$VERCEL_LOG"
  : > "$PATH_VERCEL_MARKER"
}

test_static_contract() {
  local token_env_count

  assert_file_contains "$WORKFLOW_FILE" "environment: staging"
  assert_file_contains "$WORKFLOW_FILE" "group: vercel-staging-\${{ github.repository }}"
  assert_file_contains "$WORKFLOW_FILE" "path: src-\${{ github.run_id }}-\${{ github.run_attempt }}"
  assert_file_contains "$WORKFLOW_FILE" "persist-credentials: false"
  assert_file_contains "$WORKFLOW_FILE" "clean: true"
  assert_file_contains "$WORKFLOW_FILE" "fetch-depth: 0"
  assert_file_contains "$WORKFLOW_FILE" "https://github.com/eba8/mission-control/issues/413"
  assert_file_contains "$WORKFLOW_FILE" "dedicated"
  assert_file_not_contains "$WORKFLOW_FILE" "upload-artifact"
  assert_file_not_contains "$WORKFLOW_FILE" "download-artifact"
  assert_file_not_contains "$WORKFLOW_FILE" "npm install -g vercel"
  assert_file_not_contains "$WORKFLOW_FILE" "vercel pull"

  token_env_count=$(grep -Fc 'VERCEL_TOKEN: ${{ secrets.VERCEL_TOKEN }}' "$WORKFLOW_FILE")
  if [ "$token_env_count" -ne 1 ]; then
    fail "VERCEL_TOKEN must appear in exactly one step env, found $token_env_count"
  fi

  # Optional Protection Bypass secret: declared once in workflow_call, and its
  # value referenced only in the smoke step env.
  local bypass_call_decl bypass_env_count
  bypass_call_decl=$(extract_workflow_call_secrets)
  if ! printf '%s\n' "$bypass_call_decl" | grep -Fq "VERCEL_AUTOMATION_BYPASS_SECRET:"; then
    fail "workflow_call must declare the optional VERCEL_AUTOMATION_BYPASS_SECRET"
  fi
  if ! printf '%s\n' "$bypass_call_decl" | grep -Fq "required: false"; then
    fail "VERCEL_AUTOMATION_BYPASS_SECRET must be optional (required: false)"
  fi

  bypass_env_count=$(grep -Fc 'VERCEL_AUTOMATION_BYPASS_SECRET: ${{ secrets.VERCEL_AUTOMATION_BYPASS_SECRET }}' "$WORKFLOW_FILE")
  if [ "$bypass_env_count" -ne 1 ]; then
    fail "the bypass secret must be wired into exactly one env block, found $bypass_env_count"
  fi

  extract_step_block "Smoke staging candidate and aliases" "$TMP_ROOT/smoke-block.yml"
  extract_step_block "Vercel control-plane deploy/promote" "$TMP_ROOT/control-block.yml"
  extract_step_block "Build Vercel staging output" "$TMP_ROOT/build-block.yml"
  extract_step_block "Finalize staging result" "$TMP_ROOT/finalize-block.yml"

  if ! grep -Fq 'VERCEL_AUTOMATION_BYPASS_SECRET: ${{ secrets.VERCEL_AUTOMATION_BYPASS_SECRET }}' "$TMP_ROOT/smoke-block.yml"; then
    fail "the bypass secret must be in the smoke step env"
  fi
  local block
  for block in control build finalize; do
    if grep -Fq "VERCEL_AUTOMATION_BYPASS_SECRET" "$TMP_ROOT/$block-block.yml"; then
      fail "the bypass secret must not appear in the $block step"
    fi
  done
  if grep -Fq "set -x" "$STEPS_DIR/control-plane.sh"; then
    fail "token-bearing control-plane step must not enable shell tracing"
  fi
  if grep -Fq "set -x" "$STEPS_DIR/smoke.sh"; then
    fail "smoke step must not enable shell tracing"
  fi
  if ! grep -Fq "VERCEL_AUTOMATION_BYPASS_SECRET not configured" "$TMP_ROOT/smoke-block.yml"; then
    fail "the smoke step must fail closed with the documented missing-secret message"
  fi
  if grep -Fq "::warning::" "$TMP_ROOT/smoke-block.yml"; then
    fail "the smoke step must not downgrade the missing bypass secret to a warning"
  fi

  pass "static workflow contract is artifact-free and secrets are step-scoped"
}

test_preflight_vercel_cli() {
  local script="$TMP_ROOT/preflight-materialized.sh"
  local out="$TMP_ROOT/preflight.out"

  common_preflight_env
  materialize_preflight "$script"
  run_script "$script" "$out" || fail "preflight happy path should pass"
  assert_file_contains "$GITHUB_OUTPUT" "vercel=$STUB_DIR/vercel-trusted"
  if [ -s "$PATH_VERCEL_MARKER" ]; then
    fail "PATH-resolved vercel was invoked"
  fi

  common_preflight_env
  run_script "$script" "$out" VERCEL_STUB_VERSION=99.0.0 && fail "version mismatch should fail"
  assert_file_contains "$out" "Vercel CLI version mismatch"

  common_preflight_env
  run_script "$script" "$out" SHA_MODE=mismatch && fail "hash mismatch should fail"
  assert_file_contains "$out" "Vercel CLI hash mismatch"

  common_preflight_env
  run_script "$script" "$out" BAD_OWNER_PATH="$STUB_DIR/vercel-trusted" && fail "non-root CLI should fail"
  assert_file_contains "$out" "Untrusted vercel owner"

  common_preflight_env
  run_script "$script" "$out" BAD_MODE_PATH="$STUB_DIR/git" && fail "writable git should fail"
  assert_file_contains "$out" "Unsafe git permissions"

  # A symlink whose target lives under a writable directory must be rejected
  # even though the lexical path itself looks safe.
  mkdir -p "$STUB_DIR/untrusted"
  cp "$STUB_DIR/vercel-trusted" "$STUB_DIR/untrusted/vercel-trusted"
  mv "$STUB_DIR/vercel-trusted" "$STUB_DIR/vercel-trusted.real"
  ln -s "$STUB_DIR/untrusted/vercel-trusted" "$STUB_DIR/vercel-trusted"
  common_preflight_env
  run_script "$script" "$out" BAD_MODE_PATH="$STUB_DIR/untrusted" && fail "symlink into a writable directory should fail"
  assert_file_contains "$out" "Unsafe vercel resolved permissions"
  unlink "$STUB_DIR/vercel-trusted"
  mv "$STUB_DIR/vercel-trusted.real" "$STUB_DIR/vercel-trusted"

  pass "A1 tool and Vercel CLI preflight fails closed"
}

test_verify_exact_source() {
  local out="$TMP_ROOT/verify.out"

  export GITHUB_OUTPUT="$TMP_ROOT/verify-output"
  export GIT_BIN="$STUB_DIR/git"
  export EXPECTED_SHA=1111111111111111111111111111111111111111
  run_script "$STEPS_DIR/verify-source.sh" "$out" GIT_HEAD_SHA=$EXPECTED_SHA GIT_STATUS_OUTPUT= || fail "matching SHA should pass"

  run_script "$STEPS_DIR/verify-source.sh" "$out" GIT_HEAD_SHA=2222222222222222222222222222222222222222 GIT_STATUS_OUTPUT= && fail "mismatched SHA should fail"
  assert_file_contains "$out" "Unexpected checkout SHA"

  run_script "$STEPS_DIR/verify-source.sh" "$out" GIT_HEAD_SHA=$EXPECTED_SHA GIT_STATUS_OUTPUT="?? stale.txt" && fail "dirty checkout should fail"
  assert_file_contains "$out" "Dirty checkout"

  pass "A2 exact-source binding rejects mismatched or dirty checkouts"
}

test_prepare_alias_allowlist() {
  local out="$TMP_ROOT/prepare.out"
  local output="$TMP_ROOT/prepare-output"
  local prod_script="$TMP_ROOT/prepare-production-alias.sh"

  export GITHUB_OUTPUT="$output"
  export GIT_BIN="$STUB_DIR/git"
  : > "$GITHUB_OUTPUT"
  run_script "$STEPS_DIR/prepare-aliases.sh" "$out" GITHUB_REPOSITORY_NAME=WebLime-agency/limey-web-app GIT_ORIGIN_DEV_SHA=abc || fail "limey allowlist should pass"
  if [ "$(read_output "$GITHUB_OUTPUT" aliases)" != "pythonlife.org,staging.lm.fm" ]; then
    fail "limey allowlist was not deterministic and fixed"
  fi

  : > "$GITHUB_OUTPUT"
  run_script "$STEPS_DIR/prepare-aliases.sh" "$out" GITHUB_REPOSITORY_NAME=WebLime-agency/unknown GIT_ORIGIN_DEV_SHA=abc && fail "unknown repository should fail"
  assert_file_contains "$out" "Unsupported staging repository"

  materialize_production_alias_prepare "$prod_script"
  : > "$GITHUB_OUTPUT"
  run_script "$prod_script" "$out" GITHUB_REPOSITORY_NAME=WebLime-agency/limey-web-app GIT_ORIGIN_DEV_SHA=abc && fail "production alias should fail"
  assert_file_contains "$out" "Production domain refused"

  pass "staging aliases are fail-closed and per-repository"
}

set_control_env() {
  export PATH="$STUB_DIR:$PATH"
  export GITHUB_OUTPUT="$TMP_ROOT/control-output"
  export EXPECTED_SHA=1111111111111111111111111111111111111111
  export ORIGIN_DEV_SHA=1111111111111111111111111111111111111111
  export STAGING_ALIASES=pythonlife.org,staging.lm.fm
  export NEUTRAL_DIR="$TMP_ROOT/neutral"
  export JQ_BIN=/usr/bin/jq
  export PYTHON_BIN=/usr/bin/python3
  export VERCEL_BIN="$STUB_DIR/vercel-trusted"
  export VERCEL_ORG_ID=org
  export VERCEL_PROJECT_ID=project
  export VERCEL_TOKEN=synthetic-secret-token
  export VERCEL_STATE_DIR="$TMP_ROOT/vercel-state"
  export VERCEL_LOG="$TMP_ROOT/vercel.log"
  export GITHUB_RUN_ID=99
  export GITHUB_RUN_ATTEMPT=1
  rm -rf "$VERCEL_STATE_DIR"
  mkdir -p "$NEUTRAL_DIR" "$VERCEL_STATE_DIR"
  : > "$GITHUB_OUTPUT"
  : > "$VERCEL_LOG"
}

test_control_plane_success_and_superseded() {
  local out="$TMP_ROOT/control.out"

  set_control_env
  touch "$NEUTRAL_DIR/re.py" "$NEUTRAL_DIR/sitecustomize.py" "$NEUTRAL_DIR/usercustomize.py"
  run_script "$STEPS_DIR/control-plane.sh" "$out" PYTHONPATH="$NEUTRAL_DIR" PYTHONSTARTUP="$NEUTRAL_DIR/re.py" HOME="$NEUTRAL_DIR" || fail "control success should pass"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "success" ]; then
    fail "successful control step did not emit success"
  fi
  assert_file_contains "$VERCEL_LOG" "alias set https://candidate.vercel.app pythonlife.org"
  assert_file_contains "$VERCEL_LOG" "alias set https://candidate.vercel.app staging.lm.fm"
  assert_file_not_contains "$out" "synthetic-secret-token"

  set_control_env
  run_script "$STEPS_DIR/control-plane.sh" "$out" ORIGIN_DEV_SHA=2222222222222222222222222222222222222222 || fail "superseded should be a managed result"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "superseded" ]; then
    fail "superseded guard did not emit superseded"
  fi
  assert_file_not_contains "$VERCEL_LOG" "alias set https://candidate.vercel.app"

  pass "control plane promotes deterministically and rejects stale SHA before aliases"
}

test_control_plane_failure_modes() {
  local out="$TMP_ROOT/control-fail.out"

  set_control_env
  run_script "$STEPS_DIR/control-plane.sh" "$out" VERCEL_MODE=malformed_inspect || fail "malformed inspect is managed"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "failed" ]; then
    fail "malformed inspect should emit failed"
  fi
  assert_file_not_contains "$VERCEL_LOG" "alias set https://candidate.vercel.app"

  set_control_env
  run_script "$STEPS_DIR/control-plane.sh" "$out" FAIL_SECOND_ALIAS=1 || fail "second alias failure should be managed"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "rolled_back" ]; then
    fail "second alias failure should emit rolled_back"
  fi
  assert_file_contains "$VERCEL_LOG" "alias set https://old-pythonlife.org.vercel.app pythonlife.org"
  assert_file_contains "$VERCEL_LOG" "alias set https://old-staging.lm.fm.vercel.app staging.lm.fm"
  assert_file_not_contains "$out" "synthetic-secret-token"

  set_control_env
  run_script "$STEPS_DIR/control-plane.sh" "$out" FAIL_SECOND_ALIAS=1 ROLLBACK_FAIL=1 || fail "rollback failure should be managed"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "rollback_failed" ]; then
    fail "rollback failure should emit rollback_failed"
  fi
  assert_file_contains "$out" "Rollback alias set failed"
  assert_file_not_contains "$out" "synthetic-secret-token"

  pass "control-plane failures roll back or incident without leaking token"
}

set_smoke_env() {
  export PATH="$STUB_DIR:$PATH"
  export GITHUB_OUTPUT="$TMP_ROOT/smoke-output"
  export CURL_BIN="$STUB_DIR/curl"
  export CURL_LOG="$TMP_ROOT/curl.log"
  export CURL_ARGV_LOG="$TMP_ROOT/curl-argv.log"
  export DEPLOYMENT_URL=https://candidate.vercel.app
  export PROMOTED_ALIASES=pythonlife.org,staging.lm.fm
  export VERCEL_STATE_DIR="$TMP_ROOT/vercel-state"
  export VERCEL_LOG="$TMP_ROOT/vercel.log"
  unset CURL_SCENARIO VERCEL_AUTOMATION_BYPASS_SECRET EXPECTED_BYPASS_SECRET
  : > "$GITHUB_OUTPUT"
  : > "$CURL_LOG"
  : > "$CURL_ARGV_LOG"
  : > "$VERCEL_LOG"
}

test_post_promotion_smoke_incident() {
  local out="$TMP_ROOT/smoke.out"
  local vercel_log_before
  local vercel_log_after

  set_smoke_env
  vercel_log_before=$(wc -c < "$VERCEL_LOG")
  run_script "$STEPS_DIR/smoke.sh" "$out" CURL_SCENARIO=fail || fail "smoke failure should be managed"
  vercel_log_after=$(wc -c < "$VERCEL_LOG")
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "failed" ]; then
    fail "smoke failure should emit failed"
  fi
  if [ "$vercel_log_before" != "$vercel_log_after" ]; then
    fail "smoke failure attempted a token-bearing Vercel rollback"
  fi
  assert_file_contains "$out" "manual-recovery incident"

  pass "post-promotion smoke failure is a manual-recovery incident"
}

test_smoke_bypass_header_candidate_only() {
  local out="$TMP_ROOT/smoke-bypass.out"
  local candidate_line

  set_smoke_env
  run_script "$STEPS_DIR/smoke.sh" "$out" \
    VERCEL_AUTOMATION_BYPASS_SECRET=synthetic-bypass-value \
    EXPECTED_BYPASS_SECRET=synthetic-bypass-value || fail "bypass smoke should pass"

  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "success" ]; then
    fail "bypass smoke should emit success"
  fi

  candidate_line=$(grep -F 'url=https://candidate.vercel.app ' "$CURL_LOG" || true)
  if [ -z "$candidate_line" ] || [[ "$candidate_line" != *"bypass_header=yes"* ]]; then
    echo "curl log:" >&2
    cat "$CURL_LOG" >&2 || true
    fail "candidate smoke did not send the protection bypass header"
  fi
  if [[ "$candidate_line" != *"bypass_value=correct"* ]]; then
    echo "curl log:" >&2
    cat "$CURL_LOG" >&2 || true
    fail "candidate smoke did not send the configured bypass value"
  fi
  if [[ "$candidate_line" == *"env_has_secret=yes"* ]]; then
    fail "the bypass secret must not be inherited by the candidate curl process"
  fi

  for alias in pythonlife.org staging.lm.fm; do
    local alias_line
    alias_line=$(grep -F "url=https://${alias} " "$CURL_LOG" || true)
    if [ -z "$alias_line" ]; then
      fail "alias $alias was not smoked"
    fi
    if [[ "$alias_line" == *"bypass_header=yes"* ]]; then
      fail "alias $alias must be smoked without the bypass header"
    fi
    if [[ "$alias_line" == *"env_has_secret=yes"* ]]; then
      fail "alias $alias must not inherit the bypass secret"
    fi
  done

  if ! grep -Fq -- "--config" "$CURL_ARGV_LOG"; then
    fail "candidate smoke must feed the header through curl config on stdin"
  fi

  assert_file_not_contains "$CURL_ARGV_LOG" "synthetic-bypass-value"
  assert_file_not_contains "$CURL_LOG" "synthetic-bypass-value"
  assert_file_not_contains "$out" "synthetic-bypass-value"

  pass "bypass header applies to the candidate only and stays out of argv/logs"
}

test_smoke_without_bypass_fails_closed() {
  local out="$TMP_ROOT/smoke-no-bypass.out"
  local curl_count

  set_smoke_env
  run_script "$STEPS_DIR/smoke.sh" "$out" || fail "missing bypass is a managed smoke failure"

  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "failed" ]; then
    fail "missing bypass must fail the staging gate closed"
  fi

  assert_file_contains "$out" "::error"
  assert_file_contains "$out" "VERCEL_AUTOMATION_BYPASS_SECRET not configured"
  assert_file_not_contains "$out" "::warning::"
  assert_file_not_contains "$out" "smoke skipped"

  if grep -Fq "url=https://candidate.vercel.app " "$CURL_LOG"; then
    fail "candidate must not be smoked when the bypass secret is absent"
  fi
  curl_count=$(wc -l < "$CURL_LOG")
  if [ "$curl_count" -ne 2 ]; then
    echo "curl log:" >&2
    cat "$CURL_LOG" >&2 || true
    fail "expected both aliases and only both aliases to be smoked, got $curl_count request(s)"
  fi
  if grep -Fq "bypass_header=yes" "$CURL_LOG"; then
    fail "alias smoke must stay tokenless"
  fi

  pass "absent bypass fails closed with the required error and no skip path"
}

test_smoke_login_redirect_is_failure() {
  local out="$TMP_ROOT/smoke-login.out"

  set_smoke_env
  run_script "$STEPS_DIR/smoke.sh" "$out" CURL_SCENARIO=candidate_login \
    VERCEL_AUTOMATION_BYPASS_SECRET=synthetic-bypass-value || fail "login redirect is a managed smoke failure"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "failed" ]; then
    fail "candidate login redirect must fail the smoke"
  fi
  assert_file_contains "$out" "manual-recovery incident"

  set_smoke_env
  run_script "$STEPS_DIR/smoke.sh" "$out" CURL_SCENARIO=candidate_login_3xx \
    VERCEL_AUTOMATION_BYPASS_SECRET=synthetic-bypass-value || fail "3xx login redirect is a managed smoke failure"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "failed" ]; then
    fail "candidate 3xx login redirect must fail the smoke"
  fi

  set_smoke_env
  run_script "$STEPS_DIR/smoke.sh" "$out" CURL_SCENARIO=alias_login \
    VERCEL_AUTOMATION_BYPASS_SECRET=synthetic-bypass-value || fail "alias login redirect is a managed smoke failure"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "failed" ]; then
    fail "alias login redirect must fail the smoke, even with a bypass secret"
  fi
  assert_file_contains "$out" "manual-recovery incident"

  set_smoke_env
  run_script "$STEPS_DIR/smoke.sh" "$out" CURL_SCENARIO=alias_login || fail "alias login redirect is a managed smoke failure"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "failed" ]; then
    fail "alias login redirect must fail the smoke without a bypass secret"
  fi

  pass "Vercel login/SSO redirects fail the smoke instead of passing"
}

test_smoke_rejects_unsafe_bypass_value() {
  local out="$TMP_ROOT/smoke-unsafe.out"

  set_smoke_env
  run_script "$STEPS_DIR/smoke.sh" "$out" \
    'VERCEL_AUTOMATION_BYPASS_SECRET=bad"value' || fail "unsafe bypass value is a managed smoke failure"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "failed" ]; then
    fail "unsafe bypass value must fail the smoke before any request"
  fi
  assert_file_contains "$out" "Invalid protection bypass secret"
  if grep -Fq "url=https://candidate.vercel.app " "$CURL_LOG"; then
    fail "unsafe bypass value must not trigger a candidate request"
  fi
  if grep -Fq "bypass_header=yes" "$CURL_LOG"; then
    fail "unsafe bypass value must never be written into a curl config"
  fi
  assert_file_not_contains "$out" 'bad"value'

  pass "bypass value is validated before it is written into the curl config"
}

test_finalize_result_gate() {
  local out="$TMP_ROOT/finalize.out"
  local output="$TMP_ROOT/finalize-output"

  export GITHUB_OUTPUT="$output"
  export CONTROL_RESULT=success
  export SMOKE_RESULT=
  export DEPLOYMENT_URL=https://candidate.vercel.app
  export PROMOTED_ALIASES=pythonlife.org,staging.lm.fm
  : > "$GITHUB_OUTPUT"
  run_script "$STEPS_DIR/finalize.sh" "$out" || fail "success finalization should pass"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "success" ]; then
    fail "finalize did not preserve success"
  fi

  : > "$GITHUB_OUTPUT"
  run_script "$STEPS_DIR/finalize.sh" "$out" CONTROL_RESULT=rolled_back SMOKE_RESULT= && fail "rolled_back finalization should fail the job"
  assert_file_contains "$out" "result=rolled_back"

  pass "final step preserves outputs and gates failing results"
}

test_shell_validation() {
  local script

  for script in "$STEPS_DIR"/*.sh; do
    bash -n "$script"
  done

  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -s bash -e SC2016,SC2154 "$STEPS_DIR"/*.sh
  fi

  pass "extracted workflow shell validates"
}

extract_steps
install_stubs
test_static_contract
test_preflight_vercel_cli
test_verify_exact_source
test_prepare_alias_allowlist
test_control_plane_success_and_superseded
test_control_plane_failure_modes
test_post_promotion_smoke_incident
test_smoke_bypass_header_candidate_only
test_smoke_without_bypass_fails_closed
test_smoke_login_redirect_is_failure
test_smoke_rejects_unsafe_bypass_value
test_finalize_result_gate
test_shell_validation

echo "All $pass_count vercel staging workflow tests passed."
