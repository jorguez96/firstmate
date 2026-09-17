#!/usr/bin/env bash
# Tests for bin/fm-upstream-sync.sh: fork-parent upstream merge automation.
#
# Every case builds a fixture world with a file:// origin (the fork) and a
# file:// upstream (the fork parent), so no case touches the network and no
# case lands anything outside its own temp dir.
# The three automation paths are each dry-run first: a clean merge with green
# verification reports ready and lands nothing, a clean merge with red
# verification refuses to land, and a conflicting merge names its files and
# refuses to land.
# A live default run then proves the no-auto-land promise: it pushes a review
# branch and asks gh-axi for a pull request while origin/main stays put.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC="$ROOT/bin/fm-upstream-sync.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-upstream-sync)

# new_world <name> <lint_exit>: fixture fork at base plus one fork commit, and
# an upstream bare repo holding the same base. The caller adds the upstream
# divergence with diverge_upstream and the fork identity with wire_upstream.
new_world() {
  local name=$1 lint_exit=$2 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/config"
  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q --bare "$w/upstream.git"
  git -C "$w/upstream.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  git -C "$w/seed" checkout -qb main
  printf 'base\n' > "$w/seed/file.txt"
  mkdir -p "$w/seed/bin" "$w/seed/tests"
  printf '#!/usr/bin/env bash\nexit %s\n' "$lint_exit" > "$w/seed/bin/fm-lint.sh"
  chmod +x "$w/seed/bin/fm-lint.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$w/seed/tests/affected.test.sh"
  chmod +x "$w/seed/tests/affected.test.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm base
  git -C "$w/seed" push -q origin main
  git clone -q "$w/origin.git" "$w/fork" 2>/dev/null
  git -C "$w/fork" remote add upstream "file://$w/upstream.git"
  # The upstream bare repo starts at the same base via the seed.
  git -C "$w/seed" push -q "file://$w/upstream.git" main:main 2>/dev/null
  # One fork-only commit on top of the shared base.
  printf 'fork\n' > "$w/fork/fork.txt"
  git -C "$w/fork" add fork.txt
  git -C "$w/fork" commit -qm fork-commit
  git -C "$w/fork" push -q origin main
  printf '%s\n' "$w"
}

# diverge_upstream <world> <mode>: clean adds a disjoint file and touches the
# affected test, conflict edits the same line the fork will also edit.
diverge_upstream() {
  local w=$1 mode=$2
  git clone -q "$w/upstream.git" "$w/upwork" 2>/dev/null
  if [ "$mode" = "clean" ]; then
    printf 'upstream\n' > "$w/upwork/upstream.txt"
    printf '# upstream touch\n' >> "$w/upwork/tests/affected.test.sh"
  else
    printf 'upstream-edit\n' > "$w/upwork/file.txt"
  fi
  git -C "$w/upwork" add -A
  git -C "$w/upwork" commit -qm "upstream-$mode"
  git -C "$w/upwork" push -q origin main
  rm -rf "$w/upwork"
}

wire_fork_conflict() {
  local w=$1
  printf 'fork-edit\n' > "$w/fork/file.txt"
  git -C "$w/fork" add file.txt
  git -C "$w/fork" commit -qm fork-edit
  git -C "$w/fork" push -q origin main
}

run_sync() {
  local w=$1
  shift
  env FM_HOME="$w/home" FM_UPSTREAM_SYNC_INTERVAL=0 "$SYNC" "$@"
}

test_check_reports_when_behind() {
  local w out status=0
  w=$(new_world check-behind 0)
  diverge_upstream "$w" clean
  out=$(run_sync "$w" check --repo "$w/fork" 2>&1) || status=$?
  expect_code 0 "$status" "check exit when behind"
  assert_contains "$out" "upstream sync available" "check names the pending sync"
  pass "check reports when behind"
}

test_check_silent_when_current() {
  local w out status=0
  w=$(new_world check-current 0)
  out=$(run_sync "$w" check --repo "$w/fork" 2>&1) || status=$?
  expect_code 0 "$status" "check exit when current"
  assert_equals "" "$out" "check stays silent when current"
  pass "check silent when current"
}

test_dryrun_clean_green_lands_nothing() {
  local w out status=0 before after
  w=$(new_world dryrun-green 0)
  diverge_upstream "$w" clean
  before=$(git -C "$w/fork" rev-parse origin/main)
  out=$(run_sync "$w" sync --repo "$w/fork" --dry-run 2>&1) || status=$?
  expect_code 0 "$status" "dry-run exit on clean green"
  assert_contains "$out" "clean merge, verification green" "dry-run reports green gate"
  assert_contains "$out" "tests/affected.test.sh green" "dry-run exercises the affected test file"
  assert_contains "$out" "dry-run, landed nothing" "dry-run lands nothing"
  after=$(git -C "$w/fork" rev-parse origin/main)
  assert_equals "$before" "$after" "origin/main is untouched by a dry run"
  pass "dry-run clean green lands nothing"
}

test_dryrun_red_verification_refuses_land() {
  local w out status=0 before after
  w=$(new_world dryrun-red 1)
  diverge_upstream "$w" clean
  before=$(git -C "$w/fork" rev-parse origin/main)
  out=$(run_sync "$w" sync --repo "$w/fork" --dry-run 2>&1) || status=$?
  expect_code 0 "$status" "dry-run exit on red verification"
  assert_contains "$out" "verification red" "dry-run reports the red gate"
  assert_contains "$out" "refusing to land" "red merge never lands"
  after=$(git -C "$w/fork" rev-parse origin/main)
  assert_equals "$before" "$after" "origin/main is untouched by a red sync"
  pass "dry-run red verification refuses land"
}

test_dryrun_conflict_names_files() {
  local w out status=0
  w=$(new_world dryrun-conflict 0)
  wire_fork_conflict "$w"
  diverge_upstream "$w" conflict
  out=$(run_sync "$w" sync --repo "$w/fork" --dry-run 2>&1) || status=$?
  expect_code 0 "$status" "dry-run exit on conflict"
  assert_contains "$out" "conflicts in:" "dry-run reports the conflict path"
  assert_contains "$out" "file.txt" "dry-run names the conflicting file"
  assert_contains "$out" "dry-run, opened nothing" "conflict dry-run opens nothing"
  pass "dry-run conflict names files"
}

test_dirty_checkout_refused() {
  local w out status=0
  w=$(new_world dirty 0)
  diverge_upstream "$w" clean
  printf 'dirty\n' >> "$w/fork/file.txt"
  out=$(run_sync "$w" sync --repo "$w/fork" --dry-run 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "dirty checkout must refuse"
  assert_contains "$out" "refused: checkout is dirty" "dirty refusal names the guard"
  pass "dirty checkout refused"
}

test_live_default_opens_pr_without_landing() {
  local w out status=0 before after fakebin log
  w=$(new_world live-pr 0)
  diverge_upstream "$w" clean
  fakebin=$(fm_fakebin "$w")
  log="$w/gh-log"
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$log'
printf 'https://example.invalid/pr/1\n'
SH
  chmod +x "$fakebin/gh-axi"
  before=$(git -C "$w/fork" rev-parse origin/main)
  out=$(env FM_HOME="$w/home" FM_UPSTREAM_SYNC_INTERVAL=0 PATH="$fakebin:$PATH" "$SYNC" sync --repo "$w/fork" 2>&1) || status=$?
  expect_code 0 "$status" "live default exit on clean green"
  assert_contains "$out" "clean merge, verification green" "live run reports the green gate"
  after=$(git -C "$w/fork" rev-parse origin/main)
  assert_equals "$before" "$after" "origin/main never advances without auto-land"
  assert_present "$log" "fake gh-axi saw the PR request"
  assert_grep "pr create" "$log" "live run opens a pull request"
  pass "live default opens PR without landing"
}

test_dryrun_conflict_previews_issue_and_creates_nothing() {
  local w out status=0 base upstream before_refs after_refs fakebin log
  w=$(new_world dryrun-conflict-preview 0)
  wire_fork_conflict "$w"
  diverge_upstream "$w" conflict
  base=$(git -C "$w/fork" rev-parse origin/main)
  git -C "$w/fork" fetch upstream main --quiet 2>/dev/null
  upstream=$(git -C "$w/fork" rev-parse upstream/main)
  fakebin=$(fm_fakebin "$w")
  log="$w/gh-log"
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$log'
printf 'https://example.invalid/issue/1\n'
SH
  chmod +x "$fakebin/gh-axi"
  before_refs=$(git -C "$w/fork" ls-remote origin)
  out=$(env FM_HOME="$w/home" FM_UPSTREAM_SYNC_INTERVAL=0 PATH="$fakebin:$PATH" "$SYNC" sync --repo "$w/fork" --dry-run 2>&1) || status=$?
  expect_code 0 "$status" "conflict dry-run exit"
  assert_contains "$out" "conflicts in:" "dry-run reports the conflict path"
  assert_contains "$out" "file.txt" "dry-run names the conflicting file"
  assert_contains "$out" "dry-run, opened nothing" "conflict dry-run opens nothing"
  assert_contains "$out" "would open tracking issue" "dry-run previews the reviewable artifact"
  assert_contains "$out" "$base" "dry-run prints the exact base SHA"
  assert_contains "$out" "$upstream" "dry-run prints the exact upstream SHA"
  after_refs=$(git -C "$w/fork" ls-remote origin)
  assert_equals "$before_refs" "$after_refs" "dry-run pushes no branch"
  assert_absent "$log" "dry-run never calls gh-axi"
  pass "dry-run conflict previews issue and creates nothing"
}

test_live_conflict_opens_issue_without_branch() {
  local w out status=0 base upstream before_main after_main before_refs after_refs fakebin log
  w=$(new_world live-conflict 0)
  wire_fork_conflict "$w"
  diverge_upstream "$w" conflict
  base=$(git -C "$w/fork" rev-parse origin/main)
  git -C "$w/fork" fetch upstream main --quiet 2>/dev/null
  upstream=$(git -C "$w/fork" rev-parse upstream/main)
  fakebin=$(fm_fakebin "$w")
  log="$w/gh-log"
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$log'
prev=""
for a in "\$@"; do
  if [ "\$prev" = "--body-file" ]; then
    cat "\$a" >> '$log'
  fi
  prev="\$a"
done
printf 'https://example.invalid/issue/1\n'
SH
  chmod +x "$fakebin/gh-axi"
  before_main=$(git -C "$w/fork" rev-parse origin/main)
  before_refs=$(git -C "$w/fork" ls-remote origin)
  out=$(env FM_HOME="$w/home" FM_UPSTREAM_SYNC_INTERVAL=0 PATH="$fakebin:$PATH" "$SYNC" sync --repo "$w/fork" 2>&1) || status=$?
  expect_code 0 "$status" "live conflict exit"
  assert_contains "$out" "conflicts in:" "live conflict reports the conflict path"
  assert_contains "$out" "tracking issue" "live conflict arrives reviewable instead of failing"
  after_main=$(git -C "$w/fork" rev-parse origin/main)
  assert_equals "$before_main" "$after_main" "origin/main never advances on conflict"
  after_refs=$(git -C "$w/fork" ls-remote origin)
  assert_equals "$before_refs" "$after_refs" "conflict path never pushes a branch, so it never pushes zero-commit branches"
  assert_present "$log" "fake gh-axi saw the issue request"
  assert_grep "issue create" "$log" "live conflict opens a tracking issue"
  assert_no_grep "pr create" "$log" "live conflict never attempts a pull request"
  assert_grep "file.txt" "$log" "issue carries the conflict-file list"
  assert_grep "$base" "$log" "issue carries the exact base SHA"
  assert_grep "$upstream" "$log" "issue carries the exact upstream SHA"
  pass "live conflict opens issue without branch"
}

test_check_reports_when_behind
test_check_silent_when_current
test_dryrun_clean_green_lands_nothing
test_dryrun_red_verification_refuses_land
test_dryrun_conflict_names_files
test_dryrun_conflict_previews_issue_and_creates_nothing
test_live_conflict_opens_issue_without_branch
test_dirty_checkout_refused
test_live_default_opens_pr_without_landing

echo "# all fm-upstream-sync tests passed"
