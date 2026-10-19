#!/usr/bin/env bash
# Everything runs in throwaway repos with a local bare remote behind a fake github.com URL; gh and
# claude are replaced by mocks.
#   tests/run.sh [test-name...]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$(cd "$HERE/../lib" && pwd)"
SUBMIT="$HERE/../bin/submit-task"
CI="$LIB/ci.sh"

die() { echo "assertion failed: $*" >&2; exit 1; }
fails() { if "$@"; then die "expected failure: $*"; fi; }
eq() { [[ $1 == "$2" ]] || die "expected '$2', got '$1'${3:+ ($3)}"; }
contains() { grep -qF -- "$2" <<< "$1" || die "output lacks '$2':"$'\n'"$1"; }

# --- sandbox -----------------------------------------------------------------------------------

sandbox() {
  SB="$(mktemp -d)"
  trap 'rm -rf "$SB"' EXIT
  export HOME="$SB/home" XDG_CONFIG_HOME="$SB/home/.config" GIT_CONFIG_NOSYSTEM=1 TMPDIR="$SB/tmp"
  mkdir -p "$HOME" "$TMPDIR" "$SB/bin"
  git config --global user.name tester
  git config --global user.email tester@example.com
  git config --global init.defaultBranch main
  git config --global url."$SB/remote.git".insteadOf https://github.com/test/repo.git
  export PATH="$SB/bin:$PATH" GH_LOG="$SB/gh.log"
  install_gh_mock
  install_claude_mock
  install_oidc_mocks

  git init -q --bare "$SB/remote.git"
  REPO="$SB/repo"
  git init -q "$REPO"
  cd "$REPO"
  git remote add origin https://github.com/test/repo.git
  mkdir -p tasks .claude-task .github/workflows
  printf 'ignored/\n*.log\n.env\nbuild/\n' > .gitignore
  echo a > a.txt; echo b > b.txt; echo c > c.txt; echo keep > keep.txt
  printf '#!/bin/sh\necho hi\n' > tool.sh
  ln -s a.txt link
  echo 'name: claude task' > .github/workflows/claude-task.yml
  printf 'PROTECTED_PATHS=guarded/\nCLAUDE_MAX_BUDGET_USD=1\n' > .claude-task/config
  echo 'tasks/' > .claude-task/.gitignore
  printf '#!/usr/bin/env bash\nset -euo pipefail\nmkdir -p build && echo setup > build/setup.out\n${SETUP_EXTRA:-true}\n' > .claude-task/setup.sh
  printf '#!/usr/bin/env bash\nset -euo pipefail\ngrep -q . a.txt\n${VALIDATE_EXTRA:-true}\n' > .claude-task/validate.sh
  chmod +x .claude-task/setup.sh .claude-task/validate.sh
  git add -A
  git commit -qm init
  git push -q origin main
}

install_gh_mock() {
  cat > "$SB/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "auth status") [[ ${GH_MOCK_FAIL-} == auth ]] && exit 1; exit 0 ;;
  "workflow run") [[ ${GH_MOCK_FAIL-} == workflow ]] && { echo "HTTP 422" >&2; exit 1; }; exit 0 ;;
  "run list") echo "123 https://github.com/test/repo/actions/runs/123" ;;
  "pr create") [[ ${GH_MOCK_FAIL-} == pr ]] && exit 1; echo "https://github.com/test/repo/pull/1" ;;
esac
EOF
  chmod +x "$SB/bin/gh"
}

# FAKE_CLAUDE: edit (default) | none | fail | error-result | protected | hook | secret
install_claude_mock() {
  cat > "$SB/bin/fake-claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat > "$PWD/../claude-stdin"
printf '%s\n' "$@" > "$PWD/../claude-args"
{
  echo "rule=${ANTHROPIC_FEDERATION_RULE_ID-}"
  echo "org=${ANTHROPIC_ORGANIZATION_ID-}"
  echo "api_key=${ANTHROPIC_API_KEY-}"
  echo "oidc_request=${ACTIONS_ID_TOKEN_REQUEST_TOKEN-}"
  echo "token_file=${ANTHROPIC_IDENTITY_TOKEN_FILE-}"
  if [[ -n ${ANTHROPIC_IDENTITY_TOKEN_FILE-} ]]; then
    echo "jwt1=$(cat "$ANTHROPIC_IDENTITY_TOKEN_FILE")"
    sleep "${FAKE_CLAUDE_SLEEP:-0}"
    echo "jwt2=$(cat "$ANTHROPIC_IDENTITY_TOKEN_FILE")"
  fi
} > "$PWD/../claude-env"
echo '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
result() { printf '{"type":"result","subtype":"%s","is_error":%s,"result":"## Summary\\nreport","num_turns":2,"total_cost_usd":0.01,"duration_ms":1500}\n' "$1" "$2"; }
case "${FAKE_CLAUDE:-edit}" in
  edit) echo "changed by claude" >> a.txt; mkdir -p src; echo new > src/new.txt; rm c.txt ;;
  none) ;;
  fail) exit 1 ;;
  error-result) result error_max_budget_usd true; exit 0 ;;
  protected) echo x > .github/workflows/evil.yml ;;
  hook) echo 'exit 0' > .claude-task/validate.sh ;;
  secret) printf 'key=%s%s\n' AKIA ABCDEFGHIJKLMNOP > leaked.txt ;;
esac
result success false
EOF
  chmod +x "$SB/bin/fake-claude"
}

# curl stands in for GitHub's OIDC token endpoint; env-probe lets a hook report what it can see
install_oidc_mocks() {
  cat > "$SB/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SB_CURL_LOG"
[[ ${GH_MOCK_FAIL-} == oidc ]] && exit 22
n=$(( $(cat "$SB_CURL_LOG" | grep -c '') ))
printf '{"count":%d,"value":"jwt-%d"}' "$n" "$n"
EOF
  printf '#!/usr/bin/env bash\necho "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-none}" > "$SB_HOOK_ENV"\n' > "$SB/bin/env-probe"
  chmod +x "$SB/bin/curl" "$SB/bin/env-probe"
  export SB_CURL_LOG="$SB/curl.log" SB_HOOK_ENV="$SB/hook-env"
}

snap() { git -C "$REPO" ls-remote origin "refs/heads/agent-snapshots/*"; }

# runs submit and sets TASK_ID / SNAP_SHA from its output
submit() {
  local out
  out="$("$SUBMIT" --yes "$@" 2>&1)" || { echo "$out" >&2; return 1; }
  OUT=$out
  TASK_ID="$(sed -n 's/^task: *//p' <<< "$out")"
  SNAP_SHA="$(sed -n 's/^snapshot: *\([0-9a-f]*\).*/\1/p' <<< "$out")"
}

# CI environment for a submitted task, as claude-task-run.yml sets it up
ci_env() {
  export CT_CONF="$REPO/.claude-task/config" CT_WORK="$SB/work" CT_OUT="$SB/out"
  export CT_SNAPSHOT_REF="agent-snapshots/$TASK_ID" CT_SNAPSHOT_SHA="$SNAP_SHA"
  export CT_PROMPT_PATH="${1:-tasks/t.md}" CT_TASK_NAME="${TASK_ID%-*}" CT_TASK_ID="$TASK_ID"
  export GITHUB_REF=refs/heads/main GITHUB_REPOSITORY=test/repo GITHUB_RUN_ID=1
  export GITHUB_OUTPUT="$SB/gh-output" GITHUB_STEP_SUMMARY="$SB/summary"
  export CLAUDE_BIN=fake-claude ANTHROPIC_API_KEY=dummy
  rm -rf "$CT_WORK"
  git clone -q --depth 2 --branch "$CT_SNAPSHOT_REF" "file://$SB/remote.git" "$CT_WORK"
}

# the run job's steps in workflow order, then the publish job in a fresh checkout
pipeline() {
  "$CI" inputs && "$CI" verify && "$CI" hook setup && "$CI" claude && "$CI" collect \
    && "$CI" hook validate || return 1
  rm -rf "$SB/pub"
  git clone -q --depth 2 --branch "$CT_SNAPSHOT_REF" "file://$SB/remote.git" "$SB/pub"
  CT_WORK="$SB/pub" "$CI" inputs && CT_WORK="$SB/pub" "$CI" publish
}

tree_state() {
  (cd "$REPO" && find . -path ./.git -prune -o -print0 | sort -z | xargs -0 -I{} sh -c \
    'if [ -L "{}" ]; then echo "L {} $(readlink "{}")"; elif [ -f "{}" ]; then echo "F {} $(stat -c %a "{}") $(sha256sum < "{}")"; else echo "D {}"; fi')
}

# --- submit: snapshot semantics ------------------------------------------------------------------

test_snapshot_contents() {
  sandbox
  echo staged >> a.txt && git add a.txt
  echo unstaged >> b.txt
  git rm -q c.txt
  rm keep.txt
  mkdir -p new ignored && echo d > new/d.txt && echo secret > ignored/x && echo log > debug.log
  echo 'TOKEN=1' > .env
  chmod -x tool.sh
  ln -s b.txt link2
  printf '# Task\n\n  exact  prompt\twith tabs\n\n' > tasks/t.md
  echo "partly staged" >> a.txt

  local head index_before state_before status_before
  head="$(git rev-parse HEAD)"
  index_before="$(sha256sum < .git/index)"
  state_before="$(tree_state)"
  status_before="$(GIT_OPTIONAL_LOCKS=0 git status --porcelain)"

  submit tasks/t.md
  ci_env

  eq "$(git rev-parse "$SNAP_SHA^")" "$head" "snapshot parent"
  eq "$(git show "$SNAP_SHA:a.txt")" "$(cat a.txt)" "staged + unstaged edits"
  eq "$(git show "$SNAP_SHA:b.txt")" "$(cat b.txt)" "unstaged edit"
  fails git cat-file -e "$SNAP_SHA:c.txt"
  fails git cat-file -e "$SNAP_SHA:keep.txt"
  eq "$(git show "$SNAP_SHA:new/d.txt")" d "untracked file"
  fails git cat-file -e "$SNAP_SHA:ignored/x"
  fails git cat-file -e "$SNAP_SHA:debug.log"
  fails git cat-file -e "$SNAP_SHA:.env"
  eq "$(git ls-tree "$SNAP_SHA" tool.sh | cut -c1-6)" 100644 "exec bit cleared"
  eq "$(git ls-tree "$SNAP_SHA" link2 | cut -c1-6)" 120000 "symlink mode"
  eq "$(git show "$SNAP_SHA:link2")" b.txt "symlink target"
  cmp <(git show "$SNAP_SHA:tasks/t.md") tasks/t.md || die "prompt bytes differ"

  eq "$(git symbolic-ref --short HEAD)" main
  eq "$(git rev-parse HEAD)" "$head" "HEAD moved"
  eq "$(sha256sum < .git/index)" "$index_before" "real index changed"
  eq "$(tree_state)" "$state_before" "working tree changed"
  eq "$(GIT_OPTIONAL_LOCKS=0 git status --porcelain)" "$status_before" "status changed"
  eq "$(ls -A "$TMPDIR")" "" "temp files left behind"

  grep -q "^workflow run claude-task.yml -R test/repo --ref main -f snapshot_ref=agent-snapshots/$TASK_ID -f snapshot_sha=$SNAP_SHA -f prompt_path=tasks/t.md -f task_name=t -f task_id=$TASK_ID$" "$GH_LOG" \
    || die "unexpected dispatch: $(cat "$GH_LOG")"
  contains "$OUT" "run:      https://github.com/test/repo/actions/runs/123"
}

test_prompt_from_subdirectory() {
  sandbox
  mkdir -p sub && echo '# x' > tasks/x.md
  (cd sub && "$SUBMIT" --yes ../tasks/x.md named-task) > "$SB/out.txt"
  grep -q '^task: *named-task-[0-9a-f]\{6\}$' "$SB/out.txt" || die "$(cat "$SB/out.txt")"
}

test_no_changes() {
  sandbox
  echo '# t' > tasks/t.md && git add tasks/t.md && git commit -qm prompt
  submit tasks/t.md
  contains "$OUT" "changes:  none"
  eq "$(git rev-parse "$SNAP_SHA^{tree}")" "$(git rev-parse "HEAD^{tree}")"
}

test_invalid_prompts_rejected() {
  sandbox
  echo x > "$SB/outside.md"
  mkdir -p tasks/dir.md ignored && echo x > ignored/p.md && echo x > tasks/notmd.txt
  echo x > "tasks/has space.md" && ln -s ../a.txt tasks/link.md && ln -s "$SB/outside.md" tasks/escape.md
  echo x > tasks/-dash.md
  local p
  for p in "$SB/outside.md" ../outside.md tasks/dir.md ignored/p.md tasks/notmd.txt "tasks/has space.md" \
           tasks/link.md tasks/escape.md tasks/missing.md tasks/-dash.md .git/config; do
    fails "$SUBMIT" --yes "$p" 2>/dev/null
  done
  eq "$(snap)" "" "nothing pushed"
}

test_task_names() {
  sandbox
  echo x > tasks/t.md
  local n
  for n in Bad_Name -x a/b x..y trailing- "" "$(printf 'a%.0s' {1..41})" 'a;b'; do
    [[ -z $n ]] && continue
    fails "$SUBMIT" --yes tasks/t.md "$n" 2>/dev/null
  done
  eq "$(snap)" ""
  source "$LIB/common.sh"
  eq "$(ct_sanitize_task_name 'Add Feature: v2!!')" add-feature-v2
  eq "$(ct_sanitize_task_name '__x__')" x
  ct_valid_task_id add-feature-a1b2c3 add-feature || die "valid id rejected"
  fails ct_valid_task_id add-feature-a1b2c3 other
  fails ct_valid_task_id add-feature-A1B2C3
  fails ct_valid_task_id 'x-a1b2c3;rm'
  fails ct_valid_prompt_path ../x.md
  fails ct_valid_prompt_path /abs.md
  fails ct_valid_prompt_path a//b.md
  ct_valid_prompt_path docs/tasks/x-1.md || die "valid prompt path rejected"
}

test_requires_main() {
  sandbox
  echo x > tasks/t.md
  git checkout -qb feature
  local out
  out="$("$SUBMIT" --yes tasks/t.md 2>&1)" && die "submitted from feature"
  contains "$out" "submit tasks from 'main'"
  eq "$(git symbolic-ref --short HEAD)" feature
}

test_gh_unauthenticated_pushes_nothing() {
  sandbox
  echo x > tasks/t.md
  GH_MOCK_FAIL=auth fails "$SUBMIT" --yes tasks/t.md 2>/dev/null
  eq "$(snap)" ""
}

test_existing_result_branch() {
  sandbox
  echo x > tasks/t.md
  git push -q origin HEAD:refs/heads/task-t
  local out
  out="$("$SUBMIT" --yes tasks/t.md 2>&1)" && die "submitted over existing branch"
  contains "$out" "result branch 'task-t' already exists"
  eq "$(snap)" ""
}

test_push_never_overwrites() {
  sandbox
  source "$LIB/common.sh"
  local child
  git push -q origin HEAD:refs/heads/agent-snapshots/x-000000
  child="$(git commit-tree "HEAD^{tree}" -p HEAD -m child)"
  # a plain push would fast-forward here; the lease must refuse because the ref exists
  fails ct_push_new_ref origin "$child" refs/heads/agent-snapshots/x-000000 2>/dev/null
  eq "$(git ls-remote origin refs/heads/agent-snapshots/x-000000 | cut -f1)" "$(git rev-parse HEAD)"
  ct_push_new_ref origin "$child" refs/heads/agent-snapshots/y-000000
  fails ct_delete_ref_if origin "$child" refs/heads/agent-snapshots/x-000000 2>/dev/null
  ct_delete_ref_if origin "$child" refs/heads/agent-snapshots/y-000000
  eq "$(git ls-remote origin refs/heads/agent-snapshots/y-000000)" ""
}

test_dispatch_failure_keeps_snapshot() {
  sandbox
  echo x > tasks/t.md
  local out
  out="$(GH_MOCK_FAIL=workflow "$SUBMIT" --yes tasks/t.md 2>&1)" && die "dispatch failure not reported"
  contains "$out" "the snapshot is kept"
  contains "$out" "retry:   gh workflow run claude-task.yml"
  [[ -n $(snap) ]] || die "snapshot ref was removed"
}

test_secrets_rejected() {
  sandbox
  echo x > tasks/t.md
  echo k > deploy.pem
  fails "$SUBMIT" --yes tasks/t.md 2>/dev/null
  rm deploy.pem
  printf 'token = "%s%s"\n' ghp_ "$(printf 'a%.0s' {1..36})" > config.py
  local out
  out="$("$SUBMIT" --yes tasks/t.md 2>&1)" && die "secret content not caught"
  contains "$out" "config.py: content matches a credential pattern"
  grep -q ghp_ <<< "$out" && die "secret printed"
  echo 'X=' > .env.example && rm config.py
  submit tasks/t.md
}

test_submodules_and_lfs_rejected() {
  sandbox
  echo x > tasks/t.md
  git init -q vendor/sub && git -C vendor/sub commit -q --allow-empty -m x
  local out
  out="$("$SUBMIT" --yes tasks/t.md 2>&1)" && die "nested repo accepted"
  contains "$out" "submodules or nested git repositories"
  rm -rf vendor
  echo '*.bin filter=lfs diff=lfs merge=lfs -text' > .gitattributes && echo x > a.bin
  out="$("$SUBMIT" --yes tasks/t.md 2>&1)" && die "lfs accepted"
  contains "$out" "Git LFS"
  eq "$(snap)" ""
}

# --- CI phases ---------------------------------------------------------------------------------

test_ci_success_publishes_pr() {
  sandbox
  echo "local change" >> b.txt
  printf '# Task\nDo the thing.\n```\nexample\n```\n' > tasks/t.md
  submit tasks/t.md
  ci_env
  pipeline > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed"; }

  cmp "$SB/claude-stdin" tasks/t.md || die "Claude didn't get the exact prompt"
  grep -qx -- --setting-sources "$SB/claude-args" || die "claude args: $(cat "$SB/claude-args")"
  grep -qx -- --max-budget-usd "$SB/claude-args" || die "budget not passed"
  local tip
  tip="$(git ls-remote origin refs/heads/task-t | cut -f1)"
  [[ -n $tip ]] || die "no result branch"
  git fetch -q origin task-t
  eq "$(git rev-parse "$tip^")" "$SNAP_SHA" "result parent is the snapshot"
  eq "$(git diff --name-only "$SNAP_SHA" "$tip" | tr '\n' ' ')" "a.txt c.txt src/new.txt tasks/t.md " "Claude's commit"
  fails git cat-file -e "$tip:tasks/t.md"
  eq "$(git diff --name-only HEAD "$tip" | tr '\n' ' ')" "a.txt b.txt c.txt src/new.txt " "PR diff vs main"
  eq "$(git show "$tip:b.txt")" "$(cat b.txt)" "baseline kept"
  fails git cat-file -e "$tip:build/setup.out"
  grep -q "^pr create --repo test/repo --base main --head task-t --title Claude task: t" "$GH_LOG" || die "$(cat "$GH_LOG")"
  grep -q "$SNAP_SHA" "$SB/out/pr-body.md" || die "PR body lacks snapshot sha"
  grep -q "$TASK_ID" "$SB/out/pr-body.md" || die "PR body lacks task id"
  grep -q '^## Summary' "$SB/out/pr-body.md" || die "PR body lacks Claude's report"
  grep -qx 'Do the thing.' "$SB/out/pr-body.md" || die "PR body lacks the prompt"
  grep -qx '````' "$SB/out/pr-body.md" || die "prompt fence not longer than its backtick runs"
  eq "$(snap)" "" "snapshot ref not cleaned up"
}

test_ci_claude_failure_blocks_publish() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  local mode
  for mode in fail error-result; do
    ci_env
    FAKE_CLAUDE=$mode pipeline > "$SB/log" 2>&1 && die "pipeline passed with claude=$mode"
    grep -q "claude-task: Claude failed\|produced no result" "$SB/log" || die "$(cat "$SB/log")"
  done
  eq "$(git ls-remote origin refs/heads/task-t)" "" "published anyway"
  [[ -n $(snap) ]] || die "snapshot removed after failure"
}

test_ci_validation_failure_blocks_publish() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  VALIDATE_EXTRA=false pipeline > "$SB/log" 2>&1 && die "pipeline passed"
  grep -q "validate hook .claude-task/validate.sh failed" "$SB/log" || die "$(cat "$SB/log")"
  eq "$(git ls-remote origin refs/heads/task-t)" ""
}

test_ci_validation_must_not_change_tree() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  VALIDATE_EXTRA="touch stray.txt" pipeline > "$SB/log" 2>&1 && die "pipeline passed"
  grep -q "validation changed tracked or unignored files" "$SB/log" || die "$(cat "$SB/log")"
}

test_ci_setup_must_not_dirty_tree() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  SETUP_EXTRA="touch stray.txt" pipeline > "$SB/log" 2>&1 && die "pipeline passed"
  grep -q "setup hook changed tracked or unignored files" "$SB/log" || die "$(cat "$SB/log")"
}

test_ci_protected_and_secret_changes_rejected() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  FAKE_CLAUDE=protected pipeline > "$SB/log" 2>&1 && die "protected change published"
  grep -q "changes to protected paths" "$SB/log" || die "$(cat "$SB/log")"
  ci_env
  FAKE_CLAUDE=hook pipeline > "$SB/log" 2>&1 && die "hook change published"
  grep -q "\.claude-task/validate.sh" "$SB/log" || die "$(cat "$SB/log")"
  ci_env
  FAKE_CLAUDE=secret pipeline > "$SB/log" 2>&1 && die "secret published"
  grep -q "leaked.txt: content matches" "$SB/log" || die "$(cat "$SB/log")"
  eq "$(git ls-remote origin refs/heads/task-t)" ""
}

test_ci_no_changes() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  FAKE_CLAUDE=none pipeline > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed"; }
  grep -q "has_changes=false" "$GITHUB_OUTPUT" || die "has_changes not false"
  grep -q "Claude made no changes" "$SB/log" || die "$(cat "$SB/log")"
  eq "$(git ls-remote origin 'refs/heads/task-*')" "" "branch created"
  grep -q "^pr create" "$GH_LOG" && die "PR opened"
  eq "$(snap)" "" "snapshot not cleaned up"
}

test_ci_existing_result_branch_not_overwritten() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  git push -q origin HEAD:refs/heads/task-t
  pipeline > "$SB/log" 2>&1 && die "pipeline passed"
  grep -q "result branch task-t already exists" "$SB/log" || die "$(cat "$SB/log")"
  eq "$(git ls-remote origin refs/heads/task-t | cut -f1)" "$(git rev-parse HEAD)" "branch overwritten"
  [[ -n $(snap) ]] || die "snapshot removed"
}

test_ci_rejects_bad_inputs_and_moved_snapshot() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  CT_SNAPSHOT_REF=agent-snapshots/other-abcdef fails "$CI" inputs 2>/dev/null
  CT_TASK_ID="t-abcdef;x" fails "$CI" inputs 2>/dev/null
  CT_PROMPT_PATH=../etc/passwd.md fails "$CI" inputs 2>/dev/null
  GITHUB_REF=refs/heads/feature fails "$CI" inputs 2>/dev/null
  CT_PROMPT_PATH=a.txt fails "$CI" inputs 2>/dev/null
  CT_PROMPT_PATH=tasks/missing.md fails "$CI" verify 2>/dev/null
  CT_SNAPSHOT_SHA="$(git rev-parse HEAD)" fails "$CI" verify 2>/dev/null
  "$CI" inputs && "$CI" verify > /dev/null
}

test_ci_publish_rejects_tampered_patch() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  "$CI" verify && "$CI" hook setup && "$CI" claude && "$CI" collect > /dev/null 2>&1
  sed -i 's/^+changed by claude$/+something else/' "$SB/out/changes.patch"
  rm -rf "$SB/pub"
  git clone -q --depth 2 --branch "$CT_SNAPSHOT_REF" "file://$SB/remote.git" "$SB/pub"
  local out
  out="$(CT_WORK="$SB/pub" "$CI" publish 2>&1)" && die "tampered patch published"
  contains "$out" "doesn't reproduce the validated tree"
}

# --- the .claude-task/ folder ------------------------------------------------------------------

test_tasks_folder_prompt() {
  sandbox
  mkdir -p .claude-task/tasks
  printf '# Fix\nfix it\n' > .claude-task/tasks/fix-bug.md
  local status_before
  status_before="$(GIT_OPTIONAL_LOCKS=0 git status --porcelain)"
  eq "$status_before" "" "tasks folder should be ignored"
  submit fix-bug
  contains "$OUT" "prompt:   .claude-task/tasks/fix-bug.md"
  [[ $TASK_ID == fix-bug-* ]] || die "task id $TASK_ID"
  cmp <(git show "$SNAP_SHA:.claude-task/tasks/fix-bug.md") .claude-task/tasks/fix-bug.md || die "prompt not in snapshot"
  ci_env .claude-task/tasks/fix-bug.md
  pipeline > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed"; }
  local tip
  tip="$(git ls-remote origin refs/heads/task-fix-bug | cut -f1)"
  git fetch -q origin task-fix-bug
  fails git cat-file -e "$tip:.claude-task/tasks/fix-bug.md"
  eq "$(git diff --name-only HEAD "$tip" | tr '\n' ' ')" "a.txt c.txt src/new.txt " "PR diff vs main"
  eq "$(GIT_OPTIONAL_LOCKS=0 git status --porcelain)" "" "working tree changed"
}

test_committed_prompt_kept() {
  sandbox
  echo '# t' > tasks/t.md && git add tasks/t.md && git commit -qm prompt && git push -q origin main
  submit tasks/t.md
  ci_env
  pipeline > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed"; }
  git fetch -q origin task-t
  git cat-file -e "FETCH_HEAD:tasks/t.md" || die "committed prompt was dropped"
}

test_optional_config_and_setup() {
  sandbox
  git rm -q .claude-task/config .claude-task/setup.sh && git commit -qm minimal && git push -q origin main
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  pipeline > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed"; }
  grep -q "skipping setup" "$SB/log" || die "$(cat "$SB/log")"
  grep -qx -- 10 "$SB/claude-args" || die "default budget not passed: $(cat "$SB/claude-args")"
  [[ -n $(git ls-remote origin refs/heads/task-t) ]] || die "not published"
}

test_validate_required() {
  sandbox
  echo x > tasks/t.md
  git rm -q .claude-task/validate.sh
  local out
  out="$("$SUBMIT" --yes tasks/t.md 2>&1)" && die "submitted without validate.sh"
  contains "$out" "run 'submit-task init'"
  git commit -qm "drop validate" && git push -q origin main
  touch .claude-task/validate.sh && chmod +x .claude-task/validate.sh
  submit tasks/t.md
  rm .claude-task/validate.sh
  ci_env
  git -C "$CT_WORK" rm -q --cached .claude-task/validate.sh && rm "$CT_WORK/.claude-task/validate.sh"
  fails "$CI" hook validate 2>/dev/null
}

test_init() {
  sandbox
  local runner="$SB/runner" target="$SB/target" sha out
  mkdir -p "$runner"
  cp -r "$HERE/../bin" "$HERE/../lib" "$HERE/../templates" "$runner/"
  git -C "$runner" init -q && git -C "$runner" add -A && git -C "$runner" commit -qm runner
  git -C "$runner" tag v9.9.9
  git -C "$runner" remote add origin https://github.com/test/runner.git
  sha="$(git -C "$runner" rev-parse HEAD)"
  git init -q "$target" && cd "$target"
  out="$("$runner/bin/submit-task" init 2>&1)"
  contains "$out" "isn't on test/runner yet"
  [[ -x .claude-task/validate.sh && -x .claude-task/setup.sh ]] || die "hook scripts not executable"
  [[ -d .claude-task/tasks && ! -e .claude-task/config ]] || die "tasks missing or config created"
  grep -qF "uses: test/runner/.github/workflows/claude-task-run.yml@$sha # v9.9.9" .github/workflows/claude-task.yml \
    || die "$(cat .github/workflows/claude-task.yml)"
  grep -q '@[A-Z_]*@' .github/workflows/claude-task.yml && die "unfilled placeholder"
  echo '# t' > .claude-task/tasks/x.md
  git check-ignore -q .claude-task/tasks/x.md || die "tasks not ignored"
  echo custom > .claude-task/validate.sh
  out="$("$runner/bin/submit-task" init 2>&1)"
  contains "$out" "kept     .claude-task/validate.sh"
  eq "$(cat .claude-task/validate.sh)" custom "init overwrote a file"
  cp "$runner/templates/validate.sh" "$SB/v.sh"
  fails "$SB/v.sh" 2>/dev/null
}

# --- workload identity federation ----------------------------------------------------------------

wif_repo() {
  sandbox
  printf 'ANTHROPIC_FEDERATION_RULE_ID=fdrl_test\nANTHROPIC_ORGANIZATION_ID=00000000-0000-0000-0000-000000000000\n' >> .claude-task/config
  git commit -qam wif && git push -q origin main
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
}

test_ci_wif() {
  wif_repo
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example/req?api-version=2" ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-token
  export CT_OIDC_REFRESH_SECONDS=1 FAKE_CLAUDE_SLEEP=2.5
  SETUP_EXTRA=env-probe pipeline > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed"; }
  grep -q "authenticating with workload identity federation" "$SB/log" || die "$(cat "$SB/log")"
  grep -qx rule=fdrl_test "$SB/claude-env" || die "$(cat "$SB/claude-env")"
  grep -qx org=00000000-0000-0000-0000-000000000000 "$SB/claude-env" || die "org not passed"
  grep -qx api_key= "$SB/claude-env" || die "API key secret leaked into a WIF run"
  grep -qx oidc_request= "$SB/claude-env" || die "Claude can see the OIDC request token"
  eq "$(cat "$SB/hook-env")" none "setup hook can see the OIDC request token"
  grep -qx jwt1=jwt-1 "$SB/claude-env" || die "$(cat "$SB/claude-env")"
  grep -qx jwt2=jwt-1 "$SB/claude-env" && die "token file was not refreshed"
  grep -q 'Authorization: Bearer req-token https://token.example/req?api-version=2&audience=https://api.anthropic.com' "$SB/curl.log" \
    || die "$(cat "$SB/curl.log")"
  grep -q jwt- "$SB/log" && die "token printed in the log"
  local token_file calls
  token_file="$(sed -n 's/^token_file=//p' "$SB/claude-env")"
  [[ ! -e $token_file ]] || die "token file left behind"
  calls="$(grep -c '' "$SB/curl.log")"
  sleep 2
  eq "$(grep -c '' "$SB/curl.log")" "$calls" "refresher still running"
  [[ -n $(git ls-remote origin refs/heads/task-t) ]] || die "not published"
}

test_ci_wif_misconfigured() {
  wif_repo
  local out
  unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
  out="$("$CI" claude 2>&1)" && die "ran without id-token permission"
  contains "$out" "needs 'id-token: write'"
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example/req?x=1" ACTIONS_ID_TOKEN_REQUEST_TOKEN=req-token
  out="$(GH_MOCK_FAIL=oidc "$CI" claude 2>&1)" && die "ran without an OIDC token"
  contains "$out" "couldn't get a GitHub OIDC token"
  sed -i '/ANTHROPIC_ORGANIZATION_ID/d' "$CT_CONF"
  out="$("$CI" claude 2>&1)" && die "ran without an organization"
  contains "$out" "needs ANTHROPIC_ORGANIZATION_ID"
  echo 'ANTHROPIC_ORGANIZATION_ID=$(id)' >> "$CT_CONF"
  out="$("$CI" claude 2>&1)" && die "accepted a bad id"
  contains "$out" "unexpected characters"
}

test_ci_requires_some_credential() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  local out
  out="$(env -u ANTHROPIC_API_KEY "$CI" claude 2>&1)" && die "ran without credentials"
  contains "$out" "or configure workload identity federation"
}

test_ci_setup_app() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  "$CI" setup-app > /dev/null
  grep -qx client_id= "$GITHUB_OUTPUT" || die "client ID set without config"
  : > "$GITHUB_OUTPUT"
  echo 'SETUP_GH_APP_CLIENT_ID=Iv23liAbC123' >> "$CT_CONF"
  "$CI" setup-app > /dev/null
  grep -qx client_id=Iv23liAbC123 "$GITHUB_OUTPUT" || die "$(cat "$GITHUB_OUTPUT")"
  local out
  echo 'SETUP_GH_APP_CLIENT_ID=x$(id)' >> "$CT_CONF"
  out="$("$CI" setup-app 2>&1)" && die "accepted a bad client ID"
  contains "$out" "unexpected characters"
}

# --- runner ------------------------------------------------------------------------------------

if [[ ${1-} == --one ]]; then
  "$2"
  exit
fi

mapfile -t tests < <(if [[ $# -gt 0 ]]; then printf '%s\n' "$@"; else declare -F | awk '$3 ~ /^test_/ { print $3 }'; fi)
failed=0
for t in "${tests[@]}"; do
  log="$(mktemp)"
  if "$0" --one "$t" > "$log" 2>&1; then
    echo "ok   $t"
  else
    echo "FAIL $t"
    sed 's/^/     /' "$log" | tail -n 40
    failed=$((failed + 1))
  fi
  rm -f "$log"
done
echo "${#tests[@]} tests, $failed failed"
[[ $failed -eq 0 ]]
