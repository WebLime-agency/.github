#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ $(actionlint -version 2>&1 | head -n 1) == 1.7.7 ]]
[[ $(shellcheck --version) == *"version: 0.11.0"* ]]

# Check workflow syntax separately from linting standalone shell scripts.
actionlint -config-file .github/actionlint.yaml -shellcheck= .github/workflows/*.yml
mapfile -d '' shell_scripts < <(find tests scripts -type f -name '*.sh' -print0 | sort -z)
shellcheck "${shell_scripts[@]}"

passed=0
skipped=0
failed=0
for test in tests/*.sh; do
  echo "::group::$test"
  status=0
  bash "$test" || status=$?
  echo "::endgroup::"
  case "$status" in
    0) echo "PASS: $test"; passed=$((passed + 1)) ;;
    77)
      echo "::warning::SKIP: $test (exit 77; optional artifact unavailable)"
      skipped=$((skipped + 1))
      ;;
    *)
      echo "::error::FAIL: $test (exit $status)"
      failed=$((failed + 1))
      ;;
  esac
done
summary="Offline tests: $passed passed, $skipped skipped, $failed failed"
echo "$summary"
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  echo "$summary" >> "$GITHUB_STEP_SUMMARY"
fi
[[ $failed -eq 0 ]]
