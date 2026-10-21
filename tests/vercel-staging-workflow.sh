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
  extract_step "Build Vercel staging output" "$STEPS_DIR/build.sh"
  extract_step "Prepare staging aliases" "$STEPS_DIR/prepare-aliases.sh"
  extract_step "Prepare staging deploy context" "$STEPS_DIR/deploy-context.sh"
  extract_step "Clean staging deploy context" "$STEPS_DIR/cleanup-context.sh"
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
    s#/usr/bin/node#$ENV{STUB_DIR}/node-trusted#g;
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

  cat > "$STUB_DIR/node-trusted" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

echo "node" >> "${NODE_LOG:?}"
printf 'node-cwd=%s\n' "$PWD" >> "${NODE_LOG:?}"
printf 'node-options=%s\n' "${NODE_OPTIONS:-}" >> "${NODE_LOG:?}"
printf 'node-path=%s\n' "${NODE_PATH:-}" >> "${NODE_LOG:?}"
if [ "${NODE_FORCE_FAIL:-0}" = "1" ]; then
  echo "synthetic node startup failure" >&2
  exit 97
fi
if [ "${1:-}" = "--version" ]; then
  exec /usr/bin/node --version
fi
while [ -n "${1:-}" ] && [ "${1#-}" != "$1" ] && [ "${1:-}" != "--" ]; do
  shift
done
if [ "${1:-}" = "--" ]; then
  shift
fi
script=${1:?}
shift
exec /usr/bin/node "$script" "$@"
STUB
  chmod +x "$STUB_DIR/node-trusted"

  cat > "$STUB_DIR/node" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "PATH-resolved node must not run" >> "${PATH_NODE_MARKER:?}"
exit 98
STUB
  chmod +x "$STUB_DIR/node"

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
defaults_disabled=no
if [ "${args[0]:-}" = "--disable" ] || [ "${args[0]:-}" = "-q" ]; then
  defaults_disabled=yes
fi
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

follows_redirects=no
for arg in "${args[@]}"; do
  if [ "$arg" = "--location" ] || [ "$arg" = "-L" ]; then
    follows_redirects=yes
  fi
done

# Model curl's documented default-config behavior: unless -q/--disable is the
# first argument, an inherited .curlrc can re-enable redirects or verbose
# tracing even when --location is absent from argv.
default_config_used=no
if [ "$defaults_disabled" = "no" ] && [ -f "${HOME:-}/.curlrc" ]; then
  default_config_used=yes
  if grep -Eq '(^|[[:space:]])location([[:space:]]|$)' "${HOME}/.curlrc"; then
    follows_redirects=yes
  fi
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

printf 'url=%s bypass_header=%s bypass_value=%s env_has_secret=%s follows_redirects=%s defaults_disabled=%s default_config_used=%s\n' \
  "$url" "$bypass_header" "$bypass_value" "$env_has_secret" "$follows_redirects" "$defaults_disabled" "$default_config_used" >> "${CURL_LOG:?}"
printf 'first_arg=%s\n' "${args[0]:-}" >> "${CURL_LOG:?}"
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
    printf '200 %s\n' "${LOGIN_URL:-https://vercel.com/login?sso=1}"
  fi
  exit 0
fi
if [ "$scenario" = "candidate_login" ] && [ "$url" = "$candidate_url" ]; then
  printf '200 %s\n' "${LOGIN_URL:-https://vercel.com/login?sso=1}"
  exit 0
fi
if [ "$scenario" = "candidate_login_3xx" ] && [ "$url" = "$candidate_url" ]; then
  printf '307 %s\n' "${LOGIN_URL:-https://vercel.com/login?sso=1}"
  exit 0
fi
if [ "$scenario" = "candidate_redirect_3xx" ]; then
  if [ "$follows_redirects" = "yes" ]; then
    printf '200 %s\n' "$url"
  else
    printf '302 https://elsewhere.example.com/landing\n'
  fi
  exit 0
fi
if [ "$scenario" = "candidate_transport_fail" ]; then
  printf '200 %s\n' "$url"
  echo "curl: (28) synthetic timeout after response headers" >&2
  exit 28
fi
if [ "$scenario" = "alias_transport_fail" ] && [ "$url" != "$candidate_url" ]; then
  printf '200 %s\n' "$url"
  echo "curl: (28) synthetic timeout after response headers" >&2
  exit 28
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
#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const stateDir = process.env.VERCEL_STATE_DIR;
const logFile = process.env.VERCEL_LOG;
if (!stateDir || !logFile) {
  console.error('VERCEL_STATE_DIR and VERCEL_LOG are required');
  process.exit(2);
}
fs.mkdirSync(stateDir, { recursive: true });

const mode = process.env.VERCEL_MODE || 'success';

function log(line) {
  fs.appendFileSync(logFile, line + '\n');
}

function aliasFile(alias) {
  return path.join(stateDir, alias.split('.').join('_') + '.target');
}

const argv = process.argv.slice(2);
const command = argv[0];

if (command === '--version') {
  process.stdout.write((process.env.VERCEL_STUB_VERSION || '56.3.1') + '\n');
  process.exit(0);
}

switch (command) {
  case 'build':
    if (process.env.VERCEL_TOKEN) throw new Error('build must be tokenless');
    // vercel@56.3.1 dist/commands/build/index.js readProjectSettings contract.
    if (!fs.existsSync('.vercel/project.json') || !JSON.parse(fs.readFileSync('.vercel/project.json', 'utf8')).settings) {
      console.error('No Project Settings found locally');
      process.exit(1);
    }
    log('build-settings ' + JSON.stringify(JSON.parse(fs.readFileSync('.vercel/project.json', 'utf8'))));
    fs.mkdirSync(path.join('.vercel', 'output'), { recursive: true });
    fs.writeFileSync(path.join('.vercel', 'output', 'config.json'), JSON.stringify({ version: 3, fixture: 'fresh-' + process.env.EXPECTED_SHA }) + '\n');
    log('build');
    break;
  case 'deploy': {
    const cwdIndex = argv.indexOf('--cwd');
    const deployDir = cwdIndex === -1 ? process.cwd() : argv[cwdIndex + 1];
    // Pinned deploy compiles programmatic config BEFORE the prebuilt branch.
    for (const ext of ['ts', 'mts', 'js', 'mjs', 'cjs']) {
      const file = path.join(deployDir, 'vercel.' + ext);
      if (fs.existsSync(file)) new Function('require', fs.readFileSync(file, 'utf8'))(require);
    }
    const config = path.join(deployDir, '.vercel', 'output', 'config.json');
    log('deploy-cwd ' + deployDir);
    if (!fs.existsSync(config)) {
      console.error('missing synthetic prebuilt output');
      process.exit(46);
    }
    // Model CLI cwd/prebuilt resolution, without enforcing workflow binding:
    // a stale output would really be deployed if the workflow selects it.
    log('deployed-fixture ' + JSON.parse(fs.readFileSync(config, 'utf8')).fixture);
    log('deploy');
    if (mode === 'deploy_malformed') {
      process.stdout.write('no deployment url here\n');
    } else {
      process.stdout.write('https://candidate.vercel.app\n');
    }
    break;
  }
  case 'inspect': {
    const target = argv[1];
    if (!target) {
      console.error('inspect requires a target');
      process.exit(2);
    }
    log('inspect ' + target);
    if (mode === 'malformed_inspect') {
      process.stdout.write('not json\n');
      break;
    }
    if (target === 'https://candidate.vercel.app') {
      process.stdout.write(JSON.stringify({ readyState: 'READY', url: 'candidate.vercel.app' }) + '\n');
      break;
    }
    if (target === 'https://pythonlife.org' || target === 'https://staging.lm.fm') {
      const alias = target.slice('https://'.length);
      const file = aliasFile(alias);
      if (!fs.existsSync(file)) {
        fs.writeFileSync(file, 'https://old-' + alias + '.vercel.app\n');
      }
      const current = fs.readFileSync(file, 'utf8').split('\n')[0];
      process.stdout.write(JSON.stringify({ readyState: 'READY', target: current }) + '\n');
      break;
    }
    process.stdout.write(JSON.stringify({ readyState: 'READY', target }) + '\n');
    break;
  }
  case 'alias': {
    if (argv[1] !== 'set') {
      console.error('unexpected alias invocation: ' + argv.join(' '));
      process.exit(2);
    }
    const target = argv[2];
    const alias = argv[3];
    if (!target || !alias) {
      console.error('alias set requires a target and an alias');
      process.exit(2);
    }
    log('alias set ' + target + ' ' + alias);
    if (process.env.FAIL_SECOND_ALIAS === '1' && alias === 'staging.lm.fm' && target === 'https://candidate.vercel.app') {
      process.exit(44);
    }
    if (process.env.ROLLBACK_FAIL === '1' && target.startsWith('https://old-') && target.endsWith('.vercel.app')) {
      process.exit(45);
    }
    fs.writeFileSync(aliasFile(alias), target + '\n');
    break;
  }
  default:
    console.error('unexpected vercel invocation: ' + argv.join(' '));
    process.exit(2);
}

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
  export PATH_NODE_MARKER="$TMP_ROOT/path-node-marker"
  export NODE_LOG="$TMP_ROOT/node.log"
  unset BAD_OWNER_PATH BAD_MODE_PATH SHA_MODE VERCEL_STUB_VERSION
  : > "$GITHUB_OUTPUT"
  : > "$VERCEL_LOG"
  : > "$PATH_VERCEL_MARKER"
  : > "$PATH_NODE_MARKER"
  : > "$NODE_LOG"
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

  # The caller result contract must be documented next to the interface, not
  # only in issue discussion.
  assert_file_contains "$WORKFLOW_FILE" "superseded means restart"
  assert_file_contains "$WORKFLOW_FILE" "post-promotion \`failed\` requires manual recovery"
  assert_file_contains "$WORKFLOW_FILE" "results from a failed reusable job"

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
  if ! grep -Fq "unset NODE_OPTIONS NODE_PATH" "$STEPS_DIR/control-plane.sh"; then
    fail "the token-bearing control step must unset NODE_OPTIONS and NODE_PATH"
  fi
  if ! grep -Fq '"$NODE_BIN" -- "$VERCEL_BIN"' "$STEPS_DIR/control-plane.sh"; then
    fail "the token-bearing control step must start the CLI through the preflighted node"
  fi
  if ! grep -Fq '"$NODE_BIN" -- "$VERCEL_BIN" build' "$STEPS_DIR/build.sh"; then
    fail "the build step must start the CLI through the preflighted node"
  fi
  if ! grep -Fq "VERCEL_AUTOMATION_BYPASS_SECRET not configured" "$TMP_ROOT/smoke-block.yml"; then
    fail "the smoke step must fail closed with the documented missing-secret message"
  fi
  if grep -Fq "::warning::" "$TMP_ROOT/smoke-block.yml"; then
    fail "the smoke step must not downgrade the missing bypass secret to a warning"
  fi

  # Check the parsed scopes as well as the textual secret-reference counts.
  /usr/bin/python3 - "$WORKFLOW_FILE" <<'PYTHON'
import sys
import yaml
workflow = yaml.safe_load(open(sys.argv[1]))
job = workflow['jobs']['deploy-staging']
steps = job['steps']
for scope in (workflow, job):
    assert not any('VERCEL_TOKEN' in k or 'BYPASS_SECRET' in k for k in scope.get('env', {}))
token_steps = [s for s in steps if 'VERCEL_TOKEN' in s.get('env', {})]
bypass_steps = [s for s in steps if 'VERCEL_AUTOMATION_BYPASS_SECRET' in s.get('env', {})]
assert len(token_steps) == 1 and token_steps[0]['id'] == 'control'
assert len(bypass_steps) == 1 and bypass_steps[0]['id'] == 'smoke'
build = next(s for s in steps if s.get('id') == 'build')
control = token_steps[0]
context = next(s for s in steps if s.get('id') == 'deploy_context')
assert context['working-directory'] == build['working-directory']
assert control['working-directory'] == '${{ runner.temp }}'
assert context['env']['BUILD_SOURCE_DIR'] == '${{ steps.build.outputs.source_dir }}'
assert context['env']['BUILD_SOURCE_SHA'] == '${{ steps.build.outputs.source_sha }}'
assert control['env']['DEPLOY_DIR'] == '${{ steps.deploy_context.outputs.deploy_dir }}'
assert control['env']['DEPLOY_SOURCE_SHA'] == '${{ steps.deploy_context.outputs.source_sha }}'
assert build['env']['PROJECT_SETTINGS_JSON'] == '${{ inputs.project_settings }}'
assert build['env']['EXPECTED_SHA'] == '${{ inputs.expected_sha }}'
PYTHON

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

  common_preflight_env
  run_script "$script" "$out" BAD_OWNER_PATH="$STUB_DIR/node-trusted" && fail "non-root node should fail"
  assert_file_contains "$out" "Untrusted node owner"

  common_preflight_env
  run_script "$script" "$out" BAD_MODE_PATH="$STUB_DIR/node-trusted" && fail "writable node should fail"
  assert_file_contains "$out" "Unsafe node permissions"

  # A PATH-poisoned node or an injected NODE_OPTIONS must not be picked up by
  # the CLI version probe.
  common_preflight_env
  export NODE_OPTIONS=--require=/tmp/poison-123456.js
  run_script "$script" "$out" || fail "preflight should sanitize NODE_OPTIONS"
  unset NODE_OPTIONS
  if grep -Fq 'node-options=--require=/tmp/poison-123456.js' "$NODE_LOG"; then
    fail "preflight passed NODE_OPTIONS through to node"
  fi

  if [ -s "$PATH_NODE_MARKER" ]; then
    fail "PATH-resolved node was invoked during preflight"
  fi
  if ! grep -Fxq 'node-options=' "$NODE_LOG"; then
    fail "preflight must invoke the CLI through a sanitized Node interpreter"
  fi

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
  export CONTROL_WORKDIR="$TMP_ROOT/exact-checkout"
  export BUILD_SOURCE_DIR="$CONTROL_WORKDIR"
  export BUILD_SOURCE_SHA="$EXPECTED_SHA"
  export GIT_BIN="$STUB_DIR/git"
  export JQ_BIN=/usr/bin/jq
  export PYTHON_BIN=/usr/bin/python3
  export PROJECT_SETTINGS_JSON='{"framework":null,"installCommand":"","outputDirectory":"public"}'
  export VERCEL_BIN="$STUB_DIR/vercel-trusted"
  export NODE_BIN="$STUB_DIR/node-trusted"
  export VERCEL_ORG_ID=org
  export VERCEL_PROJECT_ID=project
  export VERCEL_TOKEN=synthetic-secret-token
  export VERCEL_STATE_DIR="$TMP_ROOT/vercel-state"
  export VERCEL_LOG="$TMP_ROOT/vercel.log"
  export NODE_LOG="$TMP_ROOT/node.log"
  export PATH_NODE_MARKER="$TMP_ROOT/path-node-marker"
  export GITHUB_RUN_ID=99
  export GITHUB_RUN_ATTEMPT=1
  rm -rf "$VERCEL_STATE_DIR"
  mkdir -p "$NEUTRAL_DIR" "$VERCEL_STATE_DIR" "$CONTROL_WORKDIR/.vercel/output"
  printf '{"fixture":"fresh-%s"}\n' "$EXPECTED_SHA" > "$CONTROL_WORKDIR/.vercel/output/config.json"
  : > "$GITHUB_OUTPUT"
  : > "$VERCEL_LOG"
  : > "$NODE_LOG"
  : > "$PATH_NODE_MARKER"
}

prepare_context() {
  local out_file=$1
  local context_output="$TMP_ROOT/context-output"
  : > "$context_output"
  (
    cd "$CONTROL_WORKDIR"
    unset VERCEL_TOKEN
    GITHUB_OUTPUT="$context_output" run_script "$STEPS_DIR/deploy-context.sh" "$out_file"
  ) || return 1
  export DEPLOY_DIR DEPLOY_SOURCE_SHA
  DEPLOY_DIR=$(read_output "$context_output" deploy_dir)
  DEPLOY_SOURCE_SHA=$(read_output "$context_output" source_sha)
}

run_prepared_control_script() {
  local out_file=$1
  shift
  set +e
  (
    cd "$NEUTRAL_DIR"
    env "$@" bash --noprofile --norc -e -o pipefail "$STEPS_DIR/control-plane.sh"
  ) >"$out_file" 2>&1
  local status=$?
  set -e
  return "$status"
}

run_control_script() {
  local out_file=$1
  shift
  prepare_context "$out_file" || return 1
  run_prepared_control_script "$out_file" "$@"
}

test_control_never_runs_source_config() {
  local out="$TMP_ROOT/source-config.out"
  local ext
  export CONFIG_MARKER="$TMP_ROOT/config-marker"
  for ext in ts mts js mjs cjs; do
    set_control_env
    rm -f "$CONTROL_WORKDIR"/vercel.* "$CONFIG_MARKER"
    cat > "$CONTROL_WORKDIR/vercel.$ext" <<'CONFIG'
if (process.env.VERCEL_TOKEN) {
  require('fs').writeFileSync(process.env.CONFIG_MARKER, 'token-readable');
  throw new Error('source config ran with token');
}
CONFIG
    run_control_script "$out" || fail "control should succeed without evaluating source config"
    [ ! -f "$CONFIG_MARKER" ] || fail "vercel.$ext executed with the token"
    /usr/bin/python3 - "$DEPLOY_DIR" <<'PYTHON'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
assert {p.name for p in root.iterdir()} == {'.vercel'}
assert {p.name for p in (root / '.vercel').iterdir()} == {'output', 'project.json'}
assert json.loads((root / '.vercel/project.json').read_text()) == {'orgId': 'org', 'projectId': 'project'}
PYTHON
    [ "$(read_output "$GITHUB_OUTPUT" result)" = success ] || fail "source config must be excluded from deploy context"
  done
  pass "token-bearing deploy never evaluates repository-authored vercel config"
}

test_context_refuses_extra_files_and_cleans_up() {
  local out="$TMP_ROOT/context-check.out"
  set_control_env
  prepare_context "$out" || fail "context preparation should succeed"
  run_prepared_control_script "$out" DEPLOY_SOURCE_SHA=2222222222222222222222222222222222222222 || fail "wrong context SHA must be managed"
  [ "$(read_output "$GITHUB_OUTPUT" result)" = failed ] || fail "wrong context SHA must fail closed"
  assert_file_not_contains "$VERCEL_LOG" "deploy"
  : > "$GITHUB_OUTPUT"
  printf 'throw new Error("must not execute")' > "$DEPLOY_DIR/vercel.cjs"
  run_prepared_control_script "$out" || fail "invalid context must be a managed failure"
  [ "$(read_output "$GITHUB_OUTPUT" result)" = failed ] || fail "extra source config must fail closed"
  assert_file_contains "$out" "Staging deploy context refused"
  assert_file_not_contains "$VERCEL_LOG" "deploy"
  run_script "$STEPS_DIR/cleanup-context.sh" "$out" || fail "cleanup must succeed"
  [ ! -e "$DEPLOY_DIR" ] || fail "prepared context must be removed"
  pass "context validation rejects extra files and cleanup removes only the prepared directory"
}

test_build_output_is_bound_to_deploy() {
  local out="$TMP_ROOT/build-deploy.out"
  local build_output="$TMP_ROOT/build-deploy-output"

  set_control_env
  mkdir -p "$NEUTRAL_DIR/.vercel/output"
  printf '{"fixture":"stale-neutral"}\n' > "$NEUTRAL_DIR/.vercel/output/config.json"
  rm -rf "$CONTROL_WORKDIR/.vercel"
  : > "$build_output"
  (
    cd "$CONTROL_WORKDIR"
    unset VERCEL_TOKEN
    run_script "$STEPS_DIR/verify-source.sh" "$out" || fail "exact source must verify before build"
    GITHUB_OUTPUT="$build_output" run_script "$STEPS_DIR/build.sh" "$out" || fail "exact-SHA build must succeed"
  )
  export BUILD_SOURCE_DIR BUILD_SOURCE_SHA
  BUILD_SOURCE_DIR=$(read_output "$build_output" source_dir)
  BUILD_SOURCE_SHA=$(read_output "$build_output" source_sha)
  run_control_script "$out" || fail "fresh build deploy should succeed"
  [ "$(read_output "$GITHUB_OUTPUT" result)" = success ] || fail "fresh build was not deployed"
  assert_file_contains "$VERCEL_LOG" "deployed-fixture fresh-$EXPECTED_SHA"
  assert_file_contains "$VERCEL_LOG" "deploy-cwd $DEPLOY_DIR"
  [ "$DEPLOY_DIR" != "$CONTROL_WORKDIR" ] || fail "deploy must not use checkout"
  assert_file_not_contains "$VERCEL_LOG" "deployed-fixture stale-neutral"
  assert_file_contains "$NODE_LOG" "node-cwd=$NEUTRAL_DIR"

  # Keep the stale neutral output present for every negative case. None may
  # fall back to it, deploy anything, or change an alias.
  local scenario
  for scenario in missing_output wrong_directory wrong_sha missing_receipt; do
    set_control_env
    case "$scenario" in
      missing_output) rm -rf "$CONTROL_WORKDIR/.vercel/output" ;;
      wrong_directory) export BUILD_SOURCE_DIR="$NEUTRAL_DIR" ;;
      wrong_sha) export BUILD_SOURCE_SHA=2222222222222222222222222222222222222222 ;;
      missing_receipt) export BUILD_SOURCE_DIR="" BUILD_SOURCE_SHA="" ;;
    esac
    prepare_context "$out" && fail "$scenario must fail preparation closed"
    assert_file_contains "$out" "Staging build binding failed"
    assert_file_not_contains "$VERCEL_LOG" "deployed-fixture"
    assert_file_not_contains "$VERCEL_LOG" "alias set"
  done
  set_control_env
  run_control_script "$out" NEUTRAL_DIR="$TMP_ROOT/absent-neutral" || fail "startup directory failure must be managed"
  [ "$(read_output "$GITHUB_OUTPUT" result)" = failed ] || fail "missing neutral directory must fail closed"
  assert_file_contains "$out" "Staging deploy context refused"
  assert_file_not_contains "$VERCEL_LOG" "deployed-fixture"
  pass "deploy consumes the exact-SHA build and rejects missing or mismatched output bindings"
}

test_control_plane_success_and_superseded() {
  local out="$TMP_ROOT/control.out"

  set_control_env
  touch "$NEUTRAL_DIR/re.py" "$NEUTRAL_DIR/sitecustomize.py" "$NEUTRAL_DIR/usercustomize.py"
  run_control_script "$out" PYTHONPATH="$NEUTRAL_DIR" PYTHONSTARTUP="$NEUTRAL_DIR/re.py" HOME="$NEUTRAL_DIR" || fail "control success should pass"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "success" ]; then
    fail "successful control step did not emit success"
  fi
  assert_file_contains "$VERCEL_LOG" "alias set https://candidate.vercel.app pythonlife.org"
  assert_file_contains "$VERCEL_LOG" "alias set https://candidate.vercel.app staging.lm.fm"
  assert_file_not_contains "$out" "synthetic-secret-token"

  set_control_env
  run_control_script "$out" ORIGIN_DEV_SHA=2222222222222222222222222222222222222222 || fail "superseded should be a managed result"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "superseded" ]; then
    fail "superseded guard did not emit superseded"
  fi
  assert_file_not_contains "$VERCEL_LOG" "alias set https://candidate.vercel.app"

  pass "control plane promotes deterministically and rejects stale SHA before aliases"
}

test_project_settings_rejects_invalid_inputs() {
  local out="$TMP_ROOT/settings.out"
  local workdir="$TMP_ROOT/settings-fresh"
  local settings
  set_control_env
  for settings in '' '{}' 'not-json' '{"env":{"SECRET":"synthetic"}}' '{"env":"synthetic"}' '{"framework":true}'; do
    rm -rf "$workdir"
    mkdir -p "$workdir"
    (
      cd "$workdir"
      unset VERCEL_TOKEN
      run_script "$STEPS_DIR/build.sh" "$out" PROJECT_SETTINGS_JSON="$settings"
    ) && fail "invalid settings must fail before build"
    assert_file_contains "$out" "Invalid Vercel project settings"
    assert_file_not_contains "$VERCEL_LOG" "build"
    [ ! -f "$workdir/.vercel/project.json" ] || fail "invalid settings must not write a project link"
  done
  pass "only explicit reviewed non-secret settings keys and types reach the fresh build"
}

test_build_step_starts_cli_through_preflighted_node() {
  local out="$TMP_ROOT/build.out"
  local workdir="$TMP_ROOT/build-workdir"
  export PYTHON_BIN=/usr/bin/python3
  export NEUTRAL_DIR="$TMP_ROOT/neutral"
  export PROJECT_SETTINGS_JSON='{"framework":null,"installCommand":"","outputDirectory":"public"}'

  export PATH="$STUB_DIR:$PATH"
  export GITHUB_OUTPUT="$TMP_ROOT/build-output"
  export NODE_BIN="$STUB_DIR/node-trusted"
  export VERCEL_BIN="$STUB_DIR/vercel-trusted"
  export VERCEL_ORG_ID=org
  export VERCEL_PROJECT_ID=project
  export NODE_LOG="$TMP_ROOT/node.log"
  export VERCEL_LOG="$TMP_ROOT/vercel.log"
  export PATH_NODE_MARKER="$TMP_ROOT/path-node-marker"
  export PATH_VERCEL_MARKER="$TMP_ROOT/path-vercel-marker"
  export RUNNER_TEMP="$TMP_ROOT/build-runner-temp"
  unset VERCEL_STUB_VERSION VERCEL_TOKEN
  rm -rf "$workdir"
  mkdir -p "$workdir" "$RUNNER_TEMP" "$NEUTRAL_DIR"
  [ ! -e "$workdir/.vercel" ] || fail "build fixture must start genuinely fresh"
  : > "$NODE_LOG"
  : > "$VERCEL_LOG"
  : > "$PATH_NODE_MARKER"
  : > "$PATH_VERCEL_MARKER"

  # Inherited NODE_OPTIONS is a legitimate input to this step (the workflow
  # sets a heap limit), so only PATH poisoning is asserted here: the CLI must
  # still be started through the preflighted absolute interpreter.
  set +e
  (
    cd "$workdir"
    env bash --noprofile --norc -e -o pipefail "$STEPS_DIR/build.sh"
  ) >"$out" 2>&1
  local status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    cat "$out" >&2
    fail "build step should succeed with synthetic CLI"
  fi
  if [ ! -f "$workdir/.vercel/output/config.json" ]; then
    fail "build step did not run the CLI build"
  fi
  assert_file_contains "$VERCEL_LOG" "build"
  if [ -s "$PATH_NODE_MARKER" ]; then
    fail "build step invoked a PATH-resolved node"
  fi
  if [ -s "$PATH_VERCEL_MARKER" ]; then
    fail "build step invoked a PATH-resolved vercel"
  fi
  if ! grep -Fq 'node-path=' "$NODE_LOG"; then
    fail "build step must start the CLI through the preflighted Node interpreter"
  fi

  pass "build step starts the CLI through the preflighted absolute Node interpreter"
}

test_control_plane_failure_modes() {
  local out="$TMP_ROOT/control-fail.out"

  set_control_env
  run_control_script "$out" VERCEL_MODE=malformed_inspect || fail "malformed inspect is managed"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "failed" ]; then
    fail "malformed inspect should emit failed"
  fi
  assert_file_not_contains "$VERCEL_LOG" "alias set https://candidate.vercel.app"

  set_control_env
  run_control_script "$out" FAIL_SECOND_ALIAS=1 || fail "second alias failure should be managed"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "rolled_back" ]; then
    fail "second alias failure should emit rolled_back"
  fi
  assert_file_contains "$VERCEL_LOG" "alias set https://old-pythonlife.org.vercel.app pythonlife.org"
  assert_file_contains "$VERCEL_LOG" "alias set https://old-staging.lm.fm.vercel.app staging.lm.fm"
  assert_file_not_contains "$out" "synthetic-secret-token"

  set_control_env
  run_control_script "$out" FAIL_SECOND_ALIAS=1 ROLLBACK_FAIL=1 || fail "rollback failure should be managed"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "rollback_failed" ]; then
    fail "rollback failure should emit rollback_failed"
  fi
  assert_file_contains "$out" "Rollback alias set failed"
  assert_file_not_contains "$out" "synthetic-secret-token"

  # The CLI is a Node entrypoint. A PATH-resolved node or inherited NODE_OPTIONS
  # must never start the token-bearing control-plane process.
  set_control_env
  run_control_script "$out" NODE_OPTIONS=--require=/tmp/poison-123456.js NODE_PATH=/tmp/poison-node-path
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "success" ]; then
    fail "control step should sanitize Node startup environment and still succeed"
  fi
  if [ -s "$PATH_NODE_MARKER" ]; then
    fail "token-bearing control step invoked a PATH-resolved node"
  fi
  assert_file_not_contains "$NODE_LOG" 'node-options=--require=/tmp/poison-123456.js'
  assert_file_not_contains "$NODE_LOG" 'node-path=/tmp/poison-node-path'
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
  if [[ "$candidate_line" != *"follows_redirects=no"* ]]; then
    fail "candidate smoke must not follow redirects while carrying the bypass header"
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
    if [[ "$alias_line" != *"follows_redirects=yes"* ]]; then
      fail "alias $alias smoke must follow redirects so the landing URL is inspected"
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

test_smoke_candidate_redirect_fails_without_following() {
  local out="$TMP_ROOT/smoke-candidate-redirect.out"

  set_smoke_env
  run_script "$STEPS_DIR/smoke.sh" "$out" CURL_SCENARIO=candidate_redirect_3xx \
    VERCEL_AUTOMATION_BYPASS_SECRET=synthetic-bypass-value \
    EXPECTED_BYPASS_SECRET=synthetic-bypass-value || fail "candidate redirect is a managed smoke failure"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "failed" ]; then
    fail "a candidate redirect must fail the smoke instead of being followed with the bypass header"
  fi
  assert_file_contains "$out" "Staging smoke unexpected redirect"
  assert_file_contains "$out" "https://elsewhere.example.com/landing"
  assert_file_contains "$out" "manual-recovery incident"

  if ! grep -F 'url=https://candidate.vercel.app ' "$CURL_LOG" | grep -Fq 'follows_redirects=no'; then
    echo "curl log:" >&2
    cat "$CURL_LOG" >&2 || true
    fail "candidate smoke must issue the redirect check without following redirects"
  fi
  assert_file_not_contains "$CURL_LOG" "synthetic-bypass-value"
  assert_file_not_contains "$out" "synthetic-bypass-value"

  pass "candidate redirects fail closed instead of forwarding the bypass header"
}

test_smoke_ignores_default_curl_config() {
  local out="$TMP_ROOT/smoke-curlrc.out"
  local curl_home="$TMP_ROOT/curl-home"
  local candidate_line

  mkdir -p "$curl_home"
  printf 'location = true\nverbose = true\n' > "$curl_home/.curlrc"

  set_smoke_env
  run_script "$STEPS_DIR/smoke.sh" "$out" HOME="$curl_home" \
    CURL_SCENARIO=candidate_redirect_3xx \
    VERCEL_AUTOMATION_BYPASS_SECRET=synthetic-bypass-value \
    EXPECTED_BYPASS_SECRET=synthetic-bypass-value || fail "inherited .curlrc redirect is a managed smoke failure"

  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "failed" ]; then
    fail "an inherited .curlrc with location must not turn a candidate redirect into success"
  fi
  candidate_line=$(grep -F 'url=https://candidate.vercel.app ' "$CURL_LOG" || true)
  if [ -z "$candidate_line" ]; then
    fail "candidate smoke did not issue a request"
  fi
  if [[ "$candidate_line" != *"defaults_disabled=yes"* ]]; then
    fail "curl default configuration must be disabled for the candidate smoke"
  fi
  if [[ "$candidate_line" != *"follows_redirects=no"* ]]; then
    fail "candidate smoke must not follow redirects even with an inherited .curlrc"
  fi
  if [ "$(grep -Fc 'first_arg=--disable' "$CURL_LOG")" -ne 3 ]; then
    fail "--disable must be curl's first argument on candidate and alias smokes"
  fi
  assert_file_contains "$out" "Staging smoke unexpected redirect"
  assert_file_not_contains "$CURL_LOG" "synthetic-bypass-value"
  assert_file_not_contains "$out" "synthetic-bypass-value"

  pass "curl default configuration cannot re-enable redirects or leak the bypass header"
}

test_smoke_transport_failures_are_failures() {
  local out="$TMP_ROOT/smoke-transport.out"

  set_smoke_env
  run_script "$STEPS_DIR/smoke.sh" "$out" CURL_SCENARIO=candidate_transport_fail \
    VERCEL_AUTOMATION_BYPASS_SECRET=synthetic-bypass-value \
    EXPECTED_BYPASS_SECRET=synthetic-bypass-value || fail "candidate transport failure is a managed smoke failure"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "failed" ]; then
    fail "a candidate 200 followed by curl exit 28 must fail the smoke"
  fi
  assert_file_contains "$out" "Staging smoke request failed"
  assert_file_contains "$out" "manual-recovery incident"
  assert_file_not_contains "$out" "synthetic-bypass-value"

  set_smoke_env
  run_script "$STEPS_DIR/smoke.sh" "$out" CURL_SCENARIO=alias_transport_fail \
    VERCEL_AUTOMATION_BYPASS_SECRET=synthetic-bypass-value \
    EXPECTED_BYPASS_SECRET=synthetic-bypass-value || fail "alias transport failure is a managed smoke failure"
  if [ "$(read_output "$GITHUB_OUTPUT" result)" != "failed" ]; then
    fail "an alias 200 followed by curl exit 28 must fail the smoke"
  fi

  pass "curl transport errors cannot be reported as successful smokes"
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
  curl_count=$(grep -c '^url=' "$CURL_LOG")
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
  local scenario login_url
  for login_url in \
    'https://vercel.com/login?sso=1' \
    'https://vercel.com:443/login?sso=1' \
    'https://vercel.com./login?sso=1' \
    'https://VeRcEl.CoM.:443/login?sso=1' \
    'https://LOGIN.VERCEL.COM.:443/team/sso?next=app' \
    'https://VeRcEl.CoM:443/SSO?next=app' \
    'https://LOGIN.VERCEL.COM:443/team/sso?next=app'; do
    for scenario in candidate_login candidate_login_3xx alias_login; do
      set_smoke_env
      run_script "$STEPS_DIR/smoke.sh" "$out" CURL_SCENARIO="$scenario" LOGIN_URL="$login_url" \
        VERCEL_AUTOMATION_BYPASS_SECRET=synthetic-bypass-value \
        EXPECTED_BYPASS_SECRET=synthetic-bypass-value || fail "login rejection must be a managed failure"
      [ "$(read_output "$GITHUB_OUTPUT" result)" = failed ] || fail "$scenario at $login_url must fail"
      if [ "$scenario" = alias_login ]; then
        assert_file_contains "$out" "::error title=Staging smoke hit Vercel login::alias pythonlife.org"
      else
        assert_file_contains "$out" "::error title=Staging smoke hit Vercel login::candidate"
      fi
      assert_file_contains "$out" "manual-recovery incident"
      assert_file_not_contains "$out" "Staging smoke request failed"
      assert_file_not_contains "$out" "synthetic-bypass-value"
      assert_file_contains "$CURL_LOG" 'url=https://candidate.vercel.app bypass_header=yes bypass_value=correct'
      assert_file_contains "$CURL_LOG" 'url=https://pythonlife.org bypass_header=no'
      assert_file_contains "$CURL_LOG" 'url=https://staging.lm.fm bypass_header=no'
      assert_file_not_contains "$CURL_ARGV_LOG" "synthetic-bypass-value"
    done
  done

  set_smoke_env
  run_script "$STEPS_DIR/smoke.sh" "$out" CURL_SCENARIO=alias_login || fail "alias login must fail without a bypass"
  [ "$(read_output "$GITHUB_OUTPUT" result)" = failed ] || fail "missing bypass plus alias login must fail"
  assert_file_contains "$out" "::error title=Staging smoke hit Vercel login::alias pythonlife.org"
  assert_file_contains "$out" "VERCEL_AUTOMATION_BYPASS_SECRET not configured"
  assert_file_contains "$CURL_LOG" 'url=https://pythonlife.org bypass_header=no'
  pass "Vercel login/SSO rejection normalizes host case, default HTTPS port, and DNS root dot"
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
test_control_never_runs_source_config
test_context_refuses_extra_files_and_cleans_up
test_build_output_is_bound_to_deploy
test_control_plane_success_and_superseded
test_control_plane_failure_modes
test_project_settings_rejects_invalid_inputs
test_build_step_starts_cli_through_preflighted_node
test_post_promotion_smoke_incident
test_smoke_bypass_header_candidate_only
test_smoke_candidate_redirect_fails_without_following
test_smoke_ignores_default_curl_config
test_smoke_transport_failures_are_failures
test_smoke_without_bypass_fails_closed
test_smoke_login_redirect_is_failure
test_smoke_rejects_unsafe_bypass_value
test_finalize_result_gate
test_shell_validation

echo "All $pass_count vercel staging workflow tests passed."
