#!/usr/bin/env bash
#
# Create (or update) the release label contract in a repository.
#
# GitHub has no org-level label inheritance, so every repo that uses the
# production-anchored release workflow needs these seven labels created
# locally. Running this twice is a no-op beyond updating colour/description.
#
#   scripts/sync-release-labels.sh WebLime-agency/limey-web-app
#   scripts/sync-release-labels.sh --dry-run WebLime-agency/tailmars-web-app
#
set -euo pipefail

DRY_RUN=false
REPO=""

usage() {
  cat >&2 <<'USAGE'
Usage: sync-release-labels.sh [--dry-run] <owner/repo>

Creates the seven release/* labels used by the production-anchored release
workflow. Safe to re-run.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [ -n "${REPO}" ]; then
        echo "Unexpected argument: $1" >&2
        usage
        exit 2
      fi
      REPO="$1"
      shift
      ;;
  esac
done

if [ -z "${REPO}" ]; then
  echo "A target repository is required." >&2
  usage
  exit 2
fi

# name|colour|description
LABELS=(
  'release/new|0e8a16|User-facing: something new. Appears in release notes and marketing input.'
  'release/improved|1d76db|User-facing: an existing thing works better. Appears in release notes and marketing input.'
  'release/fixed|b60205|User-facing: a bug fix. Appears in release notes and marketing input.'
  'release/api|5319e7|Integrations and API surface. Appears in release notes and marketing input.'
  'release/security|d93f0b|Security and reliability. In the release notes, NOT in the machine-readable payload. Titles must never be exploitable.'
  'release/internal|6a737d|Internal only. Collapsed in the release notes, excluded from marketing input.'
  'release/skip|c5def5|Excluded from release notes entirely.'
)

echo "Syncing ${#LABELS[@]} release labels to ${REPO}"

for ENTRY in "${LABELS[@]}"; do
  IFS='|' read -r NAME COLOUR DESCRIPTION <<< "${ENTRY}"

  if [ "${DRY_RUN}" = true ]; then
    echo "  [dry-run] ${NAME}"
    continue
  fi

  # --force updates an existing label rather than failing, which is what makes
  # this idempotent.
  gh label create "${NAME}" \
    --repo "${REPO}" \
    --color "${COLOUR}" \
    --description "${DESCRIPTION}" \
    --force

  echo "  ok ${NAME}"
done

echo "Done."
