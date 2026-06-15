# Claude PR review — org-wide rollout (WebLime-agency)

Route B: one reusable workflow in the org `.github` repo, a tiny caller in each
repo. Authenticated with the **subscription OAuth token** (`CLAUDE_CODE_OAUTH_TOKEN`)
to start — zero marginal cost, but all reviews share one Claude account's rate
limits. If whole-team volume hits the wall, switch one line in the reusable
workflow to `ANTHROPIC_API_KEY` (pay-as-you-go) — callers never change.

## Layout

```
reusable/claude-review-reusable.yml    -> WebLime-agency/.github  (the actual review logic)
reusable/claude-mention-reusable.yml   -> WebLime-agency/.github  (optional @claude responder)
caller/claude-review.yml               -> every repo              (6-line stub, triggers + secrets: inherit)
caller/claude.yml                      -> every repo (optional)   (@claude responder caller)
rollout.sh                             -> setup + enroll, dry-run by default
```

## One-time: org secret

The reusable workflow reads `CLAUDE_CODE_OAUTH_TOKEN`. Generate it once from a
Claude Code CLI logged into the subscription you want reviews to bill against:

```bash
claude setup-token        # prints a long-lived OAuth token
```

Prefer a dedicated/service Claude account on the highest tier you have (e.g. Max
20x) so org reviews don't compete with anyone's interactive Claude Code usage.

Set it once at the org level:

- **UI (easiest):** GitHub → WebLime-agency → Settings → Secrets and variables →
  Actions → **New organization secret** → name `CLAUDE_CODE_OAUTH_TOKEN`, value =
  the token above, repository access = **All repositories**.
- **CLI:** needs `admin:org` scope (the current token only has `read:org`):
  ```bash
  gh auth refresh -h github.com -s admin:org
  gh secret set CLAUDE_CODE_OAUTH_TOKEN --org WebLime-agency --visibility all
  ```

## Steps

```bash
# 1. Preview, then create the org reusable workflows
./rollout.sh setup
./rollout.sh setup --apply

# 2. Preview, then enroll repos (opens one PR per repo; idempotent)
./rollout.sh enroll --all
./rollout.sh enroll --all --apply

#    …or a curated set:
./rollout.sh enroll --repo WebLime-agency/limey-web-app --repo WebLime-agency/nucleus --apply

#    …or also wire the @claude responder:
./rollout.sh enroll --all --with-mention --apply
```

Every run is a **dry run** until you add `--apply`.

## Verify

Open a test PR in an enrolled repo → the "Claude Code Review" check runs and Claude
comments. Edit `reusable/claude-review-reusable.yml` and re-run `setup --apply` to
change behavior everywhere at once — callers never change.

## Conserving subscription rate limits

All reviews share one account's limits, so the main lever is the caller trigger.
`caller/claude-review.yml` reviews on `opened, synchronize, ready_for_review,
reopened` (matches Nucleus — re-reviews on every push). Dropping `synchronize`
reviews once per PR (re-review on demand with `@claude`) and is the biggest
reduction in how fast you approach the wall.

## Switching to pay-as-you-go later

If you outgrow the subscription limits, in `reusable/claude-review-reusable.yml`
change `claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}` to
`anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}`, add that org secret (set a
monthly spend cap in the Console), and re-run `./rollout.sh setup --apply`. No repo
or caller changes needed.

## Migrating Nucleus (optional)

Nucleus already runs standalone `claude-code-review.yml` / `claude.yml` on its own
`CLAUDE_CODE_OAUTH_TOKEN`. To fold it into this model, replace those two files with
the callers here so it uses the org secret and the shared reusable workflow. Fine to
leave as-is.
