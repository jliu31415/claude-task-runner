#!/usr/bin/env bash
# Runs on a fresh ubuntu-24.04 runner before Claude starts, from the repo root. Install the
# toolchain and dependencies that validate.sh and Claude's own test runs need, writing only to
# gitignored paths. The SETUP_GH_TOKEN secret, if set, is available as GH_TOKEN. Delete this file if
# the project needs no setup.
set -euo pipefail
