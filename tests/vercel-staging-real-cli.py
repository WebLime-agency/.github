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
import stat
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
// Synthetic metadata only: let the real CLI cross project lookup and reach
// its second compileVercelConfig(rootDirectory). Every other request is denied
// in memory; the socket/DNS guards above remain active.
if (Object.hasOwn(process.env, 'OFFLINE_PROJECT_ROOT')) {
  const {Writable, Readable} = require('node:stream');
  function reply(path) {
    fs.appendFileSync(process.env.OFFLINE_NETWORK_LOG, 'mock ' + path + '\\n');
    if (path.includes('/projects/')) {
      fs.appendFileSync(process.env.OFFLINE_NETWORK_LOG, 'project-root=' + process.env.OFFLINE_PROJECT_ROOT + '\\n');
      return [200, {id:process.env.VERCEL_PROJECT_ID, name:'offline', accountId:process.env.VERCEL_ORG_ID, rootDirectory:process.env.OFFLINE_PROJECT_ROOT || null, framework:null, link:null}];
    }
    if (path.includes('/teams/')) return [200, {id:process.env.VERCEL_ORG_ID, slug:'offline', name:'offline', type:'team'}];
    if (path.includes('/user')) return [200, {user:{id:'offline', username:'offline', name:'offline'}}];
    fs.appendFileSync(process.env.OFFLINE_NETWORK_LOG, 'upload-refused\\n');
    return [400, {error:{code:'OFFLINE_STOP',message:'OFFLINE_UPLOAD_REFUSED'}}];
  }
  function request(...args) {
    const first=args[0];
    const opts=(typeof first==='object' && !(first instanceof URL)) ? first : args[1] || {};
    const path=opts.path || (typeof first==='string' ? new URL(first).pathname : first.pathname);
    const [status,body]=reply(path);
    const q=new Writable({write(chunk, encoding, done){done();}});
    q.abort=()=>q.destroy(); q.setTimeout=()=>q; q.setHeader=()=>q; q.getHeader=()=>null; q.removeHeader=()=>q;
    q.end=function(...endArgs) {
      Writable.prototype.end.apply(this,endArgs);
      process.nextTick(()=>{
        const response=Readable.from([Buffer.from(JSON.stringify(body))]);
        response.statusCode=status; response.statusMessage='Offline fixture';
        response.headers={'content-type':'application/json'}; response.rawHeaders=['content-type','application/json']; response.httpVersion='1.1';
        const callback=args.findLast(arg=>typeof arg==='function');
        if(callback) callback(response);
        q.emit('response',response);
      });
      return q;
    };
    return q;
  }
  for(const name of ['node:http','node:https']) {
    const api=require(name); api.request=request; api.get=(...args)=>{const q=request(...args);q.end();return q;};
  }
  globalThis.fetch=async(input)=>{
    const [status,body]=reply(new URL(String(input.url || input)).pathname);
    return new Response(JSON.stringify(body),{status,headers:{'content-type':'application/json'}});
  };
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
        result = subprocess.run(argv, cwd=cwd, env=env | (extra or {}), text=True, capture_output=True, timeout=45, umask=0)
        return result

    def require(condition, message, result=None):
        if not condition:
            if result:
                print(result.stdout + result.stderr, file=sys.stderr)
            raise AssertionError(message)

    version = run(['/usr/bin/node', '--require', str(guard), '--', str(cli), '--version'], neutral)
    require(version.returncode == 0 and version.stdout.strip() == '56.3.1', 'real CLI version mismatch', version)
    scripts = {}
    for key in ('build', 'deploy_context', 'control', 'Clean staging deploy context', 'smoke'):
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
    require(stat.S_IMODE((source / '.vercel').stat().st_mode) == 0o700, 'settings dir must be 0700 under umask 000')
    require(stat.S_IMODE((source / '.vercel/project.json').stat().st_mode) == 0o600, 'settings file must be 0600 under umask 000')
    settings_file = source / '.vercel/project.json'
    original_settings = settings_file.read_bytes()
    settings_file.chmod(0o666)
    reused, outputs = step('build', source)
    require(reused.returncode != 0 and not outputs and 'Refusing existing Vercel project settings' in reused.stderr, 'pre-existing 0666 project settings must not be reused', reused)
    require(settings_file.read_bytes() == original_settings, 'existing project settings were overwritten')
    settings_file.chmod(0o600)
    print('ok - real settings permissions are explicit under umask 000; existing 0666 link refused')
    monorepo = root / 'monorepo'
    (monorepo / 'apps/web/public').mkdir(parents=True)
    (monorepo / 'apps/web/public/index.html').write_text('unsupported-monorepo')
    rejected, outputs = step('build', monorepo, {'PROJECT_SETTINGS_JSON': json.dumps({'rootDirectory':'apps/web','framework':None,'installCommand':'','buildCommand':'','outputDirectory':'public'})})
    require(rejected.returncode != 0 and not outputs and 'Unsupported Vercel root directory' in rejected.stderr, 'nonempty rootDirectory must be rejected before real build', rejected)
    require(not (monorepo / '.vercel/project.json').exists(), 'unsupported root wrote project settings')
    print('ok - nonempty project root is rejected before real build')
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
        require(stat.S_IMODE((deploy / '.vercel').stat().st_mode) == 0o700, 'deploy link dir must be 0700')
        require(stat.S_IMODE((deploy / '.vercel/project.json').stat().st_mode) == 0o600, 'deploy link must be 0600')
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

    context, output = step('deploy_context', source)
    require(context.returncode == 0, 'clean deep-probe context must prepare', context)
    deploy = Path(output['deploy_dir'])
    env.update(DEPLOY_DIR=str(deploy), DEPLOY_SOURCE_SHA=output['source_sha'])
    hostile = {'OFFLINE_PROJECT_ROOT':'.vercel/output', 'VERCEL_TOKEN':'syntheticOfflineToken', 'CONFIG_MARKER':str(marker)}
    artifact_config = deploy / '.vercel/output/vercel.cjs'
    artifact_config.write_text("if(process.env.VERCEL_TOKEN) process.getBuiltinModule('fs').writeFileSync(process.env.CONFIG_MARKER,'token-readable'); module.exports={};")
    direct = run([str(node), '--', str(cli), 'deploy', '--prebuilt', '--cwd', str(deploy), '--token=syntheticOfflineToken'], neutral, hostile)
    require(marker.exists() and marker.read_text() == 'token-readable', 'positive control did not reach remote-root config compilation', direct)
    marker.unlink()
    # Remove the positive compiler's cache BEFORE testing the workflow. A
    # compiled vercel.json must not mask an omitted vercel.cjs inventory ban.
    shutil.rmtree(deploy / '.vercel/output/.vercel', ignore_errors=True)
    Path(env['OFFLINE_NETWORK_LOG']).write_text('')
    Path(env['OFFLINE_CWD_LOG']).write_text('')
    controlled, outcome = step('control', neutral, hostile)
    require(controlled.returncode == 0 and outcome.get('result') == 'failed' and not marker.exists(), 'recursive control inventory allowed token-readable artifact config', controlled)
    require(not Path(env['OFFLINE_CWD_LOG']).read_text() and not Path(env['OFFLINE_NETWORK_LOG']).read_text(), 'unsafe artifact must be rejected before CLI/project lookup', controlled)
    artifact_config.unlink()
    Path(env['OFFLINE_NETWORK_LOG']).write_text('')
    controlled, outcome = step('control', neutral, hostile)
    evidence = Path(env['OFFLINE_NETWORK_LOG']).read_text()
    require(controlled.returncode == 0 and outcome.get('result') == 'failed' and not marker.exists(), 'hostile remote root must not execute code', controlled)
    require('project-root=.vercel/output' in evidence and 'upload-refused' in evidence, 'deep real CLI probe did not proceed past project lookup to refused upload', controlled)
    cleaned, _ = step('Clean staging deploy context', neutral)
    require(cleaned.returncode == 0, 'deep-probe cleanup failed', cleaned)
    # Also verify rejection before copy, rather than only at token boundary.
    source_config = source / '.vercel/output/functions/probe.func/nested/vercel.cjs'
    source_config.parent.mkdir(parents=True)
    source_config.write_text('module.exports={};')
    rejected, outputs = step('deploy_context', source)
    require(rejected.returncode != 0 and not outputs and 'Unsafe prebuilt output' in rejected.stderr, 'source artifact config must be refused before copy', rejected)
    source_config.unlink()
    link = source / '.vercel/output/link'
    link.symlink_to(source / 'public/index.html')
    rejected, outputs = step('deploy_context', source)
    require(rejected.returncode != 0 and not outputs and 'Unsafe prebuilt output' in rejected.stderr, 'source artifact symlink must be rejected', rejected)
    link.unlink()
    context, output = step('deploy_context', source)
    require(context.returncode == 0, 'FIFO probe context must prepare', context)
    deploy = Path(output['deploy_dir'])
    env.update(DEPLOY_DIR=str(deploy), DEPLOY_SOURCE_SHA=output['source_sha'])
    os.mkfifo(deploy / '.vercel/output/fifo')
    Path(env['OFFLINE_CWD_LOG']).write_text('')
    controlled, outcome = step('control', neutral, hostile)
    require(controlled.returncode == 0 and outcome.get('result') == 'failed' and not Path(env['OFFLINE_CWD_LOG']).read_text(), 'special file must be rejected before CLI invocation', controlled)
    cleaned, _ = step('Clean staging deploy context', neutral)
    require(cleaned.returncode == 0, 'FIFO context cleanup failed', cleaned)
    print('ok - remote-root config execution reproduced directly; recursive workflow inventory blocks it')

    # URL validation belongs to the workflow, not Vercel CLI. Exercise the real
    # extracted smoke/Python parser here with a synthetic curl response only.
    curl = root / 'curl-fixture'
    curl.write_text("#!/usr/bin/python3\nimport os,sys\nif '--config' in sys.argv: sys.stdin.read()\nprint('200 ' + os.environ['OFFLINE_LANDING'])\n")
    curl.chmod(0o755)
    smoke_env = {'CURL_BIN':str(curl), 'DEPLOYMENT_URL':'https://candidate.vercel.app', 'PROMOTED_ALIASES':'pythonlife.org,staging.lm.fm', 'VERCEL_AUTOMATION_BYPASS_SECRET':'syntheticBypass'}
    for url in ('https://vercel.com/%6cogin', 'https://vercel.com/a/%2e%2e/%6cogin', 'http://vercel.com/login', 'https://vercel.com/team/%73so',
                'https://vercel.com。/login',
                'https://vercel.com．/login',
                'https://vercel.com｡/login',
                'https://vercel.com。:443/login',
                'https://vercel.com．:443/login',
                'https://vercel.com｡:443/login',
                'https://vercel.com%E3%80%82/login'):
        result, output = step('smoke', neutral, smoke_env | {'OFFLINE_LANDING':url})
        require(result.returncode == 0 and output.get('result') == 'failed' and 'Staging smoke hit Vercel login' in result.stdout, 'decoded/HTTP login must produce login-specific rejection', result)
    for url in ('http://app.example/ok', 'https:///bad', 'https://app.example:bad/ok', 'https://app.example/%zz', 'https://app%20example/ok'):
        result, output = step('smoke', neutral, smoke_env | {'OFFLINE_LANDING':url})
        require(result.returncode == 0 and output.get('result') == 'failed' and 'Staging smoke unsafe landing' in result.stdout, 'unsafe final landing must fail closed', result)
    print('ok - actual workflow URL parser rejects encoded/dot-segment/HTTP login and unsafe landings')

    for name, changes in (('wrong SHA', {'BUILD_SOURCE_SHA': '2' * 40}), ('wrong path', {'BUILD_SOURCE_DIR': str(neutral)}), ('missing receipt', {'BUILD_SOURCE_SHA': ''})):
        invalid, output = step('deploy_context', source, changes)
        require(invalid.returncode != 0 and not output and 'Staging build binding failed' in invalid.stdout, name + ' must be rejected before deploy', invalid)
    shutil.rmtree(source / '.vercel/output')
    invalid, output = step('deploy_context', source)
    require(invalid.returncode != 0 and not output, 'missing fresh output must not fall back to stale neutral output', invalid)
    print('ok - stale/wrong-SHA/missing real build bindings are rejected')
    print('All offline real-CLI fixture groups passed; sockets/DNS blocked, synthetic token only.')
