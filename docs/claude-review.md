# Explicit Claude review requests

The review reusable accepts only a newly created PR conversation comment containing
`@claude review` (case insensitive). It has no automatic PR or manual dispatch
route. Keep disabled workflows disabled until source changes are merged, checked,
and the owner explicitly authorizes release. Merging source does not authorize
enabling workflows.

The requester must be a human with OWNER, MEMBER, or COLLABORATOR association
and current repository write, maintain, or admin permission. Ordinary issues,
inline review comments, edits, deleted comments, bots, reruns, closed/draft PRs,
and forks cannot invoke the review. An edited request needs a new comment.
Extra comment text is never treated as model instructions.

## Revision and credential boundary

Preparation captures the exact base and head SHAs and obtains cumulative patch
data through an immutable comparison. It verifies file and line counts against
the PR metadata, including complete hunk lengths. Binary/missing patches,
more than 200 files, and prompts exceeding 256 KiB are declined rather than
partially reviewed. Neither PR files nor their instructions, hooks, configuration,
dependencies, or scripts are checked out or executed.

The model runs on an ephemeral hosted runner in an empty directory with an
isolated home and an allowlisted environment. Its only credential is the existing
subscription OAuth token. It receives a fixed prompt with snapshot data, with
all tools, MCP servers, hooks, project settings, plugins, and slash commands
disabled. The CLI is pinned to 2.1.321; Node is pinned to 24.18.0.
This is a bounded single-turn snapshot review, replacing the tool-using plugin.
It does not run tests or inspect unchanged files.

The model cannot post comments. Deterministic workflow code checks the request,
current permission, PR state, repository identity, and captured base/head again
before invocation and publication. Output is bounded and parsed as data. Provider
logs are not posted. A result is always labeled with its reviewed SHAs; if the
request or revision has changed at the final check, findings are withheld.
A subsequent push can still occur after that check, so the SHA label remains
authoritative rather than claiming the comment always describes the newest head.

## Duplicate delivery and failures

A serialized, authenticated bot comment claims each request ID before any provider
invocation. Subsequent deliveries find that marker and skip; rerun attempts also
skip at the job gate. Human copies of the marker are ignored. A failed or interrupted
run consumes its request: create a new comment for a deliberate retry. The
workflow never automatically retries a failed review request. Do not remove claim
comments when preserving the deduplication history matters.

The claim comment is updated with either the bounded review result or a fixed
failure/stale status. No model output is published as a successful review unless
the CLI reports a successful result. Unsupported snapshots are declined before
the claim, with a workflow notice.

## Compatibility and adoption

Legacy callers that still fire on `pull_request` reach a job-level false condition.
The whole review job is skipped before runner allocation or any step, yielding
GitHub's normal skipped/successful-check behavior rather than a failure or paid
review. Their caller files and enabled/disabled states are unchanged by this
source change. Those callers must separately adopt the comment trigger before
explicit review requests can reach this reusable.

The existing generic mention responder remains available for other `@claude`
requests. It excludes PR conversation comments containing `@claude review` so an
explicit review does not start both workflows. Existing inline-review and
ordinary-issue mention behavior is preserved.

Callers should use `issue_comment: { types: [created] }`, a commit SHA pin, explicit
OAuth secret forwarding, and the reusable's narrow permissions. Update pins only
through reviewed PRs. No secret, token, repository setting, or workflow activation
change is part of adoption.

## Offline verification

`bash tests/claude-review-workflow.sh` exercises the actual workflow scripts with
synthetic events, GitHub API responses, and a model stub. It never invokes a
provider or activates a workflow. The suite covers authorization, legacy
no-ops, edits/deletions, forks, duplicate requests, patch completeness, revision
movement, output failures, mention routing, and hostile input/credential isolation.
