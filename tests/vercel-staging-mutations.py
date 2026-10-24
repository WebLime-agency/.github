#!/usr/bin/env python3
"""Reproduce hardening regressions with extracted-step synthetic fixtures only.

Run normally to prove each mutation is caught. --baseline REV proves each new
regression test fails on that revision's workflow (defaults to the reviewed
593a0440 head). Tests and mutations operate on temporary workflow copies;
no checkout edits, service calls, credentials, or workflow dispatches occur.
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / '.github/workflows/vercel-staging-reusable.yml'
HARNESS = ROOT / 'tests/vercel-staging-workflow.sh'


def replace(text, old, new, count=1):
    if text.count(old) != count:
        raise AssertionError(f'mutation anchor expected {count}: {old!r}')
    return text.replace(old, new)


def block(text, name, transform):
    start = text.index('      - name: ' + name + '\n')
    end = text.find('      - name: ', start + 10)
    if end == -1:
        end = len(text)
    return text[:start] + transform(text[start:end]) + text[end:]


CONTROL = 'Vercel control-plane deploy/promote'
SMOKE = 'Smoke staging candidate and aliases'
BUILD = 'Build Vercel staging output'
MUTATIONS = [
    ('P1-2 token argv', 'test_no_token_argv', lambda s: replace(s, 'run_vercel deploy --prebuilt)', 'run_vercel deploy --prebuilt --token="$control_token")')),
    ('P1-3 early bypass gate', 'test_early_bypass_gate', lambda s: replace(s, 'if [ "$BYPASS_CONFIGURED" != true ]; then', 'if false; then')),
    ('P2-1 initial ancestry', 'test_dev_membership', lambda s: block(s, 'Verify exact source', lambda b: replace(b, 'if ! "$GIT_BIN" merge-base --is-ancestor "$EXPECTED_SHA" "$ORIGIN_DEV_SHA"; then', 'if false; then'))),
    ('P2-1 refreshed ancestry', 'test_dev_membership', lambda s: replace(s, 'if ! "$GIT_BIN" --git-dir="$TMPDIR/dev-check.git" merge-base --is-ancestor "$EXPECTED_SHA" "$ORIGIN_DEV_SHA"; then', 'if false; then')),
    ('P2-1 fresh dev tip', 'test_dev_membership', lambda s: replace(s, 'ORIGIN_DEV_SHA="$("$GIT_BIN" --git-dir="$TMPDIR/dev-check.git" rev-parse refs/remotes/origin/dev)"', ': # regress to previously fetched ORIGIN_DEV_SHA')),
    ('P2-1 initial fetch', 'test_private_fetch_credentials', lambda s: block(s, 'Verify exact source', lambda b: replace(b, '          fetch_dev\n', '          : # initial fetch removed\n'))),
    ('P2-1 promotion refetch', 'test_private_fetch_credentials', lambda s: block(s, CONTROL, lambda b: replace(b, '            fetch_dev\n', '            : # refresh removed\n'))),
    ('P2-1 private fetch credentials', 'test_private_fetch_credentials', lambda s: replace(s, 'READ_TOKEN="$read_token" GIT_TERMINAL_PROMPT=0', 'GIT_TERMINAL_PROMPT=0', 2)),
    ('P2-2 empty smoke output', 'test_smoke_outcome_required', lambda s: replace(s, '[ "${SMOKE_RESULT:-}" = success ]', '[ -z "${SMOKE_RESULT:-}" ]')),
    ('P2-2 smoke outcome', 'test_smoke_outcome_required', lambda s: replace(s, '[ "${SMOKE_OUTCOME:-}" = success ]', 'true')),
    ('P2-3 candidate host', 'test_candidate_host_boundary', lambda s: replace(s, 'if [[ ! "$DEPLOYMENT_URL" =~ ^https://[a-z0-9-]+\\.vercel\\.app/?$ ]]; then', 'if false; then')),
    ('P2-4 explicit anchor', 'test_explicit_rollback_anchor', lambda s: replace(s, '[.url?, .deployment.url?]', '[.alias?, .url?, .deployment.url?]')),
    ('P2-4 ambiguous anchor', 'test_explicit_rollback_anchor', lambda s: replace(s, 'if length == 1 and', 'if length >= 1 and')),
    ('P2-5 allowlist order', 'test_first_validation_and_pins', lambda s: move_after(s, 'Prepare staging aliases', BUILD)),
    ('P2-5 input order', 'test_first_validation_and_pins', lambda s: move_after(s, 'Validate staging inputs', BUILD)),
    ('P2-5 checkout pin', 'test_first_validation_and_pins', lambda s: replace(s, 'actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683', 'actions/checkout@v4')),
    ('P2-5 setup-node pin', 'test_first_validation_and_pins', lambda s: replace(s, 'actions/setup-node@49933ea5288caeca8642d1e84afbd3f7d6820020', 'actions/setup-node@v4')),
    ('P2-5 build HOME', 'test_fresh_homes', lambda s: block(s, BUILD, lambda b: replace(b, 'HOME="$build_private/home" TMPDIR=', 'HOME="${HOME:-/tmp}" TMPDIR='))),
    ('P2-5 smoke HOME', 'test_fresh_homes', lambda s: block(s, SMOKE, lambda b: replace(b, 'HOME="$private_root/home" TMPDIR=', 'HOME="${HOME:-/tmp}" TMPDIR='))),
    ('P2-5 build TMPDIR', 'test_fresh_homes', lambda s: block(s, BUILD, lambda b: replace(b, 'TMPDIR="$build_private/tmp"', 'TMPDIR="${TMPDIR:-/tmp}"'))),
    ('P2-5 smoke TMPDIR', 'test_fresh_homes', lambda s: block(s, SMOKE, lambda b: replace(b, 'TMPDIR="$private_root/tmp"', 'TMPDIR="${TMPDIR:-/tmp}"'))),
    ('P1-1 defense control HOME', 'test_defense_environment', lambda s: block(s, CONTROL, lambda b: replace(b, 'HOME="$private_root/home"', 'HOME="${HOME:-/tmp}"'))),
    ('P1-1 defense control TMPDIR', 'test_defense_environment', lambda s: block(s, CONTROL, lambda b: replace(b, 'TMPDIR="$private_root/tmp"', 'TMPDIR="${TMPDIR:-/tmp}"'))),
    ('P1-1 defense privileged shell', 'test_defense_environment', lambda s: block(s, CONTROL, lambda b: replace(b, 'shell: /bin/bash --noprofile --norc -p', 'shell: /bin/bash --noprofile --norc'))),
    ('P1-1 defense control PATH', 'test_defense_environment', lambda s: block(s, CONTROL, lambda b: replace(b, 'PATH=/usr/bin:/bin HOME=', 'PATH="${PATH:-/usr/bin:/bin}" HOME='))),
    ('P1-1 defense smoke PATH', 'test_fresh_homes', lambda s: block(s, SMOKE, lambda b: replace(b, 'PATH=/usr/bin:/bin HOME=', 'PATH="${PATH:-/usr/bin:/bin}" HOME='))),
    ('P2-5 settings validation order', 'test_first_validation_and_pins', lambda s: move_after(s, 'Validate reviewed project settings', BUILD)),
    ('P2-5 early settings validation', 'test_first_validation_and_pins', lambda s: block(s, 'Validate reviewed project settings', lambda b: replace(b, 'settings = json.loads(os.environ["PROJECT_SETTINGS_JSON"])', 'settings = {"framework": None}'))),
    ('P2-5 early SHA validation', 'test_first_validation_and_pins', lambda s: replace(s, 'if [[ ! "$EXPECTED_SHA" =~ ^[0-9a-f]{40}$ ]]; then', 'if false; then')),
    ('P1-1 defense group verification', 'test_build_cleanup_failure', lambda s: replace(s, 'raise SystemExit("::error::Build process group survived cleanup")', 'pass # verification removed')),
    ('P3 hash before execution', 'test_hash_before_execution', lambda s: move_hash(s)),
    ('P3 node path traversal', 'test_first_validation_and_pins', lambda s: replace(s, 'if [[ ! "$NODE_VERSION_FILE" =~ ^[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)*$ ]] || [[ "/$NODE_VERSION_FILE/" == */../* ]] || [[ "/$NODE_VERSION_FILE/" == */./* ]]; then', 'if false; then')),
    ('P3 rollback cleanup', 'test_rollback_files_cleaned', lambda s: replace(s, 'trap \'for file in "$rollback_prefix"-*.target; do [ ! -f "$file" ] || /usr/bin/rm -f -- "$file"; done\' EXIT', ': # rollback file cleanup removed')),
    ('P1-1 defense control inherited check', 'test_defense_environment', lambda s: block(s, CONTROL, remove_check)),
    ('P1-1 defense smoke inherited check', 'test_defense_environment', lambda s: block(s, SMOKE, remove_check)),
    ('P1-1 defense control scrub', 'test_defense_environment', lambda s: block(s, CONTROL, lambda b: replace(b, '/usr/bin/env -i', '/usr/bin/env'))),
    ('P1-1 defense smoke scrub', 'test_fresh_homes', lambda s: block(s, SMOKE, lambda b: replace(b, '/usr/bin/env -i', '/usr/bin/env'))),
    ('P1-1 defense build scrub', 'test_fresh_homes', lambda s: block(s, BUILD, lambda b: replace(b, '/usr/bin/env -i', '/usr/bin/env'))),
    ('P1-1 defense build session', 'test_build_process_group', lambda s: replace(s, '["/usr/bin/setsid", "--", sys.argv[2]', '[sys.argv[2]')),
    ('P1-1 defense group kill', 'test_build_process_group', lambda s: replace(s, 'os.killpg(child.pid, signal.SIGKILL)', 'pass # group kill removed')),
]


def remove_check(s):
    return replace(s, 'echo "::error::Unsafe inherited environment: $inherited_name"\n                exit 1', 'echo "inherited check removed"')


def move_after(s, name, after):
    start = s.index('      - name: ' + name + '\n')
    end = s.index('      - name: ', start + 10)
    part = s[start:end]
    s = s[:start] + s[end:]
    target = s.index('      - name: ', s.index('      - name: ' + after + '\n') + 10)
    return s[:target] + part + s[target:]


def move_hash(s):
    start = s.index('          read -r ACTUAL_VERCEL_CLI_SHA256')
    end = s.index('          VERCEL_VERSION_OUTPUT=', start)
    part = s[start:end]
    s = s[:start] + s[end:]
    target = s.index('          {\n            echo "git=')
    return s[:target] + part + s[target:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', nargs='?', const='593a04403693e408248870c6c5c284ea243581b9')
    args = parser.parse_args()
    current = WORKFLOW.read_text()
    cases = MUTATIONS
    if args.baseline:
        baseline = subprocess.check_output(['git', 'show', args.baseline + ':.github/workflows/vercel-staging-reusable.yml'], cwd=ROOT, text=True)
        cases = [(name, test, lambda _, text=baseline: text) for name, test, _ in MUTATIONS]
    with tempfile.TemporaryDirectory(prefix='vercel-staging-mutations-') as tmp:
        for number, (name, test, mutate) in enumerate(cases, 1):
            path = Path(tmp) / f'{number}.yml'
            path.write_text(mutate(current))
            result = subprocess.run(['bash', str(HARNESS)], cwd=ROOT, env=os.environ | {'WORKFLOW_FILE': str(path), 'TEST_ONLY': test}, capture_output=True, text=True, timeout=60)
            if result.returncode == 0 or result.returncode == 77:
                raise SystemExit(f'NOT CAUGHT: {name}\n{result.stdout}{result.stderr}')
            # Syntax errors or a broken harness cannot count as regression evidence.
            output = result.stdout + result.stderr
            if any(marker in output for marker in ('syntax error', 'command not found', 'unbound variable', 'could not extract workflow step')):
                raise SystemExit(f'INVALID MUTATION FAILURE: {name}\n{output}')
            evidence = output.strip().splitlines()[-1]
            print(f'caught {number}/{len(cases)} - {name}: {evidence}', flush=True)
    print(f'All {len(cases)} {"baseline regressions reproduced" if args.baseline else "mutations caught"}.')


if __name__ == '__main__':
    main()
