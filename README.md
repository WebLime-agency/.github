# .github

Org defaults for WebLime: reusable workflows and composite actions that repos call rather than copy.

Everything here is consumed by a thin per-repo caller. The logic lives once, in this repo.

## Reusable workflows

| Workflow | Purpose |
| --- | --- |
| `release-anchored-reusable.yml` | Production-anchored GitHub Releases — **[docs](docs/release-anchored.md)** |
| `claude-review-reusable.yml` | Claude PR review |
| `claude-mention-reusable.yml` | `@claude` mention handling |
| `codex-review-reusable.yml` | `@codex review` handling |
| `vercel-production-reusable.yml` | Vercel production deploy |
| `vercel-preview-build-reusable.yml` | Vercel preview build |
| `vercel-preview-deploy-reusable.yml` | Vercel preview deploy |

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

**This repo has no PR CI.** Every workflow here is `workflow_call` only, so nothing runs the tests automatically. Run them by hand before merging:

```bash
tests/release-anchored-workflow.sh     # requires jq
tests/codex-review-workflow.sh
tests/vercel-preview-spool.sh
```
