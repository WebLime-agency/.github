const assert = require('node:assert/strict');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const vm = require('node:vm');
const { test } = require('node:test');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const workflow = fs.readFileSync(path.join(root, '.github/workflows/claude-review-reusable.yml'), 'utf8');
const mention = fs.readFileSync(path.join(root, '.github/workflows/claude-mention-reusable.yml'), 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

function jobGate(source, job) {
  const block = source.split(`  ${job}:\n`)[1];
  assert.ok(block, `missing job ${job}`);
  const expression = block.match(/^    if: \|\n((?:      .*\n)+)/m)?.[1];
  assert.ok(expression, `missing job gate for ${job}`);
  return expression.trim();
}

function step(name, kind = 'script') {
  const block = workflow.split(`      - name: ${name}\n`)[1]?.split('      - name: ')[0];
  assert.ok(block, `missing step ${name}`);
  const indent = kind === 'script' ? 12 : 10;
  const lines = block.split(`          ${kind}: |\n`)[1] ||
    block.split(`        ${kind}: |\n`)[1];
  assert.ok(lines, `missing ${kind} for ${name}`);
  const output = [];
  for (const line of lines.split('\n')) {
    if (line.trim() && !line.startsWith(' '.repeat(indent))) break;
    output.push(line.slice(indent));
  }
  return output.join('\n');
}

function evaluate(source, job, options = {}) {
  const { eventName = 'issue_comment', action = 'created', association = 'MEMBER',
    body = '@claude review', pr = true, type = 'User', attempt = 1 } = options;
  return Boolean(vm.runInNewContext(jobGate(source, job), {
    github: {
      event_name: eventName, run_attempt: attempt, repository: 'example/app',
      event: { action, pull_request: { draft: false, head: { repo: { full_name: 'example/app' } } },
        issue: { pull_request: pr ? {} : null },
        comment: { body, author_association: association, user: { type } } },
    },
    contains: (haystack, needle) => String(haystack || '').toLowerCase().includes(needle.toLowerCase()),
  }));
}

const prepare = step('Prepare authorized revision-bound request');
const confirm = step('Revalidate before provider invocation');
const publish = step('Publish only a current-head result');
const model = step('Run isolated Claude review', 'run');

async function fixture(t) {
  const scratch = await fsp.mkdtemp(path.join(os.tmpdir(), 'claude-review-test-'));
  t.after(() => fsp.rm(scratch, { recursive: true, force: true }));
  const timestamp = '2026-11-09T18:00:00Z';
  const request = { id: 7, user: { id: 11, login: 'maintainer', type: 'User' },
    author_association: 'MEMBER', body: '@claude review', created_at: timestamp, updated_at: timestamp };
  const context = { repo: { owner: 'example', repo: 'app' }, actor: 'maintainer',
    apiUrl: 'https://api.github.invalid', serverUrl: 'https://github.invalid', runId: 123,
    eventName: 'issue_comment',
    payload: { action: 'created', comment: structuredClone(request),
      issue: { number: 5, pull_request: {} }, sender: { id: 11 } } };
  const state = { request: { ...request, issue_url: context.apiUrl + '/repos/example/app/issues/5' },
    permission: 'write', pr: { number: 5, state: 'open', draft: false,
      base: { sha: 'a'.repeat(40), repo: { full_name: 'example/app' } },
      head: { sha: 'b'.repeat(40), repo: { full_name: 'example/app' } },
      changed_files: 1, additions: 1, deletions: 1 },
    comparison: { merge_base_commit: { sha: 'c'.repeat(40) },
      files: [{ filename: 'file.js', status: 'modified', additions: 1, deletions: 1,
        patch: '@@ -1 +1 @@\n-old\n+new' }] },
    comments: [], writes: [], reads: [], outputs: {}, notices: [], failures: [] };
  const read = (name, data) => async args => { state.reads.push([name, args]); return { data: structuredClone(data()) }; };
  const github = { rest: {
    repos: { getCollaboratorPermissionLevel: read('permission', () => ({ permission: state.permission })),
      compareCommits: read('compare', () => state.comparison) },
    pulls: { get: read('pr', () => state.pr) },
    issues: {
      getComment: async args => {
        state.reads.push(['comment', args]);
        if (state.deleted) throw Object.assign(new Error('Not found'), { status: 404 });
        return { data: structuredClone(state.request) };
      },
      listComments: read('comments', () => state.comments),
      createComment: async args => {
        state.writes.push(['create', args]);
        state.comments.push({ id: 101, user: { login: 'github-actions[bot]', type: 'Bot' }, body: args.body });
        return { data: { id: 101 } };
      },
      updateComment: async args => { state.writes.push(['update', args]); return { data: {} }; },
    },
  } };
  const core = { notice: message => state.notices.push(message),
    setOutput: (name, value) => { state.outputs[name] = value; },
    setFailed: message => state.failures.push(message) };
  const env = { RUNNER_TEMP: scratch, GITHUB_RUN_ATTEMPT: '1' };
  async function run(script) {
    await new AsyncFunction('require', 'github', 'context', 'core', 'process', script)(
      require, github, context, core, { env });
    return state;
  }
  async function ready() {
    await run(prepare);
    assert.equal(state.outputs.ready, 'true', state.notices.join('\n'));
    env.REVIEW_DIRECTORY = state.outputs.directory;
    return JSON.parse(await fsp.readFile(path.join(env.REVIEW_DIRECTORY, 'request.json'), 'utf8'));
  }
  async function result(value = { type: 'result', subtype: 'success', is_error: false, result: 'Synthetic finding.' }) {
    env.MODEL_OUTCOME = 'success';
    await fsp.writeFile(path.join(env.REVIEW_DIRECTORY, 'result.json'), JSON.stringify(value));
  }
  return { scratch, state, context, env, run, ready, result };
}

test('legacy PR events and manual/target/schedule events skip the entire job', () => {
  for (const eventName of ['pull_request', 'pull_request_target', 'workflow_dispatch', 'schedule']) {
    for (const action of ['opened', 'synchronize', 'ready_for_review', 'reopened'])
      assert.equal(evaluate(workflow, 'claude-review', { eventName, action }), false);
  }
});

test('only fresh trusted human review comments on PRs enter the job', () => {
  for (const association of ['OWNER', 'MEMBER', 'COLLABORATOR'])
    assert.equal(evaluate(workflow, 'claude-review', { association }), true);
  for (const association of ['NONE', 'CONTRIBUTOR', 'FIRST_TIME_CONTRIBUTOR'])
    assert.equal(evaluate(workflow, 'claude-review', { association }), false);
  for (const options of [{ action: 'edited' }, { action: 'deleted' }, { type: 'Bot' },
    { body: '@claude explain' }, { pr: false }, { attempt: 2 }])
    assert.equal(evaluate(workflow, 'claude-review', options), false);
});

test('generic mention routing is preserved without double invocation on review requests', () => {
  assert.equal(evaluate(mention, 'claude', { body: '@claude explain this' }), true);
  assert.equal(evaluate(mention, 'claude'), false);
  assert.equal(evaluate(mention, 'claude', { body: '@CLAUDE REVIEW this' }), false);
  assert.equal(evaluate(mention, 'claude', { body: '@claude review', pr: false }), true);
  assert.equal(evaluate(mention, 'claude', { eventName: 'pull_request_review_comment', body: '@claude help' }), true);
});

test('snapshot and durable claim bind the actual base/head and full patch', async t => {
  const f = await fixture(t);
  const snapshot = await f.ready();
  assert.equal(snapshot.base, f.state.pr.base.sha);
  assert.equal(snapshot.head, f.state.pr.head.sha);
  const prompt = await fsp.readFile(path.join(f.env.REVIEW_DIRECTORY, 'prompt.txt'), 'utf8');
  assert.ok(prompt.includes(f.state.comparison.files[0].patch.replaceAll('\n', '\\n')));
  assert.ok(!prompt.includes('@claude review'));
  await f.run(confirm);
  assert.equal(f.state.outputs.invoke, 'true');
  await f.result();
  await f.run(publish);
  assert.equal(f.state.failures.length, 0);
  const posted = f.state.writes.at(-1)[1];
  assert.equal(posted.comment_id, snapshot.claim);
  assert.ok(posted.body.includes('Synthetic finding.'));
  assert.ok(posted.body.includes(snapshot.head));
});

test('script-level event gate also rejects invalid callers before any API access', async t => {
  for (const change of [
    f => { f.context.eventName = 'pull_request'; },
    f => { f.context.payload.action = 'edited'; },
    f => { f.env.GITHUB_RUN_ATTEMPT = '2'; },
    f => { f.context.payload.comment.user.type = 'Bot'; },
    f => { f.context.payload.sender.id = 99; },
    f => { f.context.actor = 'someone-else'; },
    f => { f.context.payload.comment.author_association = 'NONE'; },
    f => { f.context.payload.issue.pull_request = null; },
    f => { f.context.payload.comment.body = '@claude reviews'; },
  ]) {
    const f = await fixture(t); change(f); await f.run(prepare);
    assert.equal(f.state.outputs.ready, undefined);
    assert.equal(f.state.reads.length, 0);
    assert.equal(f.state.writes.length, 0);
  }
});

test('edited, deleted, mismatched or unauthorized live requests spend nothing', async t => {
  for (const change of [
    f => { f.state.deleted = true; },
    f => { f.state.request.body += ' changed'; },
    f => { f.state.request.updated_at = '2026-11-09T19:00:00Z'; },
    f => { f.state.request.user.id = 42; },
    f => { f.state.request.issue_url += '6'; },
    f => { f.state.request.author_association = 'NONE'; },
    f => { f.state.permission = 'read'; },
  ]) {
    const f = await fixture(t); change(f); await f.run(prepare);
    assert.equal(f.state.outputs.ready, undefined);
    assert.equal(f.state.writes.length, 0);
    assert.equal(f.state.reads.some(([kind]) => kind === 'compare'), false);
  }
});

test('draft, closed, forked, missing and malformed PR heads are rejected', async t => {
  for (const change of [
    f => { f.state.pr.draft = true; },
    f => { f.state.pr.state = 'closed'; },
    f => { f.state.pr.head.repo.full_name = 'outsider/fork'; },
    f => { f.state.pr.head.repo = null; },
    f => { f.state.pr.base.repo.full_name = 'elsewhere/app'; },
    f => { f.state.pr.head.sha = 'branch; touch injected'; },
  ]) {
    const f = await fixture(t); change(f); await f.run(prepare);
    assert.equal(f.state.outputs.ready, undefined);
    assert.equal(f.state.writes.length, 0);
  }
});

test('duplicate requests never claim twice; human marker copies cannot block review', async t => {
  const f = await fixture(t);
  f.state.comments.push({ user: { login: 'outsider', type: 'User' },
    body: '<!-- claude-review-request:v1:5:7 -->\nforged' });
  await f.ready();
  delete f.state.outputs.ready;
  await f.run(prepare);
  assert.equal(f.state.outputs.ready, undefined);
  assert.equal(f.state.writes.filter(([kind]) => kind === 'create').length, 1);
  assert.ok(f.state.notices.some(message => message.includes('already claimed')));
});

test('incomplete, binary, excessive and truncated comparisons never produce a partial review', async t => {
  for (const change of [
    f => { f.state.pr.changed_files = 201; },
    f => { f.state.pr.changed_files = 2; },
    f => { delete f.state.comparison.files[0].patch; },
    f => { f.state.comparison.files[0].patch = '@@ -1,2 +1,2 @@\n-old\n+new'; },
    f => { f.state.comparison.files[0].additions = 2; },
    f => { f.state.pr.additions = 2; },
    f => { f.state.comparison.files[0].patch = '... truncated'; },
    f => { f.state.comparison.merge_base_commit.sha = ''; },
    f => { f.state.comparison.files[0].filename = 'x'.repeat(262144); },
  ]) {
    const f = await fixture(t); change(f); await f.run(prepare);
    assert.equal(f.state.outputs.ready, undefined);
    assert.equal(f.state.writes.length, 0);
  }
});

test('valid multi-hunk cumulative patches and no-newline markers remain complete', async t => {
  const f = await fixture(t);
  f.state.comparison.files[0].patch = '@@ -1 +1 @@\n-old\n+new\n@@ -8,2 +8,2 @@\n same\n-last\n+next\n\\ No newline at end of file';
  f.state.comparison.files[0].additions = f.state.pr.additions = 2;
  f.state.comparison.files[0].deletions = f.state.pr.deletions = 2;
  await f.ready();
});

test('changes after capture suppress provider invocation and stale publication', async t => {
  for (const change of [
    f => { f.state.pr.head.sha = 'd'.repeat(40); },
    f => { f.state.pr.base.sha = 'e'.repeat(40); },
    f => { f.state.pr.head.repo.full_name = 'outsider/fork'; },
    f => { f.state.pr.state = 'closed'; },
    f => { f.state.pr.draft = true; },
    f => { f.state.request.body += ' edited'; },
    f => { f.state.permission = 'triage'; },
    f => { f.state.deleted = true; },
  ]) {
    const f = await fixture(t); await f.ready(); change(f);
    await f.run(confirm);
    assert.equal(f.state.outputs.invoke, undefined);
    await f.result();
    await f.run(publish);
    assert.ok(f.state.writes.at(-1)[1].body.includes('No review result was published.'));
    assert.ok(!f.state.writes.at(-1)[1].body.includes('Synthetic finding.'));
  }
});

test('provider failure and invalid output cannot appear as successful review', async t => {
  for (const value of [
    { type: 'result', subtype: 'error', is_error: true, result: 'provider details' },
    { type: 'result', subtype: 'success', is_error: false, result: '' },
    { type: 'result', subtype: 'success', is_error: false, result: 'x'.repeat(50001) },
    { type: 'result', subtype: 'success', is_error: false, result: 'x'.repeat(140000) },
  ]) {
    const f = await fixture(t); await f.ready(); await f.result(value); await f.run(publish);
    assert.equal(f.state.failures.length, 1);
    assert.ok(!f.state.writes.at(-1)[1].body.includes('provider details'));
    assert.ok(f.state.writes.at(-1)[1].body.includes('did not complete'));
  }
  const f = await fixture(t); await f.ready(); f.env.MODEL_OUTCOME = 'failure'; await f.run(publish);
  assert.ok(f.state.writes.at(-1)[1].body.includes('did not complete'));
});

test('hostile comment/path/patch content stays data; model gets no inherited credentials or tools', async t => {
  const f = await fixture(t);
  const attack = '\$(touch SHOULD_NOT_EXIST) `touch SHOULD_NOT_EXIST` ${{ secrets.OTHER }}';
  f.context.payload.comment.body += ' ' + attack;
  f.state.request.body = f.context.payload.comment.body;
  f.state.comparison.files[0].filename = attack;
  f.state.comparison.files[0].patch = '@@ -1 +1 @@\n-old\n+' + attack;
  await f.ready();
  const directory = f.env.REVIEW_DIRECTORY;
  const stub = path.join(directory, 'tooling/node_modules/.bin');
  await fsp.mkdir(stub, { recursive: true });
  await fsp.writeFile(path.join(stub, 'claude'), `#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
assert.equal(process.env.GH_TOKEN, undefined);
assert.equal(process.env.GITHUB_TOKEN, undefined);
assert.equal(process.env.HOST_SECRET, undefined);
assert.equal(process.env.REVIEW_OAUTH_TOKEN, undefined);
assert.equal(process.env.CLAUDE_CODE_OAUTH_TOKEN, 'dummy-oauth');
assert.equal(fs.readdirSync(process.cwd()).length, 0);
const args = process.argv.slice(2);
for (const flag of ['--strict-mcp-config', '--disable-slash-commands', '--no-session-persistence']) assert.ok(args.includes(flag));
assert.equal(args[args.indexOf('--tools') + 1], '');
assert.equal(args[args.indexOf('--setting-sources') + 1], '');
assert.equal(args[args.indexOf('--mcp-config') + 1], '{"mcpServers":{}}');
assert.equal(args[args.indexOf('--settings') + 1], '{"disableAllHooks":true}');
const prompt = fs.readFileSync(0, 'utf8');
assert.ok(prompt.includes('SHOULD_NOT_EXIST'));
console.log(JSON.stringify({type:'result',subtype:'success',is_error:false,result:'Synthetic only.'}));
`, { mode: 0o700 });
  const output = spawnSync('/bin/bash', ['-c', model], { cwd: f.scratch,
    env: { PATH: process.env.PATH, REVIEW_DIRECTORY: directory, REVIEW_OAUTH_TOKEN: 'dummy-oauth',
      GH_TOKEN: 'dummy-github', GITHUB_TOKEN: 'dummy-github', HOST_SECRET: 'dummy-host' },
    encoding: 'utf8', timeout: 10000 });
  assert.equal(output.status, 0, output.stderr + '\n' + await fsp.readFile(path.join(directory, 'model-error.txt'), 'utf8'));
  assert.equal(fs.existsSync(path.join(directory, 'empty', 'SHOULD_NOT_EXIST')), false);
  assert.equal(fs.existsSync(path.join(f.scratch, 'SHOULD_NOT_EXIST')), false);
  f.env.MODEL_OUTCOME = 'success'; await f.run(publish);
  assert.ok(f.state.writes.at(-1)[1].body.includes('Synthetic only.'));
});

test('workflow has no checkout, arbitrary comment interpolation, broad secrets, or dispatch route', () => {
  assert.ok(!workflow.includes('actions/checkout'));
  assert.ok(!workflow.includes('secrets: inherit'));
  assert.ok(!workflow.includes('id-token: write'));
  assert.ok(!workflow.includes('workflow_dispatch:'));
  assert.ok(!workflow.includes('${{ github.event.comment.body }}'));
  assert.ok(workflow.includes('cancel-in-progress: false'));
  assert.ok(workflow.includes('permissions: {}'));
  assert.ok(!workflow.includes('plugin_marketplaces:'));
});
