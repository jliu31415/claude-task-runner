#!/usr/bin/env bash
# Runs a command until it succeeds, waiting between attempts with exponential backoff (capped at
# 5 minutes); for downloads that fail transiently (HTTP 5xx, resets). The command must be safe to
# rerun. Failures are logged as the label, which defaults to the whole command.
#   retry.sh [-n attempts] [-d first-delay-seconds] [-l label] [--] command [args...]
set -euo pipefail

usage() {
  echo "usage: retry.sh [-n attempts] [-d first-delay-seconds] [-l label] [--] command [args...]" >&2
  exit 2
}

attempts=3
delay=30
max_delay=300
label=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-d|-l)
      [[ $# -ge 2 ]] || { echo "retry: $1 needs a value" >&2; usage; }
      case "$1" in
        -n) attempts=$2 ;;
        -d) delay=$2 ;;
        -l) label=$2 ;;
      esac
      shift 2 ;;
    --) shift; break ;;
    -*) echo "retry: unknown option $1" >&2; usage ;;
    *) break ;;
  esac
done
[[ $attempts =~ ^[1-9][0-9]*$ ]] || { echo "retry: attempts must be a positive number: $attempts" >&2; exit 2; }
[[ $delay =~ ^(0|[1-9][0-9]*)$ ]] || { echo "retry: delay must be a whole number of seconds: $delay" >&2; exit 2; }
[[ $# -gt 0 ]] || usage
label=${label:-$*}
(( delay <= max_delay )) || delay=$max_delay

for ((i = 1; ; i++)); do
  status=0
  "$@" || status=$?
  [[ $status -ne 0 ]] || exit 0
  if [[ $i -ge $attempts ]]; then
    echo "retry: $label failed (exit $status) after $i attempt(s)" >&2
    exit "$status"
  fi
  echo "retry: $label failed (exit $status); attempt $((i + 1)) of $attempts in ${delay}s" >&2
  sleep "$delay"
  delay=$((delay * 2 > max_delay ? max_delay : delay * 2))
done
