#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/vercel-preview-build-reusable.yml"
DEPLOY_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/vercel-preview-deploy-reusable.yml"
TMP_ROOT=${TMPDIR:-/tmp}/vercel-preview-spool-test.$$
STEPS_DIR="$TMP_ROOT/steps"
STUB_DIR="$TMP_ROOT/bin"
REAL_PYTHON=$(command -v python3 || true)

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
    sed -n '1,200p' "$file" >&2 || true
    fail "missing expected text"
  fi
}

assert_file_not_contains() {
  local file=$1
  local pattern=$2
  if grep -Fq "$pattern" "$file"; then
    echo "Did not expect to find '$pattern' in $file" >&2
    sed -n '1,200p' "$file" >&2 || true
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
  ' "$DEPLOY_WORKFLOW_FILE" > "$output_file"

  if [ ! -s "$output_file" ]; then
    fail "could not extract workflow step: $step_name"
  fi
}

extract_steps() {
  mkdir -p "$STEPS_DIR"
  extract_step "Notify Vercel preview broker" "$STEPS_DIR/notify-vercel-preview-broker.sh"
}

install_stubs() {
  mkdir -p "$STUB_DIR"

  cat > "$STUB_DIR/npm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "npm should not be invoked by the notify shim" >&2
exit 2
STUB
  chmod +x "$STUB_DIR/npm"

  cat > "$STUB_DIR/vercel" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "vercel should not be invoked by the notify shim" >&2
exit 2
STUB
  chmod +x "$STUB_DIR/vercel"

  cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "gh should not be invoked by the notify shim" >&2
exit 2
STUB
  chmod +x "$STUB_DIR/gh"
}

set_common_env() {
  local runner_temp=$1
  local socket_path=$2

  export PATH="$STUB_DIR:$PATH"
  export RUNNER_TEMP="$runner_temp"
  export GITHUB_RUN_ID=987654321
  export GITHUB_RUN_ATTEMPT=1
  export BROKER_SOCKET_PATH="$socket_path"
  export POINTER_REPOSITORY="WebLime-agency/example"
  export POINTER_RUN_ID=12345

  mkdir -p "$runner_temp"
}

run_notify() {
  local runner_temp=$1
  local socket_path=$2
  local out_file=$3

  set_common_env "$runner_temp" "$socket_path"
  set +e
  bash --noprofile --norc -e -o pipefail "$STEPS_DIR/notify-vercel-preview-broker.sh" >"$out_file" 2>&1
  local status=$?
  return "$status"
}

start_fake_server() {
  local socket_path=$1
  local mode_file=$2
  local received_file=$3
  local count_file=$4
  local ready_file=$5

  rm -f "$socket_path" "$ready_file" "$received_file" "$count_file"
  "$REAL_PYTHON" - "$socket_path" "$mode_file" "$received_file" "$count_file" "$ready_file" <<'PY' >"$ready_file.log" 2>&1 &
import json
import os
import socket
import sys
import time

socket_path, mode_file, received_file, count_file, ready_file = sys.argv[1:6]

with open(mode_file, "r", encoding="utf-8") as f:
    actions = json.load(f)

try:
    os.unlink(socket_path)
except FileNotFoundError:
    pass

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(socket_path)
server.listen(16)
with open(ready_file, "w", encoding="utf-8") as f:
    f.write("ready\n")

request_count = 0
try:
    for action in actions:
        conn, _ = server.accept()
        request_count += 1
        data = b""
        conn.settimeout(2.0)
        try:
            while not data.endswith(b"\n") and len(data) <= 4096:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
        except socket.timeout:
            pass

        with open(received_file, "ab") as f:
            f.write(b"---REQUEST---\n")
            f.write(data)
            if not data.endswith(b"\n"):
                f.write(b"\n")

        kind = action.get("kind")
        if kind == "ack":
            conn.sendall(action["payload"].encode("utf-8"))
            conn.close()
        elif kind == "slow_ack":
            payload = action["payload"].encode("utf-8")
            chunk_size = max(1, (len(payload) + 2) // 3)
            for offset in range(0, len(payload), chunk_size):
                try:
                    conn.sendall(payload[offset:offset + chunk_size])
                except (BrokenPipeError, ConnectionResetError):
                    break
                if offset + chunk_size < len(payload):
                    time.sleep(1.1)
            conn.close()
        elif kind == "close":
            conn.close()
        elif kind == "partial":
            conn.sendall(action["payload"].encode("utf-8"))
            conn.close()
        elif kind == "sleep":
            time.sleep(float(action.get("seconds", 3.0)))
            conn.close()
        else:
            conn.close()
finally:
    with open(count_file, "w", encoding="utf-8") as f:
        f.write(str(request_count))
    server.close()
    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass
PY
  local server_pid=$!

  for _ in $(seq 1 100); do
    if [ -e "$ready_file" ]; then
      echo "$server_pid"
      return 0
    fi
    sleep 0.02
  done

  kill "$server_pid" 2>/dev/null || true
  fail "fake server did not become ready"
}

write_actions() {
  local file=$1
  shift
  printf '%s\n' "$1" > "$file"
}

accepted_ack() {
  printf '{"status":"accepted","version":"1","request_id":"WebLime-agency/example:12345","reason":null,"retryable":false}\n'
}

duplicate_ack() {
  printf '{"status":"duplicate","version":"1","request_id":"WebLime-agency/example:12345","reason":null,"retryable":false}\n'
}

rejected_ack() {
  local reason=$1
  local retryable=$2
  printf '{"status":"rejected","version":"1","request_id":"WebLime-agency/example:12345","reason":"%s","retryable":%s}\n' "$reason" "$retryable"
}

ack_actions() {
  "$REAL_PYTHON" - "$@" <<'PY'
import json
import sys

print(json.dumps([{"kind": "ack", "payload": payload} for payload in sys.argv[1:]]))
PY
}

complete_ack_actions() {
  "$REAL_PYTHON" - "$@" <<'PY'
import json
import sys

print(json.dumps([{"kind": "ack", "payload": payload + "\n"} for payload in sys.argv[1:]]))
PY
}

mixed_actions() {
  "$REAL_PYTHON" - "$@" <<'PY'
import json
import sys

actions = []
for raw in sys.argv[1:]:
    kind, _, payload = raw.partition(":")
    if kind in {"ack", "partial", "slow_ack"}:
        actions.append({"kind": kind, "payload": payload})
    elif kind == "close":
        actions.append({"kind": "close"})
    elif kind == "sleep":
        actions.append({"kind": "sleep", "seconds": float(payload)})
    else:
        raise SystemExit(f"unknown action kind: {kind}")
print(json.dumps(actions))
PY
}

request_count() {
  local count_file=$1
  if [ -f "$count_file" ]; then
    cat "$count_file"
  else
    echo 0
  fi
}

assert_request_frames_identical() {
  local received_file=$1
  "$REAL_PYTHON" - "$received_file" <<'PY'
import sys
from pathlib import Path

content = Path(sys.argv[1]).read_bytes()
frames = [part for part in content.split(b"---REQUEST---\n") if part]
if len(frames) < 2:
    sys.exit("expected at least two request frames")
first = frames[0]
if any(frame != first for frame in frames[1:]):
    sys.exit("retried request frames differ")
PY
}

assert_single_strict_request() {
  local received_file=$1
  "$REAL_PYTHON" - "$received_file" <<'PY'
import json
import sys
from pathlib import Path

content = Path(sys.argv[1]).read_bytes()
frames = [part for part in content.split(b"---REQUEST---\n") if part]
if len(frames) != 1:
    sys.exit(f"expected exactly one request, got {len(frames)}")
frame = frames[0]
if not frame.endswith(b"\n"):
    sys.exit("request is not newline terminated")
if len(frame) > 4096:
    sys.exit("request exceeds 4 KiB")
text = frame.decode("utf-8")

def reject_duplicate_pairs(pairs):
    seen = set()
    obj = {}
    for key, value in pairs:
        if key in seen:
            raise ValueError(f"duplicate key: {key}")
        seen.add(key)
        obj[key] = value
    return obj

obj = json.loads(text, object_pairs_hook=reject_duplicate_pairs)
if set(obj) != {"version", "repository", "run_id"}:
    sys.exit(f"unexpected request keys: {sorted(obj)}")
if obj["version"] != "1":
    sys.exit("wrong version")
if obj["repository"] != "WebLime-agency/example":
    sys.exit("wrong repository")
if not isinstance(obj["run_id"], int) or obj["run_id"] <= 0:
    sys.exit("run_id is not a positive integer")
for forbidden in ("pull_request", "pr_number", "head_sha", "output", "token", "socket", "path"):
    if forbidden in text:
        sys.exit(f"forbidden pointer data present: {forbidden}")
PY
}

run_server_case() {
  local name=$1
  local actions_json=$2
  local expected_status=$3
  local runner_temp="$TMP_ROOT/runner-$name"
  local socket_path="$TMP_ROOT/$name.sock"
  local mode_file="$TMP_ROOT/$name-actions.json"
  local received_file="$TMP_ROOT/$name-received.bin"
  local count_file="$TMP_ROOT/$name-count.txt"
  local ready_file="$TMP_ROOT/$name-ready"
  local out_file="$TMP_ROOT/$name.out"
  local server_pid
  local status

  write_actions "$mode_file" "$actions_json"
  server_pid=$(start_fake_server "$socket_path" "$mode_file" "$received_file" "$count_file" "$ready_file")

  set +e
  run_notify "$runner_temp" "$socket_path" "$out_file"
  status=$?
  set -e

  for _ in $(seq 1 100); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      break
    fi
    sleep 0.02
  done
  if kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
  fi

  if [ "$expected_status" = "success" ] && [ "$status" -ne 0 ]; then
    sed -n '1,200p' "$out_file" >&2 || true
    fail "$name should have succeeded"
  fi
  if [ "$expected_status" = "failure" ] && [ "$status" -eq 0 ]; then
    sed -n '1,200p' "$out_file" >&2 || true
    fail "$name should have failed"
  fi

  export CASE_RECEIVED_FILE="$received_file"
  export CASE_COUNT_FILE="$count_file"
  export CASE_OUT_FILE="$out_file"
}

test_stage1_handoff_stripped_static() {
  assert_file_not_contains "$BUILD_WORKFLOW_FILE" "upload-artifact"
  assert_file_not_contains "$BUILD_WORKFLOW_FILE" "pr-number.txt"
  assert_file_not_contains "$BUILD_WORKFLOW_FILE" "tar -"
  assert_file_not_contains "$BUILD_WORKFLOW_FILE" "secrets."
  assert_file_contains "$BUILD_WORKFLOW_FILE" "Checkout PR head"
  assert_file_contains "$BUILD_WORKFLOW_FILE" "Setup Node.js"
  assert_file_contains "$BUILD_WORKFLOW_FILE" "Install dependencies"
  assert_file_contains "$BUILD_WORKFLOW_FILE" "Inject repo/org Variables into build env"
  assert_file_contains "$BUILD_WORKFLOW_FILE" "Build Vercel output"
  assert_file_contains "$BUILD_WORKFLOW_FILE" "Verify Vercel output"
  pass "stage 1 keeps build check and removes artifact handoff"
}

test_python3_preflight_fail_closed() {
  local runner_temp="$TMP_ROOT/runner-preflight"
  local out_file="$TMP_ROOT/preflight.out"
  local empty_path="$TMP_ROOT/no-python"
  local status
  mkdir -p "$empty_path"

  set_common_env "$runner_temp" "$TMP_ROOT/preflight.sock"
  set +e
  PATH="$empty_path" "$BASH" --noprofile --norc -e -o pipefail "$STEPS_DIR/notify-vercel-preview-broker.sh" >"$out_file" 2>&1
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    fail "missing python3 should fail closed"
  fi
  assert_file_contains "$out_file" "::error title=Missing python3::"
  if [ -e "$TMP_ROOT/preflight.sock" ]; then
    fail "preflight should not create or connect a socket"
  fi
  pass "python3 preflight fails closed without fallback"
}

test_exact_request_and_accepted_success() {
  run_server_case "accepted" "$(complete_ack_actions "$(accepted_ack)")" success
  assert_single_strict_request "$CASE_RECEIVED_FILE"
  if [ "$(request_count "$CASE_COUNT_FILE")" != "1" ]; then
    fail "accepted should use exactly one connection"
  fi
  pass "accepted ack succeeds with exact three-key request"
}

test_duplicate_success_transport_only() {
  run_server_case "duplicate" "$(complete_ack_actions "$(duplicate_ack)")" success
  assert_file_contains "$CASE_OUT_FILE" "transport-delivered"
  assert_file_not_contains "$CASE_OUT_FILE" "no work"
  assert_file_not_contains "$CASE_OUT_FILE" "deployment created"
  pass "duplicate ack succeeds without deploy/no-work inference"
}

test_tagged_union_violations_fail_closed() {
  local ack

  ack=$'{"status":"accepted","version":"1","request_id":"WebLime-agency/example:12345","reason":"rate_limited","retryable":false}\n'
  run_server_case "accepted-reason" "$(ack_actions "$ack")" failure
  assert_file_contains "$CASE_OUT_FILE" "::error title=Malformed broker ack::"

  ack=$'{"status":"rejected","version":"1","request_id":"WebLime-agency/example:12345","reason":"surprise","retryable":false}\n'
  run_server_case "bad-rejected-reason" "$(ack_actions "$ack")" failure
  assert_file_contains "$CASE_OUT_FILE" "::error title=Malformed broker ack::"

  ack=$'{"status":"rejected","version":"1","request_id":"WebLime-agency/example:12345","reason":"malformed","retryable":true}\n'
  run_server_case "bad-retryable" "$(ack_actions "$ack")" failure
  assert_file_contains "$CASE_OUT_FILE" "::error title=Malformed broker ack::"

  ack=$'{"status":"accepted","version":"1","request_id":"WebLime-agency/example:12345","reason":null}\n'
  run_server_case "missing-field" "$(ack_actions "$ack")" failure
  assert_file_contains "$CASE_OUT_FILE" "::error title=Malformed broker ack::"

  ack=$'{"status":[],"version":"1","request_id":"WebLime-agency/example:12345","reason":null,"retryable":false}\n'
  run_server_case "non-string-status" "$(ack_actions "$ack")" failure
  assert_file_contains "$CASE_OUT_FILE" "::error title=Malformed broker ack::"

  ack=$'{"status":"rejected","version":"1","request_id":"WebLime-agency/example:12345","reason":{},"retryable":false}\n'
  run_server_case "non-string-reason" "$(ack_actions "$ack")" failure
  assert_file_contains "$CASE_OUT_FILE" "::error title=Malformed broker ack::"

  pass "tagged-union ack violations fail closed"
}

test_retryable_rejected_then_success() {
  local rate_limited backpressure accepted actions
  rate_limited=$(rejected_ack rate_limited true)
  backpressure=$(rejected_ack backpressure true)
  accepted=$(accepted_ack)
  actions=$(complete_ack_actions "$rate_limited" "$backpressure" "$accepted")
  run_server_case "retryable-rejected" "$actions" success
  if [ "$(request_count "$CASE_COUNT_FILE")" != "3" ]; then
    fail "retryable rejected acks should retry twice before success"
  fi
  assert_request_frames_identical "$CASE_RECEIVED_FILE"
  pass "retryable rejected acks retry byte-identical pointer"
}

test_terminal_rejected_reasons_fail_without_retry() {
  local reason ack actions
  for reason in unsupported_version malformed unauthorized_peer unknown_repository; do
    ack=$(rejected_ack "$reason" false)
    actions=$(complete_ack_actions "$ack")
    run_server_case "terminal-$reason" "$actions" failure
    assert_file_contains "$CASE_OUT_FILE" "::error title=Broker rejected pointer::"
    if [ "$(request_count "$CASE_COUNT_FILE")" != "1" ]; then
      fail "terminal rejection $reason should not retry"
    fi
  done
  pass "terminal rejected reasons fail closed without retry"
}

test_transient_channel_errors_retry_and_exhaust() {
  local accepted actions missing_out status
  accepted="$(accepted_ack)"$'\n'
  actions=$(mixed_actions "close:" "ack:$accepted")
  run_server_case "connection-loss" "$actions" success
  if [ "$(request_count "$CASE_COUNT_FILE")" != "2" ]; then
    fail "connection loss should retry once before success"
  fi
  assert_request_frames_identical "$CASE_RECEIVED_FILE"

  missing_out="$TMP_ROOT/missing-socket.out"
  set +e
  run_notify "$TMP_ROOT/runner-missing-socket" "$TMP_ROOT/absent.sock" "$missing_out"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    fail "absent socket should exhaust retry budget"
  fi
  assert_file_contains "$missing_out" "::error title=Broker notify retry budget exhausted::"
  pass "transient channel errors retry and budget exhaustion fails visibly"
}

test_incomplete_read_transient_then_success() {
  local accepted actions
  accepted="$(accepted_ack)"$'\n'
  actions=$(mixed_actions "close:" 'partial:{"status":"accepted"' "ack:$accepted")
  run_server_case "incomplete-read" "$actions" success
  if [ "$(request_count "$CASE_COUNT_FILE")" != "3" ]; then
    fail "incomplete reads should retry until complete ack"
  fi
  assert_request_frames_identical "$CASE_RECEIVED_FILE"
  pass "incomplete ack reads are transient acceptance-unknown"
}

test_read_deadline_is_total_not_per_chunk() {
  local accepted actions
  accepted="$(accepted_ack)"$'\n'
  actions=$(mixed_actions "slow_ack:$accepted" "ack:$accepted")
  run_server_case "slow-ack-deadline" "$actions" success
  if [ "$(request_count "$CASE_COUNT_FILE")" != "2" ]; then
    fail "slow-drip ack should exceed the total read deadline and retry"
  fi
  assert_request_frames_identical "$CASE_RECEIVED_FILE"
  assert_file_contains "$CASE_OUT_FILE" "Transient broker notify error on attempt 1"
  pass "two-second ack read deadline applies to the complete frame"
}

test_complete_malformed_duplicate_key_and_overcap_fail_terminal() {
  local ack actions

  for ack in \
    $'not-json\n' \
    $'[1,2,3]\n' \
    $'{"status":"rate_limited","version":"1","request_id":"WebLime-agency/example:12345","reason":null,"retryable":false}\n' \
    $'{"status":"accepted","version":"2","request_id":"WebLime-agency/example:12345","reason":null,"retryable":false}\n' \
    $'{"status":"accepted","status":"duplicate","version":"1","request_id":"WebLime-agency/example:12345","reason":null,"retryable":false}\n' \
    $'{"status":"accepted","version":"1","request_id":"WebLime-agency/example:12345","reason":null,"retryable":false} trailing\n'; do
    run_server_case "malformed-$RANDOM" "$(ack_actions "$ack")" failure
    assert_file_contains "$CASE_OUT_FILE" "::error title=Malformed broker ack::"
    if [ "$(request_count "$CASE_COUNT_FILE")" != "1" ]; then
      fail "complete malformed ack should not retry"
    fi
  done

  ack=$(python3 - <<'PY'
print("x" * 1025)
PY
)
  actions=$(ack_actions "$ack")
  run_server_case "overcap" "$actions" failure
  assert_file_contains "$CASE_OUT_FILE" "::error title=Broker ack frame too large::"
  if [ "$(request_count "$CASE_COUNT_FILE")" != "1" ]; then
    fail "over-cap ack should not retry"
  fi
  pass "complete malformed, duplicate-key, and over-cap acks fail terminally"
}

test_timeout_after_commit_duplicate_success() {
  local duplicate actions
  duplicate="$(duplicate_ack)"$'\n'
  actions=$(mixed_actions "sleep:3.0" "ack:$duplicate")
  run_server_case "timeout-duplicate" "$actions" success
  if [ "$(request_count "$CASE_COUNT_FILE")" != "2" ]; then
    fail "timeout-after-possible-commit should retry once before duplicate"
  fi
  assert_request_frames_identical "$CASE_RECEIVED_FILE"
  pass "timeout-after-commit is resolved by duplicate ack"
}

test_version_mismatch_ack_fail_closed() {
  local ack
  ack=$'{"status":"accepted","version":"2","request_id":"WebLime-agency/example:12345","reason":null,"retryable":false}\n'
  run_server_case "version-mismatch" "$(ack_actions "$ack")" failure
  assert_file_contains "$CASE_OUT_FILE" "::error title=Malformed broker ack::"
  pass "version-mismatch ack fails closed"
}

test_request_guards_fail_before_send() {
  local out_file status socket_path mode_file received_file count_file ready_file server_pid actions
  local oversized_repository expected_title

  actions=$(ack_actions 'unused\n')
  for case_name in bad-run-zero bad-run-text oversized-repository; do
    socket_path="$TMP_ROOT/$case_name.sock"
    mode_file="$TMP_ROOT/$case_name-actions.json"
    received_file="$TMP_ROOT/$case_name-received.bin"
    count_file="$TMP_ROOT/$case_name-count.txt"
    ready_file="$TMP_ROOT/$case_name-ready"
    out_file="$TMP_ROOT/$case_name.out"
    write_actions "$mode_file" "$actions"
    server_pid=$(start_fake_server "$socket_path" "$mode_file" "$received_file" "$count_file" "$ready_file")

    set_common_env "$TMP_ROOT/runner-$case_name" "$socket_path"
    case "$case_name" in
      bad-run-zero)
        export POINTER_RUN_ID=0
        expected_title="Invalid pointer run_id"
        ;;
      bad-run-text)
        export POINTER_RUN_ID=not-a-number
        expected_title="Invalid pointer run_id"
        ;;
      oversized-repository)
        oversized_repository=$(python3 - <<'PY'
print("x" * 5000)
PY
)
        export POINTER_REPOSITORY="$oversized_repository"
        expected_title="Request frame too large"
        ;;
    esac

    set +e
    timeout 1 bash --noprofile --norc -e -o pipefail "$STEPS_DIR/notify-vercel-preview-broker.sh" >"$out_file" 2>&1
    status=$?
    set -e
    kill "$server_pid" 2>/dev/null || true
    if [ "$status" -eq 0 ]; then
      fail "$case_name should fail before send"
    fi
    if [ -s "$received_file" ]; then
      fail "$case_name should not send a request"
    fi
    assert_file_contains "$out_file" "::error title=$expected_title::"
    assert_file_not_contains "$out_file" "Traceback"
  done

  out_file="$TMP_ROOT/missing-socket-guard.out"
  set_common_env "$TMP_ROOT/runner-missing-socket-guard" ""
  set +e
  bash --noprofile --norc -e -o pipefail "$STEPS_DIR/notify-vercel-preview-broker.sh" >"$out_file" 2>&1
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    fail "missing broker socket should fail before send"
  fi
  assert_file_contains "$out_file" "::error title=Missing broker socket::"
  assert_file_not_contains "$out_file" "Traceback"
  pass "request guards fail before send for invalid or oversize pointers"
}

test_cancellation_truth_static_doc() {
  assert_file_contains "$DEPLOY_WORKFLOW_FILE" "Only accepted/duplicate ack proves transport delivery"
  assert_file_contains "$DEPLOY_WORKFLOW_FILE" "cancelled workflow after accepted may still be acted on"
  assert_file_contains "$DEPLOY_WORKFLOW_FILE" "acceptance-unknown"
  assert_file_not_contains "$DEPLOY_WORKFLOW_FILE" "retract"
  pass "cancellation truth is documented without retraction logic"
}

test_token_output_isolation_static() {
  for file in "$BUILD_WORKFLOW_FILE" "$DEPLOY_WORKFLOW_FILE"; do
    assert_file_not_contains "$file" "VERCEL_TOKEN"
    assert_file_not_contains "$file" "secrets."
    assert_file_not_contains "$file" "upload-artifact"
    assert_file_not_contains "$file" "download-artifact"
  done
  assert_file_not_contains "$DEPLOY_WORKFLOW_FILE" "vercel deploy"
  assert_file_not_contains "$DEPLOY_WORKFLOW_FILE" "Install Vercel CLI"
  assert_file_not_contains "$DEPLOY_WORKFLOW_FILE" "pull-requests: write"
  assert_file_not_contains "$DEPLOY_WORKFLOW_FILE" "actions: read"
  assert_file_not_contains "$DEPLOY_WORKFLOW_FILE" "environment: vercel-preview"
  pass "preview workflows carry no token, artifact, deploy, or comment authority"
}

test_inline_client_and_no_helper_static() {
  assert_file_contains "$DEPLOY_WORKFLOW_FILE" "python3 <<'PY'"
  assert_file_contains "$DEPLOY_WORKFLOW_FILE" "object_pairs_hook=reject_duplicate_pairs"
  assert_file_not_contains "$DEPLOY_WORKFLOW_FILE" "socat"
  assert_file_not_contains "$DEPLOY_WORKFLOW_FILE" "nc "
  assert_file_not_contains "$DEPLOY_WORKFLOW_FILE" "jq"
  if grep -Eq '(^|[[:space:]])(\./)?(tests/|scripts/|\.github/scripts/)' "$DEPLOY_WORKFLOW_FILE"; then
    fail "deploy workflow references repo-local helper paths"
  fi
  pass "notify shim uses inline python client with no repo-local helper"
}

test_gate_expansion_static() {
  assert_file_contains "$DEPLOY_WORKFLOW_FILE" "expected_build_workflow_name"
  assert_file_contains "$DEPLOY_WORKFLOW_FILE" "default: Vercel Preview Build"
  assert_file_contains "$DEPLOY_WORKFLOW_FILE" "github.event.workflow_run.head_repository.full_name == github.repository"
  assert_file_contains "$DEPLOY_WORKFLOW_FILE" "github.event.workflow_run.repository.full_name == github.repository"
  assert_file_contains "$DEPLOY_WORKFLOW_FILE" "github.event.workflow_run.name == inputs.expected_build_workflow_name"
  assert_file_contains "$DEPLOY_WORKFLOW_FILE" "noise-reduction gate"
  pass "workflow_run gate keeps existing clauses and adds repository/name checks"
}

test_no_sticky_comment_here_static() {
  assert_file_not_contains "$DEPLOY_WORKFLOW_FILE" "marocchino/sticky-pull-request-comment"
  assert_file_not_contains "$DEPLOY_WORKFLOW_FILE" "header: vercel-preview"
  assert_file_contains "$DEPLOY_WORKFLOW_FILE" "header vercel-preview"
  assert_file_contains "$DEPLOY_WORKFLOW_FILE" "Preview deployment:"
  pass "sticky preview comment contract is broker-posted, not shim-posted"
}

test_static_forbidden_terms() {
  for file in "$BUILD_WORKFLOW_FILE" "$DEPLOY_WORKFLOW_FILE"; do
    assert_file_not_contains "$file" "curl"
    assert_file_not_contains "$file" "POST"
    assert_file_not_contains "$file" "http://"
    assert_file_not_contains "$file" "https://"
    assert_file_not_contains "$file" "5xx"
    assert_file_not_contains "$file" "bwrap"
    assert_file_not_contains "$file" "socat"
    assert_file_not_contains "$file" "jq"
    assert_file_not_contains "$file" "/var/run"
    assert_file_not_contains "$file" "/run/"
  done
  pass "static forbidden transport, secret, and topology terms are absent"
}

main() {
  if [ -z "$REAL_PYTHON" ]; then
    fail "python3 is required to run the synthetic fake socket tests"
  fi

  install_stubs
  extract_steps

  test_stage1_handoff_stripped_static
  test_python3_preflight_fail_closed
  test_exact_request_and_accepted_success
  test_duplicate_success_transport_only
  test_tagged_union_violations_fail_closed
  test_retryable_rejected_then_success
  test_terminal_rejected_reasons_fail_without_retry
  test_transient_channel_errors_retry_and_exhaust
  test_incomplete_read_transient_then_success
  test_read_deadline_is_total_not_per_chunk
  test_complete_malformed_duplicate_key_and_overcap_fail_terminal
  test_timeout_after_commit_duplicate_success
  test_version_mismatch_ack_fail_closed
  test_request_guards_fail_before_send
  test_cancellation_truth_static_doc
  test_token_output_isolation_static
  test_inline_client_and_no_helper_static
  test_gate_expansion_static
  test_no_sticky_comment_here_static
  test_static_forbidden_terms
}

main "$@"
