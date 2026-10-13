# Claude task runner helpers, shared by the local CLI (bin/submit-task) and the CI steps (ci.sh).
# Everything a consuming repo provides lives in its .claude-task/ folder. Sourced; callers own
# `set -euo pipefail`.

CT_SNAPSHOT_PREFIX=agent-snapshots/
CT_DIR=.claude-task
CT_CONF_PATH=$CT_DIR/config
CT_TASKS_DIR=$CT_DIR/tasks
CT_SETUP_PATH=$CT_DIR/setup.sh
CT_VALIDATE_PATH=$CT_DIR/validate.sh
CT_WORKFLOW=claude-task.yml

# defaults for the optional .claude-task/config keys
CT_DEFAULT_BASE_BRANCH=main
CT_DEFAULT_RESULT_BRANCH_PREFIX=task-
CT_DEFAULT_CLAUDE_MAX_BUDGET_USD=10

ct_die() { echo "claude-task: $*" >&2; exit 1; }
ct_warn() { echo "claude-task: warning: $*" >&2; }

ct_valid_task_name() { [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$ ]]; }

# task IDs are <task name>-<6 hex>, so the name is recoverable and the ID can't smuggle anything else
ct_valid_task_id() {
  local id=$1 name=${2-} prefix
  [[ $id =~ ^([a-z0-9-]+)-[0-9a-f]{6}$ ]] || return 1
  prefix=${BASH_REMATCH[1]}
  ct_valid_task_name "$prefix" || return 1
  [[ -z $name || $prefix == "$name" ]]
}

ct_task_name_of() { echo "${1%-*}"; }

ct_sanitize_task_name() {
  local s
  s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//')"
  s="${s:0:40}"
  while [[ $s == *- ]]; do s="${s%-}"; done
  echo "$s"
}

ct_new_task_id() { echo "$1-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"; }

ct_valid_sha() { [[ $1 =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]]; }

# repo-relative, no `.`/`..`/`.git` segments, conservative charset so it's safe in refs, logs and
# workflow inputs
ct_valid_repo_path() {
  local p=$1 seg
  local -a segs
  [[ $p =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || return 1
  IFS=/ read -ra segs <<< "$p"
  for seg in "${segs[@]}"; do
    [[ $seg == . || $seg == .. || $seg == .git || $seg == -* ]] && return 1
  done
  return 0
}

ct_valid_prompt_path() { ct_valid_repo_path "$1" && [[ $1 == *.md ]]; }

ct_valid_branch() { [[ $1 =~ ^[A-Za-z0-9._/-]+$ ]] && git check-ref-format --branch "$1" >/dev/null 2>&1; }

# KEY=value reader; the file is never sourced, so it can't run code. Prints the last value for KEY,
# or CT_DEFAULT_<KEY> when the file or key is missing or empty.
ct_conf_get() {
  local file=$1 key=$2 default_var="CT_DEFAULT_$2" line val= found=0
  local default=${!default_var-}
  [[ -f $file ]] || { echo "$default"; return; }
  while IFS= read -r line || [[ -n $line ]]; do
    line="${line%$'\r'}"
    [[ $line == "$key="* ]] || continue
    val="${line#*=}"
    found=1
  done < "$file"
  if [[ $found -eq 1 && -n $val ]]; then echo "$val"; else echo "$default"; fi
}

# prints each path from stdin (one per line) that falls under a space-separated protected list;
# entries ending in / match a directory prefix, others match exactly
ct_protected_hits() {
  local protected=$1 path entry
  local -a entries
  read -ra entries <<< "$protected"
  while IFS= read -r path; do
    for entry in "${entries[@]}"; do
      if [[ $entry == */ && $path == "$entry"* ]] || [[ $path == "$entry" ]]; then
        echo "$path"
        break
      fi
    done
  done
}

_CT_SECRET_NAME_RE='^(\.env(\..*)?|.*\.(pem|key|p12|pfx|jks|keystore)|id_(rsa|dsa|ecdsa|ed25519)(_.*)?|\.netrc|\.pypirc|credentials\.json|.*secrets?\.(env|json|ya?ml|toml))$'
_CT_SECRET_NAME_OK_RE='^\.env\.(example|sample|template)$|\.pub$'
_CT_SECRET_CONTENT_RE='-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|sk-ant-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|sk_live_[0-9A-Za-z]{24,}'

# Heuristic scan of files added or changed between two tree-ishes. Prints "path: reason" for each
# hit and never prints file contents. Not a complete secret detector.
ct_secret_scan() {
  local old=$1 new=$2 path base hits=0
  while IFS= read -r -d '' path; do
    base="${path##*/}"
    if [[ $base =~ $_CT_SECRET_NAME_RE ]] && ! [[ $base =~ $_CT_SECRET_NAME_OK_RE ]]; then
      echo "$path: filename looks like a secret or credential file"
      hits=1
      continue
    fi
    if git cat-file blob "$new:$path" 2>/dev/null | grep -IqE -e "$_CT_SECRET_CONTENT_RE"; then
      echo "$path: content matches a credential pattern"
      hits=1
    fi
  done < <(git diff -z --name-only --no-renames --diff-filter=AMT "$old" "$new")
  return "$hits"
}

# fails rather than overwrites when the remote ref exists, even if the push would fast-forward
ct_push_new_ref() {
  local remote=$1 sha=$2 ref=$3
  git push --quiet --no-verify "$remote" "--force-with-lease=$ref:" "$sha:$ref"
}

# deletes the remote ref only while it still points at sha
ct_delete_ref_if() {
  local remote=$1 sha=$2 ref=$3
  git push --quiet --no-verify "$remote" "--force-with-lease=$ref:$sha" ":$ref"
}
