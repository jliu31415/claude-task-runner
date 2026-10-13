#!/usr/bin/env bash
# CI side of the Claude task runner; each phase is one workflow step (see claude-task-run.yml).
#   inputs | verify | hook <setup|validate> | claude | collect | publish
# Environment:
#   CT_CONF   trusted .claude-task/config from the dispatched commit, not the snapshot (may be absent)
#   CT_WORK   checkout of the submitted snapshot
#   CT_OUT    directory for the prompt, report and patch (uploaded as the task artifact)
#   CT_SNAPSHOT_REF CT_SNAPSHOT_SHA CT_PROMPT_PATH CT_TASK_NAME CT_TASK_ID   workflow inputs
set -euo pipefail

CT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CT_LIB/common.sh"

CT_CLAUDE_CODE_VERSION=2.1.296
CT_CLAUDE_TOOLS=Read,Edit,Write,Glob,Grep,Bash,TodoWrite
CT_DEFAULT_PROTECTED=".github/ .claude/ $CT_DIR/"
CT_OIDC_AUDIENCE=https://api.anthropic.com
# GitHub's identity tokens live about 5 minutes; the CLI re-reads the file whenever it refreshes
CT_OIDC_REFRESH_SECONDS=${CT_OIDC_REFRESH_SECONDS:-120}
# the job may hold id-token: write; untrusted code (hooks, Claude) runs without the request vars
CT_NO_OIDC=(env -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN)

: "${CT_CONF:?}" "${CT_WORK:?}" "${CT_OUT:?}"
: "${CT_SNAPSHOT_REF:?}" "${CT_SNAPSHOT_SHA:?}" "${CT_PROMPT_PATH:?}" "${CT_TASK_NAME:?}" "${CT_TASK_ID:?}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
mkdir -p "$CT_OUT"

conf() { ct_conf_get "$CT_CONF" "$1"; }

# .claude-task/ holds the hook scripts, so Claude can't weaken its own validation
protected_paths() {
  echo "$CT_DEFAULT_PROTECTED $(conf PROTECTED_PATHS)"
}

# A prompt that isn't in the snapshot's parent was uploaded only to carry the task (typically from
# the gitignored tasks folder), so the result drops it again rather than adding it to the PR.
prompt_is_uploaded() {
  ! git -C "$CT_WORK" cat-file -e "$CT_SNAPSHOT_SHA^:$CT_PROMPT_PATH" 2>/dev/null
}

# paths changed between the snapshot and tree, minus the dropped prompt
claude_changes() {
  git -C "$CT_WORK" diff --name-only --no-renames "$CT_SNAPSHOT_SHA" "$1" \
    | { if prompt_is_uploaded; then grep -vxF -- "$CT_PROMPT_PATH" || true; else cat; fi; }
}

check_changes() {
  local tree=$1 hits
  hits="$(claude_changes "$tree" | ct_protected_hits "$(protected_paths)")"
  [[ -z $hits ]] || { echo "$hits" | sed 's/^/  /' >&2; ct_die "changes to protected paths (above)"; }
  if ! hits="$(cd "$CT_WORK" && ct_secret_scan "$CT_SNAPSHOT_SHA" "$tree")"; then
    echo "$hits" | sed 's/^/  /' >&2
    ct_die "possible secrets in the changes (above)"
  fi
}

check_inputs() {
  ct_valid_task_name "$CT_TASK_NAME" || ct_die "invalid task_name: $CT_TASK_NAME"
  ct_valid_task_id "$CT_TASK_ID" "$CT_TASK_NAME" || ct_die "invalid task_id for task_name $CT_TASK_NAME: $CT_TASK_ID"
  [[ $CT_SNAPSHOT_REF == "$CT_SNAPSHOT_PREFIX$CT_TASK_ID" ]] \
    || ct_die "snapshot_ref must be $CT_SNAPSHOT_PREFIX$CT_TASK_ID, got: $CT_SNAPSHOT_REF"
  ct_valid_sha "$CT_SNAPSHOT_SHA" || ct_die "invalid snapshot_sha: $CT_SNAPSHOT_SHA"
  ct_valid_prompt_path "$CT_PROMPT_PATH" || ct_die "invalid prompt_path: $CT_PROMPT_PATH"
}

check_head() {
  local head
  head="$(git -C "$CT_WORK" rev-parse HEAD)"
  [[ $head == "$CT_SNAPSHOT_SHA" ]] \
    || ct_die "checked out $head, expected snapshot $CT_SNAPSHOT_SHA; was $CT_SNAPSHOT_REF moved?"
}

no_gitlinks() {
  ! git -C "$CT_WORK" ls-tree -r "$1" | grep -q '^160000 ' \
    || ct_die "submodules and nested git repositories aren't supported"
}

worktree_tree() {
  git -C "$CT_WORK" add --all -- . && git -C "$CT_WORK" write-tree
}

phase_inputs() {
  local base
  check_inputs
  base="$(conf BASE_BRANCH)"
  [[ ${GITHUB_REF-} == "refs/heads/$base" ]] \
    || ct_die "dispatch the workflow from $base (got ref ${GITHUB_REF-unset}); its config and scripts are trusted only there"
}

phase_verify() {
  local entry mode type
  check_inputs
  check_head
  git -C "$CT_WORK" rev-parse --verify --quiet "$CT_SNAPSHOT_SHA^" >/dev/null \
    || ct_die "the snapshot's parent commit wasn't fetched (checkout needs fetch-depth 2)"
  no_gitlinks HEAD
  entry="$(git -C "$CT_WORK" ls-tree HEAD -- "$CT_PROMPT_PATH")"
  read -r mode type _ <<< "$entry"
  [[ $type == blob && ( $mode == 100644 || $mode == 100755 ) ]] \
    || ct_die "prompt $CT_PROMPT_PATH is not a regular file in the snapshot"
  git -C "$CT_WORK" cat-file blob "HEAD:$CT_PROMPT_PATH" > "$CT_OUT/prompt.md"
  [[ -s $CT_OUT/prompt.md ]] || ct_die "prompt $CT_PROMPT_PATH is empty"
  [[ -z $(git -C "$CT_WORK" status --porcelain --untracked-files=all) ]] \
    || ct_die "snapshot checkout is not clean"
  echo "snapshot $CT_SNAPSHOT_SHA verified; prompt $CT_PROMPT_PATH ($(wc -c < "$CT_OUT/prompt.md") bytes)"
}

phase_hook() {
  local which=$1 script dirty
  case "$which" in
    setup) script=$CT_SETUP_PATH ;;
    validate) script=$CT_VALIDATE_PATH ;;
    *) ct_die "unknown hook: $which" ;;
  esac
  if [[ ! -e $CT_WORK/$script && $which == setup ]]; then
    echo "no $script; skipping setup"
    return
  fi
  [[ -f $CT_WORK/$script && ! -L $CT_WORK/$script ]] || ct_die "$script is not a regular file in the snapshot"
  [[ -x $CT_WORK/$script ]] || ct_die "$script is not executable"

  echo "running $which hook: $script"
  (cd "$CT_WORK" && "${CT_NO_OIDC[@]}" "./$script") || ct_die "$which hook $script failed"

  if [[ $which == setup ]]; then
    dirty="$(git -C "$CT_WORK" status --porcelain --untracked-files=all)"
    [[ -z $dirty ]] || { echo "$dirty" >&2; ct_die "setup hook changed tracked or unignored files (above); write outputs to ignored paths"; }
  elif [[ -f $CT_OUT/tree ]]; then
    [[ $(worktree_tree) == "$(cat "$CT_OUT/tree")" ]] \
      || ct_die "validation changed tracked or unignored files after the changes were collected"
  fi
}

# writes a fresh GitHub OIDC token for the Anthropic audience to $1, atomically and without echoing it
fetch_oidc_token() {
  local dest=$1 tmp token
  tmp="$dest.tmp"
  token="$(curl -sS --fail -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$CT_OIDC_AUDIENCE" | jq -r '.value // empty')" || return 1
  [[ -n $token ]] || return 1
  (umask 077 && printf '%s' "$token" > "$tmp") && mv -f "$tmp" "$dest"
}

# Workload identity federation: when .claude-task/config names a federation rule, Claude Code
# exchanges the job's GitHub OIDC token for a short-lived Anthropic token instead of using a key.
setup_wif() {
  local key val
  for key in ANTHROPIC_FEDERATION_RULE_ID ANTHROPIC_ORGANIZATION_ID ANTHROPIC_SERVICE_ACCOUNT_ID ANTHROPIC_WORKSPACE_ID; do
    val="$(conf "$key")"
    [[ -z $val || $val =~ ^[A-Za-z0-9_-]+$ ]] || ct_die "$key in $CT_CONF_PATH has unexpected characters"
    if [[ -n $val ]]; then export "$key=$val"; else unset "$key"; fi
  done
  [[ -n ${ANTHROPIC_ORGANIZATION_ID-} ]] || ct_die "ANTHROPIC_FEDERATION_RULE_ID needs ANTHROPIC_ORGANIZATION_ID in $CT_CONF_PATH"
  [[ -n ${ACTIONS_ID_TOKEN_REQUEST_URL-} && -n ${ACTIONS_ID_TOKEN_REQUEST_TOKEN-} ]] \
    || ct_die "workload identity federation needs 'id-token: write' on the calling job (rerun 'submit-task init' for a current workflow)"
  # a configured rule wins; a stray key secret would otherwise take precedence in the CLI
  unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
  export ANTHROPIC_IDENTITY_TOKEN_FILE="$CT_TMP/oidc-token"
  fetch_oidc_token "$ANTHROPIC_IDENTITY_TOKEN_FILE" || ct_die "couldn't get a GitHub OIDC token"
  (
    while sleep "$CT_OIDC_REFRESH_SECONDS"; do
      fetch_oidc_token "$ANTHROPIC_IDENTITY_TOKEN_FILE" || ct_warn "refreshing the GitHub OIDC token failed"
    done
  ) &
  CT_OIDC_REFRESHER=$!
  echo "authenticating with workload identity federation (rule $ANTHROPIC_FEDERATION_RULE_ID)"
}

phase_claude() {
  local bin=${CLAUDE_BIN:-} budget model instructions status result is_error
  CT_TMP="$(mktemp -d)"
  CT_OIDC_REFRESHER=""
  trap '[[ -z $CT_OIDC_REFRESHER ]] || kill "$CT_OIDC_REFRESHER" 2>/dev/null; rm -rf "$CT_TMP"' EXIT
  if [[ -n $(conf ANTHROPIC_FEDERATION_RULE_ID) ]]; then
    setup_wif
  else
    [[ -n ${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-} ]] \
      || ct_die "set the ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN secret, or configure workload identity federation"
  fi
  if [[ -z $bin ]]; then
    npm install --global --no-fund --no-audit "@anthropic-ai/claude-code@$CT_CLAUDE_CODE_VERSION"
    bin=claude
  fi

  instructions="$CT_TMP/instructions.md"
  {
    cat "$CT_LIB/instructions.md"
    printf '\nProtected paths (changing any of them fails the task): %s\n' "$(protected_paths)"
  } > "$instructions"

  local -a args=(
    -p --output-format stream-json --verbose --no-session-persistence
    --permission-mode dontAsk --allowedTools "$CT_CLAUDE_TOOLS"
    # project .claude/ settings come from the snapshot and may carry hooks; don't load them
    --setting-sources user
    --append-system-prompt-file "$instructions"
  )
  budget="$(conf CLAUDE_MAX_BUDGET_USD)"
  model="$(conf CLAUDE_MODEL)"
  [[ -z $budget || $budget =~ ^[0-9]+(\.[0-9]+)?$ ]] || ct_die "CLAUDE_MAX_BUDGET_USD must be a number: $budget"
  [[ -n $budget ]] && args+=(--max-budget-usd "$budget")
  [[ -n $model ]] && args+=(--model "$model")

  set +e
  (cd "$CT_WORK" && "${CT_NO_OIDC[@]}" "$bin" "${args[@]}" < "$CT_OUT/prompt.md") \
    | tee -p "$CT_OUT/transcript.jsonl" \
    | jq -R --unbuffered -r 'fromjson? | select(.type == "assistant") | .message.content[]?
        | if .type == "text" then .text
          elif .type == "tool_use" then "> \(.name) \(.input.command // .input.file_path // .input.pattern // "")"
          else empty end'
  status=${PIPESTATUS[0]}
  set -e

  result="$(jq -R -c 'fromjson? | select(.type == "result")' "$CT_OUT/transcript.jsonl" | tail -n1)"
  [[ -n $result ]] || ct_die "Claude exited with status $status and produced no result"
  jq -r '.result // ""' <<< "$result" > "$CT_OUT/claude-report.md"
  is_error="$(jq -r '.is_error' <<< "$result")"
  jq -r '"claude: \(.subtype), \(.num_turns) turns, $\(.total_cost_usd // "?"), \((.duration_ms // 0) / 1000 | floor)s"' <<< "$result"
  [[ $status -eq 0 && $is_error == false ]] || ct_die "Claude failed (exit $status, is_error=$is_error)"
}

phase_collect() {
  local tree n
  check_head
  prompt_is_uploaded && rm -f "$CT_WORK/$CT_PROMPT_PATH"
  tree="$(worktree_tree)"
  no_gitlinks "$tree"
  claude_changes "$tree" > "$CT_OUT/files.txt"
  check_changes "$tree"
  n="$(grep -c '' "$CT_OUT/files.txt" || true)"
  if [[ $n -gt 0 ]]; then
    git -C "$CT_WORK" diff --cached --binary --no-renames "$CT_SNAPSHOT_SHA" > "$CT_OUT/changes.patch"
  else
    : > "$CT_OUT/changes.patch"
  fi
  echo "$tree" > "$CT_OUT/tree"
  echo "has_changes=$([[ $n -gt 0 ]] && echo true || echo false)" >> "$GITHUB_OUTPUT"
  echo "Claude changed $n file(s)"
  sed 's/^/  /' "$CT_OUT/files.txt"
}

delete_snapshot() {
  if ct_delete_ref_if origin "$CT_SNAPSHOT_SHA" "refs/heads/$CT_SNAPSHOT_REF"; then
    echo "deleted $CT_SNAPSHOT_REF"
  else
    ct_warn "couldn't delete $CT_SNAPSHOT_REF (moved or already gone); delete it by hand if it's still there"
  fi
}

pr_body() {
  local run_url=$1 parent
  cat <<EOF
Automated change from the Claude task runner. Review before merging; it is never auto-merged.

| | |
|---|---|
| Task ID | \`$CT_TASK_ID\` |
| Prompt | \`$CT_PROMPT_PATH\` |
| Snapshot | \`$CT_SNAPSHOT_SHA\` |
| Run | $run_url |
| Validation | \`$CT_VALIDATE_PATH\` passed |

The branch is the submitted snapshot plus one commit with Claude's changes. Local changes that
were in the snapshot but aren't on \`$(conf BASE_BRANCH)\` also show up in this PR; the
last commit alone is Claude's work.

EOF
  if parent="$(git rev-parse --verify --quiet "$CT_SNAPSHOT_SHA^")"; then
    echo "<details><summary>Submitted local changes (snapshot vs ${parent:0:12})</summary>"
    echo
    echo '```'
    git diff --stat=100 --no-renames "$parent" "$CT_SNAPSHOT_SHA" | tail -n 60
    echo '```'
    echo "</details>"
    echo
  fi
  echo "<details><summary>Claude's changes</summary>"
  echo
  echo '```'
  git diff --stat=100 --no-renames "$CT_SNAPSHOT_SHA" HEAD | tail -n 60
  echo '```'
  echo "</details>"
  echo
  echo "### Claude's report"
  echo
  head -c 20000 "$CT_OUT/claude-report.md"
}

phase_publish() {
  local base prefix branch tree hits new run_url
  check_inputs
  check_head
  cd "$CT_WORK"
  base="$(conf BASE_BRANCH)"
  prefix="$(conf RESULT_BRANCH_PREFIX)"
  branch="$prefix$CT_TASK_NAME"
  ct_valid_branch "$branch" || ct_die "invalid result branch: $branch"
  run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"

  if [[ ! -s $CT_OUT/changes.patch ]]; then
    echo "Claude made no changes; no branch or PR created."
    printf '### Task %s\n\nClaude made no changes; no branch or PR was created.\n' "$CT_TASK_ID" >> "$GITHUB_STEP_SUMMARY"
    delete_snapshot
    return
  fi

  # re-check everything here: this job holds the write token and trusts nothing from the run job
  git apply --check --index --binary "$CT_OUT/changes.patch" || ct_die "the patch doesn't apply to the snapshot"
  git apply --index --binary "$CT_OUT/changes.patch"
  tree="$(git write-tree)"
  [[ $tree == "$(cat "$CT_OUT/tree")" ]] || ct_die "applied patch doesn't reproduce the validated tree"
  check_changes "$tree"

  if git ls-remote --exit-code origin "refs/heads/$branch" >/dev/null 2>&1; then
    ct_die "result branch $branch already exists; not overwriting it. The patch is in this run's artifact and $CT_SNAPSHOT_REF is kept."
  fi

  printf 'Claude task %s\n\nPrompt: %s\nSnapshot: %s\nRun: %s\n' \
      "$CT_TASK_ID" "$CT_PROMPT_PATH" "$CT_SNAPSHOT_SHA" "$run_url" |
    git -c user.name='github-actions[bot]' \
        -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
        commit --quiet --no-verify -F -
  new="$(git rev-parse HEAD)"
  ct_push_new_ref origin "$new" "refs/heads/$branch" \
    || ct_die "pushing $branch failed; the patch is in this run's artifact and $CT_SNAPSHOT_REF is kept"
  echo "pushed $branch ($new)"

  pr_body "$run_url" > "$CT_OUT/pr-body.md"
  local pr
  if ! pr="$(gh pr create --repo "${GITHUB_REPOSITORY:?}" --base "$base" --head "$branch" \
      --title "Claude task: $CT_TASK_NAME" --body-file "$CT_OUT/pr-body.md")"; then
    ct_die "pushed $branch but creating the PR failed; open it by hand (gh pr create --base $base --head $branch). $CT_SNAPSHOT_REF is kept."
  fi
  echo "opened $pr"
  printf '### Task %s\n\nPR: %s\n' "$CT_TASK_ID" "$pr" >> "$GITHUB_STEP_SUMMARY"
  delete_snapshot
}

case "${1-}" in
  inputs) phase_inputs ;;
  verify) phase_verify ;;
  hook) phase_hook "${2-}" ;;
  claude) phase_claude ;;
  collect) phase_collect ;;
  publish) phase_publish ;;
  *) ct_die "usage: ci.sh inputs|verify|hook <setup|validate>|claude|collect|publish" ;;
esac
