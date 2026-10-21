#!/usr/bin/env python3
"""Offline fixtures for the actual pinned CLI and extracted workflow steps.

Set VERCEL_REAL_CLI to the installed vercel@56.3.1 dist/vc.js. Exit 77 is a
loud skip, never a pass. No installation, service call, or real credential.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import yaml

PIN = 'c0e8cfad56746ea7a496604fc8b1e9ef71624d1784f07415a41777bdddb2536f'
cli = Path(os.environ.get('VERCEL_REAL_CLI', ''))
if not cli.is_file() or hashlib.sha256(cli.read_bytes()).hexdigest() != PIN:
    print('SKIP (not PASS): set VERCEL_REAL_CLI to the exact pinned 56.3.1 dist/vc.js; path/hash unavailable or mismatched.', file=sys.stderr)
    sys.exit(77)
cli = cli.resolve()
workflow = yaml.safe_load((Path(__file__).resolve().parent.parent / '.github/workflows/vercel-staging-reusable.yml').read_text())
steps = {s.get('id', s['name']): s for s in workflow['jobs']['deploy-staging']['steps']}
sha = '1' * 40

with tempfile.TemporaryDirectory(prefix='vercel-real-cli-offline-') as tmp:
    root = Path(tmp)
    neutral = root / 'neutral'
    neutral.mkdir()
    guard = root / 'deny-network.cjs'
    guard.write_text('''
const fs = require('node:fs');
function deny() {
  fs.appendFileSync(process.env.OFFLINE_NETWORK_LOG, 'blocked-network\\n');
  process.stderr.write('OFFLINE_NETWORK_BLOCKED\\n');
  process.exit(86);
}
// Refuse an optional native CLI, which would escape this JS transport guard.
const cp = require('node:child_process');
const spawnSync = cp.spawnSync;
cp.spawnSync = function(file, ...args) {
  if (String(file).includes('vc-native-')) throw new Error('OFFLINE_UNGUARDED_NATIVE_CLI');
  return spawnSync.call(this, file, ...args);
};
require('node:net').Socket.prototype.connect = deny;
require('node:dgram').Socket.prototype.send = deny;
require('node:dgram').Socket.prototype.connect = deny;
const dns = require('node:dns');
for (const api of [dns, dns.promises]) {
  for (const key of Object.keys(api)) {
    if (key.startsWith('lookup') || key.startsWith('resolve')) api[key] = deny;
  }
}
''')
    node = root / 'offline-node'
    node.write_text('''#!/bin/bash
set -euo pipefail
[ "${1:-}" != -- ] || shift
args=("$@")
selected_cwd='<none>'
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[$i]}" = --cwd ]; then selected_cwd=${args[$((i+1))]}; fi
done
printf '%s\\n' "$selected_cwd" >> "$OFFLINE_CWD_LOG"
exec /usr/bin/node --require "$OFFLINE_GUARD" -- "$@" --api http://127.0.0.1:9 --non-interactive
''')
    node.chmod(0o755)
    env = {
        'PATH': '/usr/bin:/bin', 'HOME': str(neutral), 'CI': '1',
        'NO_UPDATE_NOTIFIER': '1', 'VERCEL_TELEMETRY_DISABLED': '1',
        'OFFLINE_GUARD': str(guard), 'OFFLINE_NETWORK_LOG': str(root / 'network.log'),
        'OFFLINE_CWD_LOG': str(root / 'cwd.log'),
        'NODE_BIN': str(node), 'VERCEL_BIN': str(cli), 'PYTHON_BIN': '/usr/bin/python3',
        'NEUTRAL_DIR': str(neutral), 'EXPECTED_SHA': sha, 'ORIGIN_DEV_SHA': sha,
        'VERCEL_ORG_ID': 'team_offline_fixture', 'VERCEL_PROJECT_ID': 'prj_offline_fixture',
        'PROJECT_SETTINGS_JSON': json.dumps({'framework': None, 'installCommand': '', 'buildCommand': '', 'outputDirectory': 'public', 'rootDirectory': None, 'nodeVersion': '22.x'}),
        'STAGING_ALIASES': 'pythonlife.org,staging.lm.fm', 'JQ_BIN': '/usr/bin/jq',
        'GITHUB_OUTPUT': str(root / 'output'), 'GITHUB_RUN_ID': '1', 'GITHUB_RUN_ATTEMPT': '1',
    }

    def run(argv, cwd, extra=None):
        result = subprocess.run(argv, cwd=cwd, env=env | (extra or {}), text=True, capture_output=True, timeout=45)
        return result

    def require(condition, message, result=None):
        if not condition:
            if result:
                print(result.stdout + result.stderr, file=sys.stderr)
            raise AssertionError(message)

    version = run(['/usr/bin/node', '--require', str(guard), '--', str(cli), '--version'], neutral)
    require(version.returncode == 0 and version.stdout.strip() == '56.3.1', 'real CLI version mismatch', version)
    scripts = {}
    for key in ('build', 'deploy_context', 'control', 'Clean staging deploy context'):
        script = root / (key.replace(' ', '-') + '.sh')
        script.write_text(steps[key]['run'])
        scripts[key] = script

    def step(key, cwd, extra=None):
        Path(env['GITHUB_OUTPUT']).write_text('')
        result = run(['/bin/bash', '--noprofile', '--norc', '-e', '-o', 'pipefail', str(scripts[key])], cwd, extra)
        outputs = dict(line.split('=', 1) for line in Path(env['GITHUB_OUTPUT']).read_text().splitlines() if '=' in line)
        return result, outputs

    source = root / 'fresh-source'
    (source / 'public').mkdir(parents=True)
    (source / 'public/index.html').write_text('fresh-exact-sha-' + sha)
    require(not (source / '.vercel').exists(), 'fixture must start without any local Vercel state')
    missing = run([str(node), '--', str(cli), 'build'], source)
    require(missing.returncode != 0 and 'project settings' in (missing.stdout + missing.stderr).lower(), 'fresh build must fail specifically for missing project settings', missing)
    require(not (source / '.vercel/output/config.json').exists(), 'missing settings must not produce a build')
    print('ok - real fresh build fails without settings')

    built, receipt = step('build', source)
    require(built.returncode == 0, 'real tokenless build with explicit settings must succeed', built)
    require(receipt.get('source_dir') == str(source) and receipt.get('source_sha') == sha, 'build must emit the exact source receipt')
    require((source / '.vercel/output/config.json').is_file(), 'real build output missing')
    (neutral / '.vercel/output/static').mkdir(parents=True)
    (neutral / '.vercel/output/config.json').write_text('{"version":3}')
    (neutral / '.vercel/output/static/index.html').write_text('STALE-NEUTRAL')
    env.update(BUILD_SOURCE_DIR=receipt['source_dir'], BUILD_SOURCE_SHA=receipt['source_sha'])
    print('ok - real tokenless build succeeds with explicit non-secret settings')

    marker = root / 'config-marker'
    for ext in ('ts', 'js', 'cjs'):
        config = source / ('vercel.' + ext)
        tail = 'module.exports = {};' if ext == 'cjs' else 'export default {};'
        config.write_text("if (process.env.VERCEL_TOKEN) { process.getBuiltinModule('fs').writeFileSync(process.env.CONFIG_MARKER, 'token-readable'); }\n" + tail)
        token = {'VERCEL_TOKEN': 'syntheticOfflineToken', 'CONFIG_MARKER': str(marker)}
        # Positive control proves the actual pinned compiler reaches this marker
        # before its network attempt. The protected workflow must exclude it.
        direct = run([str(node), '--', str(cli), 'deploy', '--prebuilt', '--cwd', str(source), '--token=syntheticOfflineToken'], neutral, token)
        require(marker.exists() and marker.read_text() == 'token-readable', 'positive control failed: real config dispatch did not execute ' + ext, direct)
        marker.unlink()
        context, output = step('deploy_context', source)
        require(context.returncode == 0, 'context preparation failed', context)
        deploy = Path(output['deploy_dir'])
        require({p.name for p in deploy.iterdir()} == {'.vercel'}, 'source files copied into deploy root')
        require({p.name for p in (deploy / '.vercel').iterdir()} == {'output', 'project.json'}, 'unexpected Vercel state copied')
        require(json.loads((deploy / '.vercel/project.json').read_text()) == {'orgId': env['VERCEL_ORG_ID'], 'projectId': env['VERCEL_PROJECT_ID']}, 'deploy link must contain IDs only')
        fresh = (source / '.vercel/output/static/index.html').read_bytes()
        require((deploy / '.vercel/output/static/index.html').read_bytes() == fresh and b'STALE' not in fresh, 'deploy did not receive the actual fresh build payload')
        env.update(DEPLOY_DIR=str(deploy), DEPLOY_SOURCE_SHA=output['source_sha'])
        network_log = Path(env['OFFLINE_NETWORK_LOG'])
        network_log.write_text('')
        Path(env['OFFLINE_CWD_LOG']).write_text('')
        controlled, outcome = step('control', neutral, token)
        require(controlled.returncode == 0 and outcome.get('result') == 'failed', 'offline deploy must fail closed at the blocked service boundary', controlled)
        require(Path(env['OFFLINE_CWD_LOG']).read_text().splitlines() == [str(deploy)], 'real CLI invocation selected a different prebuilt context', controlled)
        require(not marker.exists(), 'workflow evaluated source config with token for ' + ext, controlled)
        require(network_log.exists() and 'blocked-network' in network_log.read_text(), 'real CLI did not reach the guarded transport; an earlier failure could hide config evaluation', controlled)
        cleaned, _ = step('Clean staging deploy context', neutral)
        require(cleaned.returncode == 0 and not deploy.exists(), 'context cleanup failed', cleaned)
        config.unlink()
        # The direct positive control may leave a compiled config; it must not
        # enter the minimal context on subsequent attempts.
        print('ok - real ' + ext + ' marker executes directly but never in workflow deploy')

    for name, changes in (('wrong SHA', {'BUILD_SOURCE_SHA': '2' * 40}), ('wrong path', {'BUILD_SOURCE_DIR': str(neutral)}), ('missing receipt', {'BUILD_SOURCE_SHA': ''})):
        invalid, output = step('deploy_context', source, changes)
        require(invalid.returncode != 0 and not output and 'Staging build binding failed' in invalid.stdout, name + ' must be rejected before deploy', invalid)
    shutil.rmtree(source / '.vercel/output')
    invalid, output = step('deploy_context', source)
    require(invalid.returncode != 0 and not output, 'missing fresh output must not fall back to stale neutral output', invalid)
    print('ok - stale/wrong-SHA/missing real build bindings are rejected')
    print('All offline real-CLI fixture groups passed; sockets/DNS blocked, synthetic token only.')
