#!/usr/bin/env bash
#
# Claude PR review — org-wide rollout for WebLime-agency (Route B: reusable workflow + API key).
#
# Subcommands:
#   setup     Create/update WebLime-agency/.github with the reusable workflow(s).
#   enroll    Add the per-repo caller workflow to repos (opens one PR per repo).
#
# SAFETY: every run is a DRY RUN that only prints intended actions.
#         Add --apply to actually mutate GitHub.
#
# Examples:
#   ./rollout.sh setup                                  # preview setup
#   ./rollout.sh setup --apply                          # create/update the .github repo
#   ./rollout.sh enroll --all                           # preview enrollment for every org repo
#   ./rollout.sh enroll --all --apply                   # open enrollment PRs across the org
#   ./rollout.sh enroll --repo WebLime-agency/limey-web-app --apply
#   ./rollout.sh enroll --all --with-mention --apply    # also add the @claude responder
#
set -euo pipefail

ORG="WebLime-agency"
DOTGH_REPO="${ORG}/.github"
BRANCH="add-claude-review"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REUSABLE_DIR="${HERE}/reusable"
CALLER_DIR="${HERE}/caller"

APPLY=0
WITH_MENTION=0
ALL=0
DOTGH_DEF="main"   # resolved to the .github repo's real default branch during enroll
declare -a REPOS=()

die()  { echo "error: $*" >&2; exit 1; }
note() { echo "  $*"; }

[[ $# -ge 1 ]] || die "usage: $0 {setup|enroll} [--apply] [--all] [--repo OWNER/NAME]... [--with-mention]"
CMD="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)        APPLY=1 ;;
    --all)          ALL=1 ;;
    --with-mention) WITH_MENTION=1 ;;
    --repo)         shift; [[ $# -gt 0 ]] || die "--repo needs OWNER/NAME"; REPOS+=("$1") ;;
    *)              die "unknown arg: $1" ;;
  esac
  shift
done

command -v gh >/dev/null || die "gh CLI not found"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"

run() {
  if [[ $APPLY -eq 1 ]]; then
    "$@"
  else
    # Mask base64 blobs so the dry-run plan stays readable.
    echo "DRY-RUN> $(printf '%s ' "$@" | sed -E 's/content=[A-Za-z0-9+/=]+/content=<base64>/g')"
  fi
}
b64() { base64 -w0 "$1"; }

# Default branch of the org .github repo (where the reusable workflows live).
# Falls back to main when the repo doesn't exist yet (e.g. dry-run before setup).
dotgh_default() { gh repo view "$DOTGH_REPO" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || echo "main"; }

# Emit a temp copy of a caller file with the reusable-workflow ref pinned to the
# .github repo's real default branch (DOTGH_DEF), not a hardcoded @main.
templated() {
  local src="$1" tmp; tmp="$(mktemp)"
  sed -E "s#-reusable\.yml@main#-reusable.yml@${DOTGH_DEF}#" "$src" > "$tmp"
  echo "$tmp"
}

# Create or update a file on a branch (handles the update-needs-sha case).
put_file() {
  local repo="$1" dest="$2" local_file="$3" branch="$4" msg="$5" sha=""
  # Treat as an update only when the GET truly succeeds; on 404 gh prints the
  # error body to stdout, so key off exit status rather than captured text.
  if ! sha="$(gh api "repos/${repo}/contents/${dest}?ref=${branch}" --jq '.sha' 2>/dev/null)"; then sha=""; fi
  local args=(-X PUT "repos/${repo}/contents/${dest}"
              -f "message=${msg}" -f "content=$(b64 "$local_file")" -f "branch=${branch}")
  [[ -n "$sha" ]] && args+=(-f "sha=${sha}")
  run gh api "${args[@]}"
}

setup() {
  echo "== setup ${DOTGH_REPO} =="
  if gh repo view "$DOTGH_REPO" >/dev/null 2>&1; then
    note "repo exists"
  else
    note "repo missing -> create (private, with README)"
    run gh repo create "$DOTGH_REPO" --private --add-readme \
      --description "Org defaults: Claude PR review reusable workflows"
  fi
  # A private .github repo won't expose its reusable workflows to other org
  # repos unless Actions access is opened to the organization.
  note "allow org repos to call this repo's reusable workflows"
  run gh api -X PUT "repos/${DOTGH_REPO}/actions/permissions/access" -f access_level=organization
  local def; def="$(dotgh_default)"
  note "writing reusable workflows to ${DOTGH_REPO}@${def}"
  put_file "$DOTGH_REPO" ".github/workflows/claude-review-reusable.yml" \
    "${REUSABLE_DIR}/claude-review-reusable.yml" "$def" "Add Claude review reusable workflow"
  put_file "$DOTGH_REPO" ".github/workflows/claude-mention-reusable.yml" \
    "${REUSABLE_DIR}/claude-mention-reusable.yml" "$def" "Add Claude @mention reusable workflow"
  echo "done."
}

repo_list() {
  if [[ ${#REPOS[@]} -gt 0 ]]; then
    printf '%s\n' "${REPOS[@]}"
  elif [[ $ALL -eq 1 ]]; then
    gh repo list "$ORG" --source --no-archived --limit 500 \
      --json nameWithOwner -q '.[].nameWithOwner' | grep -vx "${DOTGH_REPO}" || true
  else
    die "specify --all or one/more --repo OWNER/NAME"
  fi
}

enroll_one() {
  local repo="$1" default base_sha
  echo "== enroll ${repo} =="
  local existing
  for existing in claude-review.yml claude-code-review.yml; do
    if gh api "repos/${repo}/contents/.github/workflows/${existing}" >/dev/null 2>&1; then
      note "already has ${existing} — skip"; return 0
    fi
  done
  if gh pr list --repo "$repo" --head "$BRANCH" --state open --json number -q '.[].number' 2>/dev/null | grep -q .; then
    note "enrollment PR already open — skip"; return 0
  fi
  default="$(gh repo view "$repo" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || true)"
  [[ -n "$default" ]] || { note "no default branch — skip"; return 0; }
  base_sha="$(gh api "repos/${repo}/git/ref/heads/${default}" --jq '.object.sha')"
  note "branch ${BRANCH} from ${default}"
  run gh api "repos/${repo}/git/refs" -f "ref=refs/heads/${BRANCH}" -f "sha=${base_sha}" || true
  local f; f="$(templated "${CALLER_DIR}/claude-review.yml")"
  put_file "$repo" ".github/workflows/claude-review.yml" \
    "$f" "$BRANCH" "Add Claude PR review (calls org reusable workflow)"
  rm -f "$f"
  if [[ $WITH_MENTION -eq 1 ]]; then
    f="$(templated "${CALLER_DIR}/claude.yml")"
    put_file "$repo" ".github/workflows/claude.yml" \
      "$f" "$BRANCH" "Add Claude @mention responder"
    rm -f "$f"
  fi
  run gh pr create --repo "$repo" --base "$default" --head "$BRANCH" \
    --title "Add Claude PR review" \
    --body "Enables automated Claude review on PRs via the org reusable workflow (${DOTGH_REPO}). Requires the CLAUDE_CODE_OAUTH_TOKEN org secret." || true
}

case "$CMD" in
  setup)  setup ;;
  enroll)
    DOTGH_DEF="$(dotgh_default)"
    while read -r r; do [[ -n "$r" ]] && enroll_one "$r"; done < <(repo_list) ;;
  *)      die "unknown command: $CMD" ;;
esac

[[ $APPLY -eq 1 ]] || echo $'\n(dry run — re-run with --apply to execute)'
