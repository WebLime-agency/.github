# .github
Org defaults: Claude PR review reusable workflows

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
