# .github

Org defaults for WebLime: reusable workflows and composite actions that repos call rather than copy.

Everything here is consumed by a thin per-repo caller. The logic lives once, in this repo.

Run `bash scripts/ci.sh` locally with actionlint 1.7.7 and ShellCheck 0.11.0
on PATH (plus Bash, Git, jq, Perl, Python 3 and GNU coreutils). CI installs
checksum-verified releases; the same versions are enforced locally. Actionlint
checks all workflow YAML with its embedded-shell lint integration disabled;
ShellCheck checks all shell scripts under `tests/` and `scripts/` separately.
The actionlint config recognizes an existing custom runner label. Intentional
fixture-source patterns have line-specific ShellCheck directives with reasons.

The `ci` job runs on every PR and push to `main`, with read-only contents
permission on a GitHub-hosted runner. Tests use synthetic fixtures and stubs,
including a local Unix socket server; they need no secrets or external services.
The socket suite requires root-owned `/usr/bin/python3` and `/`, as on the
hosted runner; an ownership-remapping sandbox cannot run that suite unchanged.
Only tool installation and checkout access the network. Every `tests/*.sh` runs:
exit 0 is PASS, exit 77 is an explicit SKIP warning, and any other exit fails
CI. Totals are printed and added to the job summary, so skips remain visible.

## Reusable workflows

| Workflow | Purpose |
| --- | --- |
| `release-anchored-reusable.yml` | Production-anchored GitHub Releases — **[docs](docs/release-anchored.md)** |
| `claude-review-reusable.yml` | Explicit PR comment review requests - [contract](docs/claude-review.md) |
| `claude-mention-reusable.yml` | `@claude` mention handling |
| `codex-review-reusable.yml` | `@codex review` handling |
| `vercel-production-reusable.yml` | Vercel production deploy |
| `vercel-preview-build-reusable.yml` | Vercel preview build |
| `vercel-preview-deploy-reusable.yml` | Notify-only shim to the preview broker. Success confirms pointer delivery, not a deployed preview. The broker owns deployment and sticky comments; its live operational state is not verified here. |

## Composite actions

| Action | Purpose |
| --- | --- |
| `.github/actions/supabase-migrate` | Apply Supabase migrations |

## Other

| Path | Purpose |
| --- | --- |
| `release-drafter-base.yml` | Shared release-notes config, inherited via `_extends` ([docs](docs/release-anchored.md)) |
| `scripts/sync-release-labels.sh` | Creates the `release/*` label contract in a repo |
| `tests/` | Shell tests for the workflows here |

## Conventions

**Pin by commit SHA.** Callers of `release-anchored-reusable.yml` pin a commit, not `@main` — a merge here is otherwise live in every consumer immediately, with no review in the repo it affects. Bump pins in their own PR, linking the upstream change.

**Run the tests by hand before merging workflow changes.** The reusable workflows here are `workflow_call` only, so nothing inside a consumer repo executes a changed workflow until that consumer adopts it. Run the suite by hand as well as relying on the `ci` job above:

```bash
tests/release-anchored-workflow.sh     # requires jq
tests/codex-review-workflow.sh
tests/vercel-preview-spool.sh
```
