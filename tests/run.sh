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
  printf '/ignored\n*.log\n.env\nbuild/\n' > .gitignore
  echo a > a.txt; echo b > b.txt; echo c > c.txt; echo keep > keep.txt
  printf '#!/bin/sh\necho hi\n' > tool.sh
  ln -s a.txt link
  echo 'name: claude task' > .github/workflows/claude-task.yml
  printf 'PROTECTED_PATHS=guarded/\nCLAUDE_MAX_BUDGET_USD=1\nWORKTREE_LINKS=ignored\n' > .claude-task/config
  printf 'tasks/\nconfig.local\n' > .claude-task/.gitignore
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
  "run list")
    case "$*" in
      *conclusion*) printf '%s\n' "${GH_MOCK_RUNS-}" ;;
      *) echo "123 https://github.com/test/repo/actions/runs/123" ;;
    esac ;;
  "pr create") [[ ${GH_MOCK_FAIL-} == pr ]] && exit 1; echo "https://github.com/test/repo/pull/1" ;;
  "pr comment"|"pr edit"|"label create") exit 0 ;;
  "api users/"*)
    [[ ${GH_MOCK_FAIL-} == user ]] && exit 1
    login=${2#users/}
    printf '%s\t%s\n' "${login^}" "1+$login@users.noreply.github.com" ;;
  "pr list")
    case "$*" in
      *headRefName*) printf '%s\n' "${GH_MOCK_OPEN_BRANCHES-}" ;;
      *number,title,state*) printf '%s\n' "${GH_MOCK_PR-OPEN	12	fix the thing}" ;;
      *isCrossRepository*|*"--json url --jq"*) echo "${GH_MOCK_PR_URL-https://github.com/test/repo/pull/12}" ;;
    esac ;;
  "run download")
    while [[ $# -gt 0 && $1 != -D ]]; do shift; done
    cp "$GH_MOCK_ARTIFACT"/* "$2" ;;
esac
EOF
  chmod +x "$SB/bin/gh"
  # stands in for the interactive Claude Code that `continue` starts
  printf '#!/usr/bin/env bash\npwd > "$SB_CLAUDE_CWD"\nprintf "%%s" "$1" > "$SB_CLAUDE_MSG"\n' > "$SB/bin/claude"
  chmod +x "$SB/bin/claude"
  export SB_CLAUDE_CWD="$SB/claude-cwd" SB_CLAUDE_MSG="$SB/claude-msg" GH_MOCK_ARTIFACT="$SB/out"
}

# FAKE_CLAUDE: edit (default) | none | fail | error-result | protected | hook | secret | retry | break
#   | servers | submodule-edit | submodule-move
# retry breaks validation in the first session and fixes it once resumed; break always breaks it;
# servers leaves a child process and a detached listener on $SB_PORT running
install_claude_mock() {
  cat > "$SB/bin/fake-claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat > "$PWD/../claude-stdin"
printf '%s\n' "$@" > "$PWD/../claude-args"
echo "$*" >> "$PWD/../claude-calls"
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
result() {
  jq -nc --arg subtype "$1" --argjson is_error "$2" --arg report "${FAKE_REPORT-$DEFAULT_REPORT}" \
    '{type: "result", subtype: $subtype, is_error: $is_error, result: $report, num_turns: 2, session_id: "sess-1",
      total_cost_usd: 3.4, duration_ms: 872000, duration_api_ms: 725000,
      usage: {input_tokens: 1000, cache_read_input_tokens: 1900000, cache_creation_input_tokens: 99000, output_tokens: 38500},
      modelUsage: {"claude-haiku": {costUSD: 0.1}, "claude-opus": {costUSD: 3.3}}}'
}
DEFAULT_REPORT='Commit: change a; add src/new

## Summary
Depends-on: test/other#1
report

## Design
```mermaid
flowchart LR
  a --> b
```

## Files changed
- `a.txt`: append a | line
- `./src/new.txt` — new file

## Tests run
none
<!-- handoff -->
## State
handoff body'

case "${FAKE_CLAUDE:-edit}" in
  edit) echo "changed by claude" >> a.txt; mkdir -p src; echo new > src/new.txt; rm -f c.txt ;;
  none) ;;
  fail) exit 1 ;;
  error-result) result error_max_budget_usd true; exit 0 ;;
  protected) echo x > .github/workflows/evil.yml ;;
  hook) echo 'exit 0' > .claude-task/validate.sh ;;
  secret) printf 'key=%s%s\n' AKIA ABCDEFGHIJKLMNOP > leaked.txt ;;
  retry) if [[ " $* " == *" --resume sess-1 "* ]]; then echo fixed > a.txt; else : > a.txt; fi ;;
  break) : > a.txt ;;
  submodule-edit) echo edited > lib/lib.txt ;;
  submodule-move) git -C lib commit -q --allow-empty -m moved ;;
  servers)
    sleep 300 > /dev/null 2>&1 &
    echo $! > "$PWD/../claude-child"
    setsid python3 -m http.server --bind 127.0.0.1 "$SB_PORT" > /dev/null 2>&1 &
    for _ in $(seq 50); do ss -Hltn "sport = :$SB_PORT" | grep -q . && break; sleep 0.1; done ;;
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
  export GITHUB_REF=refs/heads/main GITHUB_REPOSITORY=test/repo GITHUB_RUN_ID=1 GITHUB_TRIGGERING_ACTOR=octo
  export GITHUB_OUTPUT="$SB/gh-output" GITHUB_STEP_SUMMARY="$SB/summary"
  export CLAUDE_BIN=fake-claude ANTHROPIC_API_KEY=dummy
  rm -rf "$CT_WORK"
  git clone -q --depth 2 --branch "$CT_SNAPSHOT_REF" "file://$SB/remote.git" "$CT_WORK"
}

# the run job's steps in workflow order, then the publish job in a fresh checkout
pipeline() {
  "$CI" inputs && "$CI" verify && "$CI" hook setup && "$CI" claude || return 1
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
  contains "$out" "submit new tasks from 'main', or follow-ups from a 'task-<name>' task branch"
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

test_nested_repos_and_lfs_rejected() {
  sandbox
  echo x > tasks/t.md
  git init -q vendor/sub && git -C vendor/sub commit -q --allow-empty -m x
  local out
  out="$("$SUBMIT" --yes tasks/t.md 2>&1)" && die "nested repo accepted"
  contains "$out" "nested git repositories (above) that .gitmodules doesn't declare"
  rm -rf vendor
  echo '*.bin filter=lfs diff=lfs merge=lfs -text' > .gitattributes && echo x > a.bin
  out="$("$SUBMIT" --yes tasks/t.md 2>&1)" && die "lfs accepted"
  contains "$out" "Git LFS"
  eq "$(snap)" ""
}

# adds the submodule lib (cloned from $SB/lib-remote) to main and pushes it
submodule_repo() {
  sandbox
  git config --global protocol.file.allow always
  git init -q "$SB/lib-remote"
  echo v1 > "$SB/lib-remote/lib.txt"
  git -C "$SB/lib-remote" add -A && git -C "$SB/lib-remote" commit -qm v1
  git submodule add -q "$SB/lib-remote" lib
  printf '#!/usr/bin/env bash\nset -euo pipefail\ngit submodule update --init\nmkdir -p build && echo setup > build/setup.out\n${SETUP_EXTRA:-true}\n' > .claude-task/setup.sh
  git add -A && git commit -qm "add lib" && git push -q origin main
  git fetch -q origin
}

test_submodule_pins_checked_against_base() {
  submodule_repo
  echo x > tasks/t.md
  local out base
  base="$(git -C lib rev-parse HEAD)"
  submit tasks/t.md a || die "pin equal to the base branch's rejected"

  echo v2 > lib/lib.txt && git -C lib commit -qam v2
  out="$("$SUBMIT" --yes tasks/t.md b 2>&1)" || die "$out"
  contains "$out" "isn't on any of its remote branches"
  eq "$(git ls-tree "$(sed -n 's/^snapshot: *\([0-9a-f]*\).*/\1/p' <<< "$out")" lib | awk '{ print $3 }')" \
    "$(git -C lib rev-parse HEAD)" "snapshot pin"

  echo dirty > lib/lib.txt
  out="$("$SUBMIT" --yes tasks/t.md c 2>&1)" && die "dirty submodule accepted"
  contains "$out" "lib: uncommitted changes"
  git -C lib checkout -q lib.txt

  git -C lib checkout -q --orphan other && git -C lib commit -qm unrelated
  out="$("$SUBMIT" --yes tasks/t.md c 2>&1)" && die "unrelated pin accepted"
  contains "$out" "lib: at $(git -C lib rev-parse --short=12 HEAD), which doesn't descend from ${base:0:12} on main"

  git -C lib checkout -q "$base"
  git submodule add -q "$SB/lib-remote" lib2
  out="$("$SUBMIT" --yes tasks/t.md c 2>&1)" && die "new submodule accepted"
  contains "$out" "lib2: not a submodule on main yet"
}

test_submodule_unusual_path_and_uninitialized() {
  submodule_repo
  echo x > tasks/t.md
  local out
  git submodule add -q "$SB/lib-remote" "sub é"
  git commit -qm "add sub é" && git push -q origin main && git fetch -q origin
  submit tasks/t.md a || die "a submodule path that ls-tree quotes rejected"

  echo v2 > "$SB/lib-remote/lib.txt" && git -C "$SB/lib-remote" commit -qam v2
  git update-index --cacheinfo "160000,$(git -C "$SB/lib-remote" rev-parse HEAD),lib"
  git commit -qm "move lib" && git submodule -q deinit -f lib
  out="$("$SUBMIT" --yes tasks/t.md b 2>&1)" && die "unchecked pin accepted"
  contains "$out" "lib: moved to $(git -C "$SB/lib-remote" rev-parse --short=12 HEAD) but not checked out"
  contains "$out" "run 'git submodule update --init -- lib'"
}

test_ci_submodules() {
  submodule_repo
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  pipeline > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed"; }
  git fetch -q origin task-t
  eq "$(git ls-tree FETCH_HEAD lib | awk '{ print $3 }')" "$(git -C lib rev-parse HEAD)" "result pin"
  eq "$(git diff --name-only "$SNAP_SHA" FETCH_HEAD | sort | tr '\n' ' ')" "a.txt c.txt src/new.txt tasks/t.md " "result changes"

  submit tasks/t.md u
  ci_env
  "$CI" inputs && "$CI" verify && "$CI" hook setup > "$SB/log" 2>&1 || { cat "$SB/log"; die "setup failed"; }
  [[ -f $CT_WORK/lib/lib.txt ]] || die "setup didn't fetch the submodule"
  out="$(FAKE_CLAUDE=submodule-edit "$CI" claude 2>&1)" && die "accepted an edit inside a submodule"
  contains "$out" "files inside submodules (above) changed"
  git -C "$CT_WORK/lib" checkout -q lib.txt
  out="$(FAKE_CLAUDE=submodule-move "$CI" claude 2>&1)" && die "accepted a moved submodule"
  contains "$out" "submodule pins changed"
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
  grep -q "^pr create --repo test/repo --base main --head task-t --title change a; add src/new --body-file" "$GH_LOG" || die "$(cat "$GH_LOG")"
  eq "$(git log -1 --format=%s "$tip")" "change a; add src/new" "commit subject"
  grep -q "^Task: $TASK_ID\$" <<< "$(git log -1 --format=%b "$tip")" || die "commit body lacks task id"
  eq "$(git log -1 --format=%b "$tip" | head -1)" "report" "commit body opens with the summary"
  grep -q "$SNAP_SHA" "$SB/out/pr-body.md" || die "PR body lacks snapshot sha"
  grep -q "$TASK_ID" "$SB/out/pr-body.md" || die "PR body lacks task id"
  grep -q '^## Summary' "$SB/out/pr-body.md" || die "PR body lacks Claude's report"
  [[ $(grep -n -m1 '^## Summary' "$SB/out/pr-body.md" | cut -d: -f1) -lt $(grep -n -m1 'Run details' "$SB/out/pr-body.md" | cut -d: -f1) ]] \
    || die "report isn't above the run details"
  grep -qx '```mermaid' "$SB/out/pr-body.md" || die "PR body lacks the design diagram"
  grep -q '^Commit:' "$SB/out/pr-body.md" && die "PR body keeps the Commit line"
  grep -qx 'Do the thing.' "$SB/out/pr-body.md" || die "PR body lacks the prompt"
  grep -qx '````' "$SB/out/pr-body.md" || die "prompt fence not longer than its backtick runs"
  eq "$(snap)" "" "snapshot ref not cleaned up"

  eq "$(git log -1 --format='%an <%ae>' "$SNAP_SHA")" "tester <tester@example.com>" "snapshot author"
  eq "$(git log -1 --format='%an <%ae>' "$tip")" "Octo <1+octo@users.noreply.github.com>" "commit author"
  eq "$(git log -1 --format='%cn <%ce>' "$tip")" \
    "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>" "committer"
  grep -qx 'Requested by @octo.' "$SB/out/pr-body.md" || die "PR body lacks the requester"
  eq "$(tail -n 4 "$SB/out/pr-body.md")" "$(git log -1 --format='%(trailers:only,unfold)' "$tip" | head -n 4)" "PR body trailers"
  grep -q "^pr edit https://github.com/test/repo/pull/1 --repo test/repo --add-label claude-task$" "$GH_LOG" || die "$(cat "$GH_LOG")"
  grep -q "^pr edit https://github.com/test/repo/pull/1 --repo test/repo --add-assignee octo$" "$GH_LOG" || die "$(cat "$GH_LOG")"
}

test_ci_publish_identities() {
  # a failed lookup of the requester pushes nothing
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  GH_MOCK_FAIL=user pipeline > "$SB/log" 2>&1 && die "published without the requester's identity"
  contains "$(cat "$SB/log")" "looking up octo failed; nothing was pushed"
  eq "$(git ls-remote origin refs/heads/task-t)" "" "pushed anyway"
  [[ -n $(snap) ]] || die "snapshot removed"

  ci_env
  GITHUB_TRIGGERING_ACTOR= fails "$CI" publish 2>/dev/null
}

test_ci_missing_commit_line_uses_default() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  FAKE_REPORT=$'## Summary\nno commit line' pipeline > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed"; }
  grep -q "doesn't start with a 'Commit: <message>' line; publishing as 'claude task t'" "$SB/log" || die "$(cat "$SB/log")"
  git fetch -q origin task-t
  eq "$(git log -1 --format=%s FETCH_HEAD)" "claude task t" "fallback subject"
  grep -q -- "--title claude task t" "$GH_LOG" || die "PR title: $(grep 'pr create' "$GH_LOG")"
  grep -q '^## Summary' "$SB/out/pr-body.md" || die "report dropped from the PR body"
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
  echo 'CLAUDE_MAX_BUDGET_USD=20' >> .claude-task/config && git commit -qam budget && git push -q origin main
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  FAKE_CLAUDE=break pipeline > "$SB/log" 2>&1 && die "pipeline passed"
  grep -q "validate hook .claude-task/validate.sh failed after 3 attempt(s)" "$SB/log" || die "$(cat "$SB/log")"
  eq "$(grep -c '' "$SB/claude-calls")" 3 "Claude sessions"
  eq "$(git ls-remote origin refs/heads/task-t)" ""
  [[ -n $(snap) ]] || die "snapshot removed after failure"

  ci_env
  rm "$SB/claude-calls"
  echo 'VALIDATE_RETRIES=0' >> "$CT_CONF"
  FAKE_CLAUDE=break pipeline > "$SB/log" 2>&1 && die "pipeline passed"
  grep -q "failed after 1 attempt(s)" "$SB/log" || die "$(cat "$SB/log")"
  eq "$(grep -c '' "$SB/claude-calls")" 1 "Claude sessions without retries"
}

test_ci_validation_retry() {
  sandbox
  echo 'CLAUDE_MAX_BUDGET_USD=20' >> .claude-task/config && git commit -qam budget && git push -q origin main
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  printf '#!/usr/bin/env bash\necho "probe api_key=${ANTHROPIC_API_KEY-}"\n' > "$SB/bin/key-probe"
  chmod +x "$SB/bin/key-probe"
  FAKE_CLAUDE=retry VALIDATE_EXTRA=key-probe pipeline > "$SB/log" 2>&1 \
    || { cat "$SB/log"; die "pipeline failed"; }
  eq "$(grep -c '' "$SB/claude-calls")" 2 "Claude sessions"
  grep -q -- "--max-budget-usd 20$" "$SB/claude-calls" || die "first budget: $(cat "$SB/claude-calls")"
  grep -q -- "--max-budget-usd 16.60 --resume sess-1$" "$SB/claude-calls" || die "resume: $(cat "$SB/claude-calls")"
  contains "$(cat "$SB/claude-stdin")" "The runner ran \`.claude-task/validate.sh\` on your changes and it failed"
  grep -q "resuming Claude's session" "$SB/log" || die "$(cat "$SB/log")"
  grep -qx 'probe api_key=' "$SB/out/validate.log" || die "validation sees the Anthropic key: $(cat "$SB/out/validate.log")"
  git fetch -q origin task-t
  eq "$(git show FETCH_HEAD:a.txt)" fixed "the fixed attempt is published"
  local body
  body="$(cat "$SB/out/pr-body.md")"
  contains "$body" '| Validation | `.claude-task/validate.sh` passed (attempt 2) |'
  grep -qE '^<sub>29m 4s \(24m 10s API\) · 4 turns · 2 attempts · 4M in \(95% cached\) / 77k out · \$6\.80 · claude-opus · ' <<< "$body" \
    || die "telemetry: $(tail -n 1 <<< "$body")"
}

test_ci_validation_retry_budget() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  FAKE_CLAUDE=retry pipeline > "$SB/log" 2>&1 && die "pipeline passed"
  grep -q 'validation failed and the \$1 budget is spent' "$SB/log" || die "$(cat "$SB/log")"
  eq "$(grep -c '' "$SB/claude-calls")" 1 "Claude sessions"
}

test_ci_validation_must_not_change_tree() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  VALIDATE_EXTRA="touch stray.txt" pipeline > "$SB/log" 2>&1 && die "pipeline passed"
  grep -q "validation changed tracked or unignored files" "$SB/log" || die "$(cat "$SB/log")"
}

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

test_ci_stray_processes_killed() {
  sandbox
  export SB_PORT
  SB_PORT="$(free_port)"
  echo "VALIDATE_PORTS=$SB_PORT" >> .claude-task/config && git commit -qam ports && git push -q origin main
  # validate.sh fails if Claude's leftovers survive, and leaves a process holding its output
  cat > "$SB/bin/stray-probe" <<'EOF2'
#!/usr/bin/env bash
! ss -Hltn "sport = :$SB_PORT" | grep -q . || { echo "port $SB_PORT still taken"; exit 1; }
! kill -0 "$(cat "$SB/claude-child")" 2>/dev/null || { echo "claude's child survived"; exit 1; }
sleep 300 &
echo $! > "$SB/validate-child"
EOF2
  chmod +x "$SB/bin/stray-probe"
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  FAKE_CLAUDE=servers VALIDATE_EXTRA=stray-probe CI=$CI SB=$SB \
    timeout 60 bash -c "$(declare -f pipeline); pipeline" \
    > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed"; }
  grep -q "port $SB_PORT is in use; killing" "$SB/log" || die "$(cat "$SB/log")"
  ! kill -0 "$(cat "$SB/validate-child")" 2>/dev/null || die "validate's child survived"

  submit tasks/t.md
  ci_env
  echo 'VALIDATE_PORTS=80 http' >> "$CT_CONF"
  out="$("$CI" claude 2>&1)" && die "accepted a bad port"
  contains "$out" "VALIDATE_PORTS in .claude-task/config must list TCP port numbers, got: http"
}

# ss reports a listener on every port: with $SS_MOCK_PID as its pid, else without one
install_ss_mock() {
  cat > "$SB/bin/ss" <<'EOF2'
#!/usr/bin/env bash
printf 'LISTEN 0 4096 127.0.0.1:9 0.0.0.0:*%s\n' "${SS_MOCK_PID:+ users:((\"sleep\",pid=$SS_MOCK_PID,fd=3))}"
EOF2
  chmod +x "$SB/bin/ss"
}

test_ci_port_checks() {
  sandbox
  local out port
  port="$(free_port)"
  echo "VALIDATE_PORTS=$port" >> .claude-task/config && git commit -qam ports && git push -q origin main
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  pipeline > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed with nothing listening"; }

  submit tasks/t.md u
  ci_env
  install_ss_mock
  out="$(pipeline 2>&1)" && die "passed with an unkillable listener"
  contains "$out" "port $port is in use by a process the runner can't see or kill"

  submit tasks/t.md v
  ci_env
  sleep 300 &
  export SS_MOCK_PID=$!
  out="$(pipeline 2>&1)" && die "passed with a listener that stays"
  contains "$out" "port $port is still in use 5s after killing pid(s) $SS_MOCK_PID"
  { wait "$SS_MOCK_PID"; } 2>/dev/null && die "listener not killed"
  unset SS_MOCK_PID
  rm "$SB/bin/ss"

  # every command on PATH but ss
  local dir f
  mkdir "$SB/no-ss"
  IFS=: read -ra dirs <<< "$PATH"
  for dir in "${dirs[@]}"; do
    for f in "$dir"/*; do
      [[ -x $f && ${f##*/} != ss && ! -e $SB/no-ss/${f##*/} ]] && ln -s "$f" "$SB/no-ss/${f##*/}"
    done
  done
  submit tasks/t.md w
  ci_env
  "$CI" inputs && "$CI" verify && "$CI" hook setup > "$SB/log" 2>&1 || { cat "$SB/log"; die "setup failed"; }
  rm -f "$SB/claude-calls"
  out="$(PATH="$SB/no-ss" "$CI" claude 2>&1)" && die "ran without ss"
  contains "$out" "VALIDATE_PORTS needs ss (iproute2) on the runner"
  [[ ! -e $SB/claude-calls ]] || die "Claude ran before the missing ss was caught"
}

test_ci_validate_artifacts_saved() {
  sandbox
  printf 'VALIDATE_RETRIES=1\nCLAUDE_MAX_BUDGET_USD=20\nVALIDATE_ARTIFACTS=build/results/ **/*.trace missing/ build/out/* build/proc/ .gi?/* build/nl/*\n' >> .claude-task/config
  git commit -qam artifacts && git push -q origin main
  mkdir -p "$SB/outside" && echo secret > "$SB/outside/secret.txt"
  export SB
  cat > "$SB/bin/results-probe" <<'EOF2'
#!/usr/bin/env bash
mkdir -p build/results/sub build/deep
echo "attempt" >> build/results/sub/report.txt
echo trace > build/deep/x.trace
ln -sf /etc/hostname build/results/escape
ln -sfn "$SB/outside" build/out
ln -sfn /proc/self build/proc
ln -sfn "$SB/outside" build/results/dir
# a regular file whose name is a symlink's plus a newline
mkdir -p build/nl
ln -sfn /etc/hostname build/nl/evil
echo x > build/nl/evil$'\n'
echo "probe ran"
exit 1
EOF2
  chmod +x "$SB/bin/results-probe"
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  VALIDATE_EXTRA=results-probe pipeline > "$SB/log" 2>&1 && die "pipeline passed"
  local r="$SB/out/validate-results"
  grep -q "saved 2 file(s) from VALIDATE_ARTIFACTS for attempt 2" "$SB/log" || die "$(cat "$SB/log")"
  [[ -f $r/attempt-1/build/results/sub/report.txt && -f $r/attempt-2/build/deep/x.trace ]] \
    || die "missing results: $(find "$r")"
  [[ ! -e $r/attempt-1/build/results/escape ]] || die "followed a symlink"
  eq "$(cd "$r" && find . -type f | LC_ALL=C sort | tr '\n' ' ')" \
    "./attempt-1.log ./attempt-1/build/deep/x.trace ./attempt-1/build/results/sub/report.txt ./attempt-2.log ./attempt-2/build/deep/x.trace ./attempt-2/build/results/sub/report.txt " \
    "saved files"
  grep -q "skipped build/out/secret.txt, which is in .git or leads outside the checkout" "$SB/log" || die "$(cat "$SB/log")"
  grep -q "skipped .git/config" "$SB/log" || die "$(cat "$SB/log")"
  grep -q "probe ran" "$r/attempt-1.log" || die "attempt log missing"

  submit tasks/t.md u
  ci_env
  rm -rf "$SB/out/validate-results"
  CT_ARTIFACTS_MAX_BYTES=10 VALIDATE_EXTRA=results-probe pipeline > "$SB/log" 2>&1 && die "pipeline passed"
  grep -q "VALIDATE_ARTIFACTS for attempt 1 exceed 10 bytes; not copying build/deep/x.trace" "$SB/log" || die "$(cat "$SB/log")"
  [[ -f $r/attempt-1/build/results/sub/report.txt && ! -e $r/attempt-1/build/deep ]] || die "size limit: $(find "$r")"

  submit tasks/t.md
  ci_env
  echo 'VALIDATE_ARTIFACTS=build/../../etc' >> "$CT_CONF"
  out="$("$CI" claude 2>&1)" && die "accepted a pattern outside the checkout"
  contains "$out" "VALIDATE_ARTIFACTS in .claude-task/config can't contain '.git' or '..': build/../../etc"
}

test_ci_validate_artifacts_many_files() {
  sandbox
  printf 'VALIDATE_RETRIES=0\nVALIDATE_ARTIFACTS=build/many/\n' >> .claude-task/config
  git commit -qam artifacts && git push -q origin main
  printf '#!/usr/bin/env bash\nmkdir -p build/many\ncd build/many && seq 3000 | xargs touch\nexit 1\n' > "$SB/bin/many-probe"
  chmod +x "$SB/bin/many-probe"
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  local start=$SECONDS
  VALIDATE_EXTRA=many-probe pipeline > "$SB/log" 2>&1 && die "pipeline passed"
  grep -q "saved 3000 file(s) from VALIDATE_ARTIFACTS for attempt 1" "$SB/log" || die "$(cat "$SB/log")"
  (( SECONDS - start < 15 )) || die "saving 3000 files took $((SECONDS - start))s"
}

# fails (exit 7) its first $FLAKY_FAILS runs, counted in $SB/flaky-count
install_flaky() {
  cat > "$SB/bin/flaky" <<'EOF2'
#!/usr/bin/env bash
n=$(( $(cat "$SB/flaky-count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$SB/flaky-count"
[[ $n -gt ${FLAKY_FAILS:-0} ]] || { echo "HTTP 504"; exit 7; }
EOF2
  chmod +x "$SB/bin/flaky"
  export SB
}

test_retry_helper() {
  sandbox
  install_flaky
  local out
  out="$(FLAKY_FAILS=2 "$LIB/retry.sh" -n 3 -d 0 -- flaky 2>&1)" || die "$out"
  contains "$out" "retry: flaky failed (exit 7); attempt 3 of 3 in 0s"
  eq "$(cat "$SB/flaky-count")" 3 "runs"
  rm "$SB/flaky-count"
  out="$(FLAKY_FAILS=5 "$LIB/retry.sh" -n 2 -d 0 flaky 2>&1)" && die "succeeded"
  contains "$out" "retry: flaky failed (exit 7) after 2 attempt(s)"
  FLAKY_FAILS=5 "$LIB/retry.sh" -n 1 -d 0 flaky > /dev/null 2>&1 || eq "$?" 7 "exit status"
  fails "$LIB/retry.sh" -n 0 true 2>/dev/null
  out="$("$LIB/retry.sh" true -n 2>&1)" || die "$out"
  out="$("$LIB/retry.sh" -n 2>&1)" && die "accepted -n without a value"
  contains "$out" "retry: -n needs a value"
  out="$("$LIB/retry.sh" -n 2 -d 2>&1)" && die "accepted -d without a value"
  contains "$out" "retry: -d needs a value"
  out="$("$LIB/retry.sh" -d 08 true 2>&1)" && die "accepted a delay with a leading zero"
  contains "$out" "retry: delay must be a whole number of seconds: 08"
  # the action's step script, labelled with the first non-blank line of its run input
  sed -n '/^      run: |$/,$p' "$HERE/../actions/retry/action.yml" | tail -n +2 > "$SB/action.sh"
  out="$(GITHUB_ACTION_PATH="$HERE/../actions/retry" CT_RETRY_ATTEMPTS=1 CT_RETRY_DELAY=0 \
    CT_RETRY_RUN=$'\n  \n  FLAKY_FAILS=5 flaky\ntrue' bash -e "$SB/action.sh" 2>&1)" && die "action succeeded"
  contains "$out" "retry: FLAKY_FAILS=5 flaky failed (exit 7) after 1 attempt(s)"

  # the whole command, or the label, is logged; delays double up to 300s
  printf '#!/bin/sh\necho "$1" >> "$SB/sleeps"\n' > "$SB/bin/sleep" && chmod +x "$SB/bin/sleep"
  rm "$SB/flaky-count"
  out="$(FLAKY_FAILS=5 "$LIB/retry.sh" -n 2 -d 0 env A=1 flaky 2>&1)" && die "succeeded"
  contains "$out" "retry: env A=1 flaky failed (exit 7); attempt 2 of 2"
  rm "$SB/flaky-count" "$SB/sleeps"
  out="$(FLAKY_FAILS=5 "$LIB/retry.sh" -n 4 -d 200 -l setup.sh -- env A=1 flaky 2>&1)" && die "succeeded"
  contains "$out" "retry: setup.sh failed (exit 7) after 4 attempt(s)"
  eq "$(tr '\n' ' ' < "$SB/sleeps")" "200 300 300 " "delays"
}

test_ci_setup_retried() {
  sandbox
  install_flaky
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  export CT_SETUP_RETRY_DELAY=0
  FLAKY_FAILS=1 SETUP_EXTRA=flaky pipeline > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed"; }
  grep -q "retry: .claude-task/setup.sh failed (exit 7); attempt 2 of 2" "$SB/log" || die "$(cat "$SB/log")"

  submit tasks/t.md u
  ci_env
  rm "$SB/flaky-count"
  echo 'SETUP_ATTEMPTS=1' >> "$CT_CONF"
  FLAKY_FAILS=1 SETUP_EXTRA=flaky "$CI" hook setup > "$SB/log" 2>&1 && die "setup passed"
  grep -q "setup hook .claude-task/setup.sh failed" "$SB/log" || die "$(cat "$SB/log")"
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
  "$CI" verify && "$CI" hook setup && "$CI" claude > /dev/null 2>&1
  sed -i 's/^+changed by claude$/+something else/' "$SB/out/changes.patch"
  rm -rf "$SB/pub"
  git clone -q --depth 2 --branch "$CT_SNAPSHOT_REF" "file://$SB/remote.git" "$SB/pub"
  local out
  out="$(CT_WORK="$SB/pub" "$CI" publish 2>&1)" && die "tampered patch published"
  contains "$out" "doesn't reproduce the validated tree"
}

test_ci_files_table_handoff_telemetry() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  pipeline > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed"; }
  local body
  body="$(cat "$SB/out/pr-body.md")"
  contains "$body" '| `a.txt` | +1 −0 | append a \| line |'
  contains "$body" '| `src/new.txt` | +1 −0 (new) | new file |'
  contains "$body" '| `c.txt` | +0 −1 (deleted) | ⚠ no note from Claude |'
  grep -q '^| `tasks/t.md`' <<< "$body" && die "dropped prompt listed in the table"
  grep -q '^## Files changed' <<< "$body" && die "Files changed section kept next to the table"
  grep -q '^## Tests run' <<< "$body" || die "report sections after Files changed dropped"
  eq "$(cat "$SB/out/handoff.md")" $'## State\nhandoff body' "handoff split"
  grep -q 'handoff -->' "$SB/out/claude-report.md" && die "marker left in the report"
  contains "$body" "<details><summary>Handoff notes</summary>"
  grep -qE '^<sub>14m 32s \(12m 5s API\) · 2 turns · 2M in \(95% cached\) / 38k out · \$3\.40 · claude-opus · setup [0-9]+s · validate [0-9]+s</sub>$' <<< "$body" \
    || die "telemetry: $(tail -n 1 <<< "$body")"

  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  unset ANTHROPIC_API_KEY
  export CLAUDE_CODE_OAUTH_TOKEN=dummy
  FAKE_REPORT=$'Commit: x\n\n## Files changed\nfree-form prose' pipeline > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed"; }
  body="$(cat "$SB/out/pr-body.md")"
  contains "$body" '$3.40 API-equiv (subscription)'
  contains "$body" 'free-form prose'
  contains "$body" '| `a.txt` | +1 −0 | ⚠ no note from Claude |'
  grep -q 'Handoff notes' <<< "$body" && die "empty handoff shown"
  [[ -e $SB/out/handoff.md && ! -s $SB/out/handoff.md ]] || die "handoff.md missing or not empty"
}

# a published task-t with its result branch checked out locally
published_task() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  pipeline > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed"; }
  : > "$GH_LOG"
  git fetch -q origin task-t
  git checkout -q task-t
}

test_followup_submit_and_publish() {
  published_task
  local tip
  tip="$(git rev-parse HEAD)"
  echo "my tweak" >> b.txt
  echo 'follow up' > tasks/f.md
  submit tasks/f.md
  contains "$OUT" 'follow-up on task-t → adds a commit to PR #12 "fix the thing"'
  contains "$OUT" "base:     $tip (task-t, in sync with origin)"
  [[ $TASK_ID == t-* ]] || die "task id $TASK_ID"
  grep -q -- "-f task_name=t -f task_id=$TASK_ID -f followup=true$" "$GH_LOG" || die "$(cat "$GH_LOG")"

  ci_env tasks/f.md
  export CT_FOLLOWUP=true
  pipeline > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed"; }
  local new
  new="$(git ls-remote origin refs/heads/task-t | cut -f1)"
  git fetch -q origin task-t
  eq "$(git rev-parse "$new^")" "$SNAP_SHA" "follow-up commit's parent"
  eq "$(git rev-parse "$SNAP_SHA^")" "$tip" "snapshot's parent"
  grep -q "^pr comment https://github.com/test/repo/pull/12 --repo test/repo --body-file" "$GH_LOG" || die "$(cat "$GH_LOG")"
  grep -q "^pr create" "$GH_LOG" && die "opened a second PR"
  contains "$(cat "$SB/out/pr-body.md")" "### Follow-up task \`$TASK_ID\`"
  grep -qx 'Requested by @octo.' "$SB/out/pr-body.md" || die "comment lacks the requester"
  grep -q '^Task: ' "$SB/out/pr-body.md" && die "comment repeats the trailers"
  grep -q "^pr edit" "$GH_LOG" && die "follow-up relabelled the PR"
  eq "$(snap)" "" "snapshot not cleaned up"
}

test_followup_ahead_warns() {
  published_task
  echo local > d.txt && git add d.txt && git commit -qm local
  echo 'follow up' > tasks/f.md
  submit tasks/f.md
  contains "$OUT" "1 commit(s) ahead of origin"
  contains "$OUT" "HEAD has commits not on origin/task-t"
}

test_followup_refusals() {
  published_task
  echo 'follow up' > tasks/f.md
  local out
  out="$("$SUBMIT" --yes tasks/f.md other 2>&1)" && die "accepted another task name"
  contains "$out" "keeps its branch's task name 't'"
  out="$(GH_MOCK_PR=$'MERGED\t12\tx' "$SUBMIT" --yes tasks/f.md 2>&1)" && die "submitted to a merged PR"
  contains "$out" "PR #12 for 'task-t' is merged"
  out="$(GH_MOCK_PR= "$SUBMIT" --yes tasks/f.md 2>&1)" && die "submitted without a PR"
  contains "$out" "'task-t' has no PR into main"
  git push -q origin "$(git commit-tree "HEAD^{tree}" -p HEAD -m remote):refs/heads/task-t"
  out="$("$SUBMIT" --yes tasks/f.md 2>&1)" && die "submitted behind the remote"
  contains "$out" "origin/task-t has commits this branch doesn't"
  git checkout -qb task-gone
  out="$("$SUBMIT" --yes tasks/f.md 2>&1)" && die "submitted from an unpublished branch"
  contains "$out" "'task-gone' isn't on origin"
  eq "$(snap)" "" "nothing pushed"
}

test_followup_publish_never_rewrites() {
  published_task
  echo 'follow up' > tasks/f.md
  submit tasks/f.md
  ci_env tasks/f.md
  export CT_FOLLOWUP=true
  local moved
  moved="$(git commit-tree "HEAD^{tree}" -p HEAD -m elsewhere)"
  git push -q origin "$moved:refs/heads/task-t"
  pipeline > "$SB/log" 2>&1 && die "published over a moved branch"
  grep -q "it has commits the snapshot doesn't include" "$SB/log" || die "$(cat "$SB/log")"
  eq "$(git ls-remote origin refs/heads/task-t | cut -f1)" "$moved" "branch rewritten"
  [[ -n $(snap) ]] || die "snapshot removed"

  ci_env tasks/f.md
  GH_MOCK_PR_URL= pipeline > "$SB/log" 2>&1 && die "published without an open PR"
  grep -q "task-t has no open PR into main" "$SB/log" || die "$(cat "$SB/log")"
}

test_continue() {
  published_task
  git checkout -q main
  # info/exclude is shared by all worktrees, unlike a commit on main
  echo .claude-task/handoff/ >> .git/info/exclude
  local id=$TASK_ID out
  echo dirty >> a.txt
  out="$("$SUBMIT" continue "$id" 2>&1)" && die "continued over a dirty tree"
  contains "$out" "rerun with --worktree"
  eq "$(git symbolic-ref --short HEAD)" main

  mkdir -p ignored && echo state > ignored/state
  out="$("$SUBMIT" --worktree continue "$id" 2>&1)" || die "$out"
  local wt="$REPO-task-t"
  eq "$(readlink "$wt/ignored")" "$REPO/ignored" "worktree link without the hook"
  eq "$(git -C "$wt" symbolic-ref --short HEAD)" task-t
  eq "$(git -C "$wt" rev-parse HEAD)" "$(git ls-remote origin refs/heads/task-t | cut -f1)" "worktree tip"
  eq "$(cat "$wt/.claude-task/handoff/$id.md")" $'## State\nhandoff body' "handoff notes"
  eq "$(cat "$SB_CLAUDE_CWD")" "$wt" "claude cwd"
  contains "$(cat "$SB_CLAUDE_MSG")" ".claude-task/handoff/$id.md"
  contains "$(cat "$SB_CLAUDE_MSG")" "PR https://github.com/test/repo/pull/12"
  eq "$(git -C "$wt" status --porcelain)" "" "handoff not ignored"
  eq "$(ls -A "$TMPDIR")" "" "temp files left behind"

  git checkout -q a.txt
  git worktree remove "$wt"
  out="$("$SUBMIT" continue "$id" 2>&1)" || die "$out"
  eq "$(git symbolic-ref --short HEAD)" task-t
  eq "$(cat "$SB_CLAUDE_CWD")" "$REPO" "claude cwd"
  [[ -s .claude-task/handoff/$id.md ]] || die "no handoff in the checkout"

  # the hook skips setup when submit-task isn't on PATH, so continue has to do it
  git checkout -q main
  install -m755 "$HERE/../templates/post-checkout" .git/hooks/post-checkout
  local d path=""
  IFS=: read -ra dirs <<< "$PATH"
  for d in "${dirs[@]}"; do [[ -x $d/submit-task ]] || path+="${path:+:}$d"; done
  out="$(PATH=$path "$SUBMIT" --worktree continue "$id" 2>&1)" || die "$out"
  contains "$out" "submit-task isn't on PATH"
  eq "$(readlink "$wt/ignored")" "$REPO/ignored" "worktree link with a hook that can't run"
}

test_worktree_setup() {
  sandbox
  printf 'WORKTREE_LINKS=ignored/state build/ tool.sh missing\n' >> .claude-task/config
  printf '#!/usr/bin/env bash\necho "$CT_MAIN_WORKTREE $PWD" >> "$SB_WT_LOG"\n' > .claude-task/worktree.sh
  chmod +x .claude-task/worktree.sh
  git add -A && git commit -qm worktrees
  mkdir -p ignored/state build && echo s > ignored/state/s
  export SB_WT_LOG="$SB/wt-log"
  install -m755 "$HERE/../templates/post-checkout" .git/hooks/post-checkout
  ln -s "$SUBMIT" "$SB/bin/submit-task"

  local wt="$SB/wt" out
  git worktree add -q -b wt "$wt" 2> "$SB/log" || die "$(cat "$SB/log")"
  eq "$(readlink "$wt/ignored/state")" "$REPO/ignored/state" "nested link"
  eq "$(readlink "$wt/build")" "$REPO/build" "directory link"
  [[ -f $wt/tool.sh && ! -L $wt/tool.sh ]] || die "replaced a tracked file"
  contains "$(cat "$SB/log")" "missing isn't in $REPO; not linked"
  [[ ! -e $wt/.claude-task/config.local ]] || die "linked a config.local the main checkout lacks"
  eq "$(cat "$SB_WT_LOG")" "$REPO $wt" "worktree.sh"
  contains "$(cat "$SB/log")" "the link build isn't gitignored"
  eq "$(git -C "$wt" status --porcelain)" "?? build" "links not ignored"

  out="$(cd "$wt" && "$SUBMIT" worktree-setup 2>&1)" || die "$out"
  contains "$out" "kept     ignored/state"
  git checkout -q -b other && git checkout -q main
  eq "$(grep -c '' "$SB_WT_LOG")" 2 "hook ran on a plain checkout"
  out="$("$SUBMIT" worktree-setup 2>&1)" && die "set up the main checkout"
  contains "$out" "is the main checkout"

  # config.local is gitignored, so it's always linked when the main checkout has one
  echo 'SHARED_RULES=../r.md' > .claude-task/config.local
  local wt2="$SB/wt2"
  git worktree add -q -b wt2 "$wt2" 2> "$SB/log" || die "$(cat "$SB/log")"
  eq "$(readlink "$wt2/.claude-task/config.local")" "$REPO/.claude-task/config.local" "config.local link"
  eq "$(git -C "$wt2" status --porcelain)" "?? build" "config.local link not ignored"

  printf 'WORKTREE_LINKS=../escape\n' > "$wt/.claude-task/config"
  out="$(cd "$wt" && "$SUBMIT" worktree-setup 2>&1)" && die "linked outside the repo"
  contains "$out" "must list plain repo-relative paths, got: ../escape"
}

test_pick_task() {
  sandbox
  local out
  out="$("$SUBMIT" status < /dev/null 2>&1)" && die "picked without a terminal"
  contains "$out" "not a terminal; pass a task id"

  # script gives the CLI a terminal to prompt on
  export GH_MOCK_RUNS=$'usb-fix-8b20e4\tsuccess\tOct 20 14:03\nbad id\tfailure\tx\nt-0a0b0c\tin_progress\tOct 21 09:00'
  out="$(printf '2\n' | script -qec "$SUBMIT status" /dev/null 2>&1)" || die "$out"
  contains "$out" "  1) usb-fix-8b20e4"
  contains "$out" "  2) t-0a0b0c"
  grep -q "bad id" <<< "$out" && die "listed an invalid task id"
  contains "$out" "result branch: task-t"

  out="$(printf '\n' | script -qec "$SUBMIT status" /dev/null 2>&1)" || die "$out"
  contains "$out" "result branch: task-usb-fix"

  out="$(printf '3\n' | script -qec "$SUBMIT status" /dev/null 2>&1)" && die "accepted an out-of-range pick"
  contains "$out" "no task numbered '3'"
}

test_pick_task_continue_open_prs_only() {
  published_task
  git checkout -q main
  local out
  export GH_MOCK_RUNS=$'t-111111\tsuccess\tOct 21 10:00\ngone-222222\tsuccess\tOct 21 09:00\nt-333333\tsuccess\tOct 20 09:00'
  export GH_MOCK_OPEN_BRANCHES=$'task-t\ntask-other'
  out="$(printf '\n' | script -qec "$SUBMIT continue" /dev/null 2>&1)"
  contains "$out" "  1) t-111111"
  grep -q "gone-222222\|t-333333" <<< "$out" && die "listed a task without an open PR, or an older run of one"
  contains "$(cat "$SB_CLAUDE_MSG")" "continuing task t-111111"

  git checkout -q main
  GH_MOCK_OPEN_BRANCHES= out="$(printf '\n' | script -qec "$SUBMIT continue" /dev/null 2>&1)" \
    && die "continued with no open PRs"
  contains "$out" "no recent tasks with an open PR"
}

# --- the .claude-task/ folder ------------------------------------------------------------------

test_ci_template_wraps_prompt() {
  sandbox
  printf 'header\n\n  {{task}}\n\nfooter {{task}} stays\n' > .claude-task/template.md
  printf '# Task\nDo the thing.\n{{task}}\n' > tasks/t.md
  submit tasks/t.md
  ci_env
  pipeline > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed"; }
  eq "$(cat "$SB/claude-stdin")" $'header\n\n# Task\nDo the thing.\n{{task}}\n\nfooter {{task}} stays' "wrapped prompt"
  grep -qx 'Do the thing.' "$SB/out/pr-body.md" || die "PR body lacks the prompt"
  grep -qx 'header' "$SB/out/pr-body.md" && die "PR body shows the template"

  sandbox
  printf 'no placeholder\n' > .claude-task/template.md
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  pipeline > "$SB/log" 2>&1 && die "template without {{task}} accepted"
  grep -q "must have exactly one {{task}} line (found 0)" "$SB/log" || die "$(cat "$SB/log")"
}

test_ci_shared_rules() {
  sandbox
  printf '# Shared\nbe brief\n' > "$SB/CLAUDE.md"
  # $HOME behind a symlink (like /home -> var/home) is resolved, not rejected
  mv "$HOME" "$SB/real-home" && ln -s real-home "$HOME"
  # a file without a final newline gets one before the next file
  printf 'home rule' > "$HOME/rules.md" && mkdir "$SB/abs" && echo 'abs rule' > "$SB/abs/r.md"
  printf 'SHARED_RULES=../CLAUDE.md  ~/rules.md\t%s\n' "$SB/abs/r.md" > .claude-task/config.local
  pin_runner v1.13.0
  printf 'header\n{{task}}\n' > .claude-task/template.md
  git add -A && git commit -qm rules && git push -q origin main
  echo 'do it' > tasks/t.md
  local status_before
  status_before="$(GIT_OPTIONAL_LOCKS=0 git status --porcelain)"
  submit tasks/t.md
  contains "$OUT" "rules:    ../CLAUDE.md  ~/rules.md"
  contains "$OUT" "changes:  1 file(s) relative to HEAD (1 file changed, 1 insertion(+))"
  { cat "$SB/CLAUDE.md" "$HOME/rules.md"; echo; cat "$SB/abs/r.md"; } > "$SB/all.md"
  cmp <(git show "$SNAP_SHA:.claude-task/shared-rules.md") "$SB/all.md" || die "rules not in snapshot"
  fails git cat-file -e "$SNAP_SHA:.claude-task/config.local"
  eq "$(GIT_OPTIONAL_LOCKS=0 git status --porcelain)" "$status_before" "working tree changed"
  ci_env
  pipeline > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed"; }
  eq "$(cat "$SB/claude-stdin")" $'# Shared\nbe brief\nhome rule\nabs rule\n\nheader\ndo it' "rules before the wrapped prompt"
  git fetch -q origin task-t
  fails git cat-file -e "FETCH_HEAD:.claude-task/shared-rules.md"
  eq "$(git diff --name-only HEAD FETCH_HEAD | tr '\n' ' ')" "a.txt c.txt src/new.txt " "PR diff vs main"
  grep -qF "| \`.claude-task/shared-rules.md\`" "$SB/out/pr-body.md" && die "files table lists the rules file"

  # a follow-up's base (the result branch) lacks the rules too, so they're uploaded again
  git checkout -q task-t
  submit tasks/t.md
  cmp <(git show "$SNAP_SHA:.claude-task/shared-rules.md") "$SB/all.md" || die "rules not in follow-up snapshot"
}

# pins the sandbox workflow to a runner release, as init writes it
pin_runner() {
  printf '    uses: test/runner/.github/workflows/claude-task-run.yml@%s # %s\n' "$(printf '%040d' 0)" "$1" \
    > .github/workflows/claude-task.yml
}

test_shared_rules_rejected() {
  sandbox
  echo x > tasks/t.md
  pin_runner v1.13.0
  mkdir -p "$SB/dir" "$SB/real" && echo x > "$SB/rules.md" && ln -s rules.md "$SB/link.md"
  echo x > "$SB/real/rules.md" && ln -s real "$SB/linkdir"
  echo x > "$SB/unreadable.md" && chmod 000 "$SB/unreadable.md" && ln -s ../rules.md "$HOME/hl.md"
  local p root charset='must list absolute, ~/ or repo-root-relative paths ([A-Za-z0-9._-] segments), got:'
  root="$(realpath -e "$REPO")"
  # every listed file is checked, not just the first; '|' separates the path from the full reason
  for p in "../missing.md|SHARED_RULES file not found: ../missing.md ($root/../missing.md)" \
           "../link.md|SHARED_RULES path must not contain a symlink: ../link.md" \
           "../linkdir/rules.md|SHARED_RULES path must not contain a symlink: ../linkdir/rules.md" \
           "~/hl.md|SHARED_RULES path must not contain a symlink: ~/hl.md" \
           "../dir|SHARED_RULES file is not a regular file: ../dir" \
           "../unreadable.md|SHARED_RULES file is not readable: ../unreadable.md" \
           "a.txt|SHARED_RULES must name files outside the repository: a.txt" \
           "~user/x.md|SHARED_RULES in .claude-task/config.local $charset ~user/x.md" \
           'x/../$(id).md|SHARED_RULES in .claude-task/config.local '"$charset"' x/../$(id).md'; do
    printf 'SHARED_RULES=../rules.md %s\n' "${p%|*}" > .claude-task/config.local
    fails "$SUBMIT" --yes tasks/t.md > "$SB/log" 2>&1
    grep -qxF "claude-task: ${p#*|}" "$SB/log" || die "$p: $(cat "$SB/log")"
  done

  # a config.local symlink whose target is gone (e.g. in a worktree) fails instead of being skipped
  rm .claude-task/config.local && ln -s "$SB/gone" .claude-task/config.local
  fails "$SUBMIT" --yes tasks/t.md > "$SB/log" 2>&1
  grep -qxF "claude-task: .claude-task/config.local is a symlink to a missing file ($SB/gone)" "$SB/log" \
    || die "$(cat "$SB/log")"
  rm .claude-task/config.local

  # machine-local: never in the committed config; config.local sets nothing else and stays ignored
  echo 'SHARED_RULES=../rules.md' > .claude-task/config
  fails "$SUBMIT" --yes tasks/t.md > "$SB/log" 2>&1
  grep -q "SHARED_RULES is machine-local; move it from .claude-task/config to .claude-task/config.local" "$SB/log" \
    || die "$(cat "$SB/log")"
  git checkout -q .claude-task/config
  printf 'SHARED_RULES=../rules.md\nBASE_BRANCH=dev\n' > .claude-task/config.local
  fails "$SUBMIT" --yes tasks/t.md > "$SB/log" 2>&1
  grep -q "may only set SHARED_RULES; put BASE_BRANCH in .claude-task/config" "$SB/log" || die "$(cat "$SB/log")"
  echo 'SHARED_RULES=../rules.md' > .claude-task/config.local
  echo 'tasks/' > .claude-task/.gitignore
  fails "$SUBMIT" --yes tasks/t.md > "$SB/log" 2>&1
  grep -q "config.local must be gitignored" "$SB/log" || die "$(cat "$SB/log")"
  git checkout -q .claude-task/.gitignore

  # the pinned runner must drop the uploaded file again
  for p in v1.9.0 untagged; do
    pin_runner "$p"
    fails "$SUBMIT" --yes tasks/t.md > "$SB/log" 2>&1
    grep -q "needs runner v1.13.0 or newer.*rerun 'submit-task init'" "$SB/log" || die "$p: $(cat "$SB/log")"
  done
  pin_runner v1.13.0

  # the reserved path, set or not: a working-tree file there would be uploaded and dropped
  echo mine > .claude-task/shared-rules.md
  for p in 'SHARED_RULES=../rules.md' ''; do
    printf '%s\n' "$p" > .claude-task/config.local
    fails "$SUBMIT" --yes tasks/t.md > "$SB/log" 2>&1
    grep -q "is reserved for the SHARED_RULES upload" "$SB/log" || die "'$p': $(cat "$SB/log")"
  done
  git add -A && git commit -qm reserved && rm .claude-task/shared-rules.md
  echo 'SHARED_RULES=../rules.md' > .claude-task/config.local
  fails "$SUBMIT" --yes tasks/t.md > "$SB/log" 2>&1
  grep -q "is committed" "$SB/log" || die "$(cat "$SB/log")"
  eq "$(snap)" "" "nothing pushed"
}

test_shared_rules_changing_mid_submit() {
  sandbox
  pin_runner v1.13.0
  git add -A && git commit -qm rules && git push -q origin main
  echo 'SHARED_RULES=../rules.md' > .claude-task/config.local
  echo x > tasks/t.md
  echo 1 > "$SB/rules.md"
  # every hash of the rules files sees new content
  printf '#!/usr/bin/env bash\n%q "$@" || exit\n[[ $1 == hash-object && $* == *--stdin ]] && date +%%s%%N > %q\nexit 0\n' \
    "$(command -v git)" "$SB/rules.md" > "$SB/bin/git"
  chmod +x "$SB/bin/git"
  fails "$SUBMIT" --yes tasks/t.md > "$SB/log" 2>&1
  rm "$SB/bin/git"
  grep -q "kept changing" "$SB/log" || die "$(cat "$SB/log")"
  eq "$(snap)" "" "nothing pushed"
}

# a rules file that turns unreadable after the checks fails the submit instead of being cut short
test_shared_rules_unreadable_mid_submit() {
  sandbox
  pin_runner v1.13.0
  git add -A && git commit -qm rules && git push -q origin main
  echo 'SHARED_RULES=../rules.md ../second.md' > .claude-task/config.local
  echo x > tasks/t.md
  echo 1 > "$SB/rules.md" && echo 2 > "$SB/second.md"
  printf '#!/usr/bin/env bash\n[[ $1 == read-tree ]] && chmod 000 %q\nexec %q "$@"\n' \
    "$SB/second.md" "$(command -v git)" > "$SB/bin/git"
  chmod +x "$SB/bin/git"
  fails "$SUBMIT" --yes tasks/t.md > "$SB/log" 2>&1
  rm "$SB/bin/git"
  grep -qxF "claude-task: reading the SHARED_RULES files failed" "$SB/log" || die "$(cat "$SB/log")"
  eq "$(snap)" "" "nothing pushed"
}

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
  out="$("$CI" claude 2>&1)" && die "ran without validate.sh"
  contains "$out" ".claude-task/validate.sh is not a regular file"
  [[ ! -e $SB/claude-calls ]] || die "Claude ran before the missing hook was caught"
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
  grep -q "submit-task worktree-setup" .git/hooks/post-checkout || die "post-checkout hook not installed"
  grep -qF "uses: test/runner/.github/workflows/claude-task-run.yml@$sha # v9.9.9" .github/workflows/claude-task.yml \
    || die "$(cat .github/workflows/claude-task.yml)"
  grep -q '@[A-Z_]*@' .github/workflows/claude-task.yml && die "unfilled placeholder"
  echo '# t' > .claude-task/tasks/x.md
  git check-ignore -q .claude-task/tasks/x.md || die "tasks not ignored"
  git check-ignore -q .claude-task/config.local || die "config.local not ignored"
  echo custom > .claude-task/validate.sh
  out="$("$runner/bin/submit-task" init 2>&1)"
  contains "$out" "kept     .claude-task/validate.sh"
  eq "$(cat .claude-task/validate.sh)" custom "init overwrote a file"
  cp "$runner/templates/validate.sh" "$SB/v.sh"
  fails "$SB/v.sh" 2>/dev/null
  printf '#!/bin/sh\necho mine\n' > .git/hooks/post-checkout
  out="$("$runner/bin/submit-task" init 2>&1)"
  contains "$out" "kept your own $target/.git/hooks/post-checkout, so new worktrees aren't set up on checkout"
  contains "$out" "run 'submit-task worktree-setup' when \$1 is the null sha"
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

test_ci_app_client() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  local which key out
  for which in setup publish; do
    key="${which^^}_GH_APP_CLIENT_ID"
    : > "$GITHUB_OUTPUT"
    "$CI" app-client "$which" > /dev/null
    grep -qx client_id= "$GITHUB_OUTPUT" || die "$which client ID set without config"
    : > "$GITHUB_OUTPUT"
    echo "$key=Iv23li${which}1" >> "$CT_CONF"
    "$CI" app-client "$which" > /dev/null
    grep -qx "client_id=Iv23li${which}1" "$GITHUB_OUTPUT" || die "$(cat "$GITHUB_OUTPUT")"
    echo "$key=x\$(id)" >> "$CT_CONF"
    out="$("$CI" app-client "$which" 2>&1)" && die "accepted a bad $which client ID"
    contains "$out" "unexpected characters"
  done
  out="$("$CI" app-client other 2>&1)" && die "accepted an unknown app"
  contains "$out" "unknown app"
}

test_ci_publish_app_committer() {
  sandbox
  echo x > tasks/t.md
  submit tasks/t.md
  ci_env
  CT_PUBLISH_APP_SLUG=task-app pipeline > "$SB/log" 2>&1 || { cat "$SB/log"; die "pipeline failed"; }
  git fetch -q origin task-t
  eq "$(git log -1 --format='%cn <%ce>' FETCH_HEAD)" "Task-app[bot] <1+task-app[bot]@users.noreply.github.com>" "app committer"
  eq "$(git log -1 --format=%an FETCH_HEAD)" "Octo" "author with an app"
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
