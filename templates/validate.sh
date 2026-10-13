#!/usr/bin/env bash
# Runs after Claude finishes, from the repo root; a non-zero exit blocks the PR. Replace this with
# the project's real builds and tests.
set -euo pipefail

echo "edit .claude-task/validate.sh to run this project's checks" >&2
exit 1
