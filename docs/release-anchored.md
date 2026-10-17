# Production-anchored releases

Turns a production deploy into a GitHub Release, automatically, anchored to a commit that is **provably live**.

A release is only ever produced for a commit that is the current tip of the production branch **and** for which every workflow you name has concluded `success` for that exact SHA. Work that exists only on `dev` or staging cannot appear in a release. If one deploy workflow is still running, the run is a no-op rather than a failure — the other workflow's completion re-triggers it.

Release notes come from [Release Drafter](https://github.com/release-drafter/release-drafter), grouped by one `release/*` label per pull request. The workflow itself owns tag and release creation; see *Why the workflow owns release create/update* in the workflow header for that reasoning.

---

## Adding it to a repo

Three things: labels, a config, a caller.

### 1. Labels

```bash
scripts/sync-release-labels.sh WebLime-agency/<repo>
```

Idempotent, so re-run it freely. Add them early, even before the rest lands — labels accumulate on merged PRs, so the first release is not empty.

### 2. `.github/release-drafter.yml`

Inherit the shared config; keep only what is genuinely repo-local.

```yaml
_extends:
  from: WebLime-agency/.github:/release-drafter-base.yml@<commit sha>
  strategy:
    categories: append
    autolabeler: append
    replacers: append

replacers:
  - search: '/\bTICKET-\d+\b/g'
    replace: ''

autolabeler:
  - label: 'release/api'
    files: ['src/routes/api/**']
```

Two things here are easy to get wrong and are covered under [Gotchas](#gotchas): the **leading slash** on the `from:` path, and declaring a merge strategy for **every** list key.

### 3. `.github/workflows/release.yml`

```yaml
name: Release

on:
  workflow_dispatch:
    inputs:
      sha:
        description: "Production SHA to release. Blank uses the current main tip."
        required: false
        type: string
        default: ""
      mode:
        required: true
        type: choice
        options: [dry-run, draft, publish]
        default: dry-run

jobs:
  release:
    name: Production release
    permissions:
      contents: write
      actions: read          # the gate lists deploy runs; without this it 403s
      pull-requests: read
      issues: write
    uses: WebLime-agency/.github/.github/workflows/release-anchored-reusable.yml@<commit sha>
    with:
      required_deploy_workflows: "vercel-production.yml"
      sha: ${{ inputs.sha }}
      mode: ${{ inputs.mode || 'dry-run' }}
    secrets: inherit
```

Add the automatic trigger **only after** the dispatch path has produced a release you are happy with:

```yaml
  workflow_run:
    workflows: ['Deploy', 'Vercel Production Deploy']
    branches: [main]
    types: [completed]
```

`inputs` is empty for a non-dispatch trigger, so `mode: ${{ inputs.mode || 'dry-run' }}` means adding that trigger forces you to choose `publish` deliberately.

### 4. Autolabeler (optional but expected)

```yaml
name: Release Autolabeler

on:
  pull_request_target:
    types: [opened, reopened, synchronize]

permissions:
  contents: read
  pull-requests: write

jobs:
  autolabel:
    runs-on: [self-hosted, Linux, X64, weblime-ci]
    steps:
      - uses: release-drafter/release-drafter/autolabeler@<commit sha>
        with:
          config-name: release-drafter.yml
          token: ${{ secrets.GITHUB_TOKEN }}
```

`pull_request_target` is required to label pull requests from forks and is safe here because the job never checks out or executes PR code — it reads only the branch name, title and changed paths.

---

## Inputs

| Input | Required | Default | Notes |
| --- | --- | --- | --- |
| `required_deploy_workflows` | yes | — | Comma-separated workflow **filenames**. Every one must have concluded `success` for the same SHA. The gate is only as good as this list. |
| `sha` | no | `""` | Explicit SHA. Blank resolves from the triggering event, then the production branch tip. |
| `mode` | no | `publish` | `dry-run`, `draft` or `publish`. Callers should default to `dry-run`. |
| `tag_prefix` | no | `v` | |
| `production_branch` | no | `main` | |
| `config_name` | no | `release-drafter.yml` | Relative to `.github/`. |
| `max_commits` | no | `300` | Refuses a larger range rather than risk truncated notes. |
| `runner` | no | self-hosted `weblime-ci` | JSON array for `runs-on`. `'["ubuntu-latest"]'` runs on an ephemeral hosted runner, which removes the shared-runner threat model at the cost of Actions minutes. |

### Picking `required_deploy_workflows`

List the workflows that must have **succeeded for that exact SHA** before the commit counts as deployed. Only workflows that trigger on push to the production branch are candidates — anything that runs earlier has already happened by then.

Repos differ, so do not copy another repo's list. Check what actually runs on push to `main`:

```bash
gh api "repos/WebLime-agency/<repo>/actions/workflows" --jq '.workflows[].path'
```

Migrations applied *during* promotion (before the branch moves) do not belong in this list — by the time the commit is on the production branch, they are already applied.

---

## The label contract

Exactly one `release/*` label per pull request, and a title a non-engineer can read.

| Label | Section | Reaches marketing |
| --- | --- | --- |
| `release/new` | ✨ New | yes |
| `release/improved` | 💪 Improved | yes |
| `release/fixed` | 🐛 Fixed | yes |
| `release/api` | 🔌 Integrations & API | yes |
| `release/security` | 🔒 Security & reliability | prose body only, **not** the payload |
| `release/internal` | 🧱 Internal, collapsed | no |
| `release/skip` | excluded entirely | no |

For the four customer-facing labels the **PR title is published verbatim** and feeds downstream drafting, so write it for someone who does not work here. A `release/security` title must never be exploitable.

The shared config auto-labels from branch prefixes — `fix/`, `bug/`, `hotfix/` → fixed; `chore/`, `ci/`, `refactor/`, `deps/`, `test/` → internal; `docs/` → skip; a security-titled PR → security. **`feat/*` deliberately gets nothing**: a feature branch may be new, improved or API work, and guessing would file it in the wrong section silently.

### `release.json`

Each release carries a `release.json` asset holding **only** the four customer-facing categories. Downstream consumers read that, not the prose body, so internal and security lines cannot leak through a consumer bug. The guarantee is structural rather than a convention.

---

## Modes

| Mode | Effect |
| --- | --- |
| `dry-run` | Renders the notes and `release.json` into the job summary. No tag, no release, no writes. |
| `draft` | Creates the tag and an unpublished release. |
| `publish` | Creates the tag and a published release, with `release.json` attached. |

Tags are annotated, unpadded CalVer (`v2026.9.24`), created through the API, and **never moved** — including after a rollback, because the tag records what was actually live.

---

## First release

1. Create the labels, and backfill them onto PRs merged since your chosen baseline.
2. Tag the current production tip `v0.0.0`, annotated, and **publish** a release on it with `latest: false`. Release Drafter needs a *published* previous release to bound the range. Use a semver-coercible tag.
3. Dispatch with `mode: dry-run`. Read the job summary: gate verdict, range, PR set, rendered body, `release.json`.
4. Review as a human — is any security line exploitable? Does anything internal read as customer-facing?
5. Dispatch with `mode: draft`, confirm the tag lands on the expected SHA.
6. Publish by hand.
7. Only then add the `workflow_run` trigger.

A baseline on the current tip means the first dry run correctly reports **nothing to release** — everything up to it is deliberately not itemised, so the first real release covers what ships next.

---

## Testing before merge

Neither the autolabeler nor the release workflow can run from a pull request branch by default, which makes both easy to merge broken.

**The autolabeler** uses `pull_request_target`, which runs the workflow file from the **base** branch — so it cannot execute until it is already on the default branch. Test it from a scratch branch with the trigger temporarily switched to `pull_request`, which runs from the **head** branch; the action accepts either event. Name the scratch branch with a prefix an **inherited** rule matches, such as `chore/`, and a green run proves the whole chain at once:

```
_extends strategy: appended 1 'autolabeler' item(s) onto 4 inherited item(s)
Config was fetched from 2 different contexts.
Found label for branch: 'release/internal'
```

**The release workflow** uses `workflow_dispatch`, which only fires from the default branch. Add a temporary `push` trigger scoped to a scratch branch.

In both cases, use a scratch branch off the PR branch rather than the PR branch itself, so the pull request under review is never touched and its reviews survive.

---

## Gotchas

Each of these cost real time. None is caught by any test in this repo, because they are all cross-repo or event-shaped.

**`_extends` needs a leading slash for a root-level file.** `normalizeFilepath` prepends `.github/` to any *relative* path in a cross-repo `_extends`, so `…:release-drafter-base.yml` resolves to `.github/release-drafter-base.yml` and 404s. `…:/release-drafter-base.yml` is repo-root relative. The failure appears only in the autolabeler's run log.

**Declare a merge strategy for every local list key.** `_extends` merges shallowly: an extending file's value **replaces** the inherited one. Declaring only `categories: append` means a local `autolabeler` wipes every inherited branch rule, so most PRs get no label — with no error anywhere.

**The autolabeler is a sub-action.** `release-drafter/release-drafter/autolabeler@…`, not the root action. From v7 the root action is the *drafter* and has no `disable-releaser` input, so pointing at it drafts a release on every pull request and applies no labels.

**Pin commit SHAs, never `@main`.** A merge here would otherwise be live in every consumer immediately, with no review in the repo it affects. This repo has no PR CI, so such a merge is also machine-unverified. Bump pins in their own PR, linking the upstream change.

**`actions: read` is required.** The gate lists deploy workflow run conclusions. Without it every run dies with HTTP 403 before it can tell a pending deploy from a successful one.

**Unpadded CalVer.** Release Drafter excludes releases whose tags fail semver coercion, and `09` is an invalid segment. A padded scheme makes previous releases invisible, so every run behaves like the first — silently.

---

## Operating it

The per-repo runbook — what to do when no release appears, when notes look truncated, when a PR landed in the wrong category, after a rollback — lives in each repo's `CLAUDE.md`, next to the rest of its CI documentation.

## Tests

```bash
tests/release-anchored-workflow.sh     # requires jq
```

Extracts each `run:` block from the workflow and executes it against stubbed tooling and a throwaway git repository. Covers the gate's verdicts, the range guards, the tag guard, the verify comparison, dry-run write suppression, and the shared-runner hardening — a planted hook, an fsmonitor command and a fake binary on `PATH` must none of them run.

It cannot cover `_extends` resolution, a real `workflow_run` payload, or Release Drafter's actual output. Those need a dry run from a caller repo.
