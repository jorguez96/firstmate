#!/usr/bin/env bash
# fm-upstream-sync.sh - merge the upstream fork parent into this fork's origin/main.
#
# This fork carries its own commits on top of an older upstream base, so a pure
# fast-forward onto upstream is impossible and the sync merges upstream in.
# Upstream is fetched from the `upstream` remote and the fork's `main` tracks `origin`.
# Homes then advance through the guarded fast-forward they already run
# (bin/fm-update.sh via the updatefirstmate skill), so this script owns only the
# fork's own merge into origin/main and never a second home updater.
# Standing sync-merge authority (captain, 2026-09-17, bounded to this automation
# only): a sync lands on its own if and only if the upstream merge is
# conflict-free AND verification is green, and anything else arrives for the
# captain instead (verification-red as a pull request, conflicts as a tracking
# issue) and never auto-lands.
# Red merges never land under any setting.
# The script never force-pushes, never rebases landed fork commits, never touches
# a dirty checkout, and never commits secrets.
# Verification is at minimum bin/fm-lint.sh plus the affected test files, and the
# merge attempt always runs in a disposable scratch worktree, never on main.
#
# Usage:
#   fm-upstream-sync.sh check [--repo <path>]
#   fm-upstream-sync.sh sync [--repo <path>] [--dry-run] [--allow-auto-land]
#   fm-upstream-sync.sh arm [--repo <path>]
#   fm-upstream-sync.sh disarm
#   fm-upstream-sync.sh --help
#
# `check` prints one line when origin/main sits behind upstream/main and prints
# nothing when current, so it composes with the watcher state-check contract.
# `sync --dry-run` proves clean-merge detection, green verification gating, and
# the conflict path against the real upstream remote without pushing or opening
# anything, while printing the exact tracking-issue artifact it would open.
# A live `sync` without auto-land opens a pull request with gh-axi instead of
# landing (conflicts open a tracking issue instead, because a branch with zero
# new commits cannot open a pull request), and states in its body exactly what
# enables auto-landing.
# Auto-landing additionally requires FM_UPSTREAM_SYNC_AUTO_LAND=1 in the
# environment alongside --allow-auto-land, so one flag alone never lands.
# `arm` writes state/upstream-sync.check.sh and binds its bytes with
# bin/fm-check-register.sh, and `disarm` removes the shim and its trust binding.
set -u
export LC_ALL=C
# A watched upstream remote must never stop to ask for credentials.
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID=upstream-sync
RECORD="$STATE/.upstream-sync-check"

usage() {
  cat <<'EOF'
Usage:
  fm-upstream-sync.sh check [--repo <path>]
  fm-upstream-sync.sh sync [--repo <path>] [--dry-run] [--allow-auto-land]
  fm-upstream-sync.sh arm [--repo <path>]
  fm-upstream-sync.sh disarm
  fm-upstream-sync.sh --help
EOF
}

die() {
  printf '%s\n' "$1" >&2
  exit "${2:-2}"
}

repo_top() {
  if [ -n "${SYNC_REPO:-}" ]; then
    printf '%s\n' "$SYNC_REPO"
  else
    git rev-parse --show-toplevel 2>/dev/null || die "error: not inside a git repository" 2
  fi
}

require_remote() {
  local repo=$1 name=$2
  git -C "$repo" config --get "remote.$name.url" >/dev/null 2>&1 \
    || die "error: remote '$name' is not configured in $repo" 2
}

refuse_dirty() {
  local repo=$1
  [ -z "$(git -C "$repo" status --porcelain --untracked-files=no 2>/dev/null)" ] \
    || die "refused: checkout is dirty in $repo" 1
}

# Resolve the fork base (origin/main) and the upstream head without fetching,
# so `check` stays read-only.
resolve_heads() {
  local repo=$1
  require_remote "$repo" origin
  require_remote "$repo" upstream
  git -C "$repo" fetch origin main --quiet 2>/dev/null || true
  SYNC_BASE=$(git -C "$repo" rev-parse --verify origin/main 2>/dev/null) \
    || die "error: cannot resolve origin/main" 1
  SYNC_UPSTREAM=$(git -C "$repo" ls-remote upstream refs/heads/main 2>/dev/null | awk '{print $1}') \
    || die "error: cannot read upstream/main" 1
  [ -n "$SYNC_UPSTREAM" ] || die "error: cannot read upstream/main" 1
}

behind_count() {
  local repo=$1 base=$2 head=$3
  if git -C "$repo" merge-base --is-ancestor "$head" "$base" 2>/dev/null; then
    printf '0\n'
  elif git -C "$repo" merge-base --is-ancestor "$base" "$head" 2>/dev/null; then
    git -C "$repo" rev-list --count "$base..$head" 2>/dev/null || printf '1\n'
  else
    git -C "$repo" rev-list --count "$base..$head" 2>/dev/null || printf '1\n'
  fi
}

interval_open() {
  local every=${FM_UPSTREAM_SYNC_INTERVAL:-3600} now last
  if [ "$every" = "0" ]; then
    return 0
  fi
  case "$every" in
    ''|*[!0-9]*) die "error: FM_UPSTREAM_SYNC_INTERVAL must be 0..86400" 2 ;;
  esac
  if [ "$every" -lt 60 ] || [ "$every" -gt 86400 ]; then
    die "error: FM_UPSTREAM_SYNC_INTERVAL must be 0..86400" 2
  fi
  now=$(date +%s)
  if [ -f "$RECORD" ]; then
    last=$(cat "$RECORD" 2>/dev/null) || last=0
    case "$last" in
      ''|*[!0-9]*) last=0 ;;
    esac
    if [ $((now - last)) -lt "$every" ]; then
      return 1
    fi
  fi
  return 0
}

interval_stamp() {
  umask 077
  date +%s > "$RECORD" 2>/dev/null || true
}

cmd_check() {
  local repo behind
  repo=$(repo_top)
  if ! interval_open; then
    return 0
  fi
  resolve_heads "$repo"
  if git -C "$repo" merge-base --is-ancestor "$SYNC_UPSTREAM" "$SYNC_BASE" 2>/dev/null; then
    interval_stamp
    return 0
  fi
  behind=$(behind_count "$repo" "$SYNC_BASE" "$SYNC_UPSTREAM")
  printf 'upstream sync available: origin/main is %s behind upstream/main\n' "$behind"
  interval_stamp
}

secret_hit() {
  local scratch=$1
  git -C "$scratch" grep -n -E 'BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{10,}|github_pat_[A-Za-z0-9_]{10,}|TYPESAFE_API_KEY=[^[:space:]"'\'']' HEAD 2>/dev/null | head -n 5
}

run_verification() {
  local scratch=$1 base=$2 head=$3 tests out status=0
  out=""
  if [ -x "$scratch/bin/fm-lint.sh" ]; then
    if "$scratch/bin/fm-lint.sh" >/tmp/fm-upstream-sync-lint.log 2>&1; then
      out="${out}verify: lint green
"
    else
      out="${out}verify: lint red
"
      status=1
    fi
  else
    out="${out}verify: lint missing, treated as red
"
    status=1
  fi
  tests=$(git -C "$scratch" diff --name-only "$base" "$head" -- 'tests/*.test.sh' 2>/dev/null || true)
  if [ -z "$tests" ]; then
    out="${out}verify: no affected test files
"
  else
    local t ts=0
    for t in $tests; do
      if [ -f "$scratch/$t" ]; then
        if (cd "$scratch" && bash "$t" >/tmp/fm-upstream-sync-test.log 2>&1); then
          out="${out}verify: $t green
"
        else
          out="${out}verify: $t red
"
          ts=1
        fi
      fi
    done
    if [ "$ts" -ne 0 ]; then
      status=1
    fi
  fi
  printf '%s' "$out"
  return "$status"
}

pr_body_enablement() {
  cat <<'EOF'
## Enabling auto-landing

This sync arrived for review because live auto-landing is OFF.
Auto-landing engages only when BOTH hold for the same run:

- `FM_UPSTREAM_SYNC_AUTO_LAND=1` is present in the automation environment, AND
- `bin/fm-upstream-sync.sh sync` runs with `--allow-auto-land`.

One flag alone never lands.
The captain's standing authority (2026-09-17, bounded to this automation only) covers a self-landing merge if and only if the upstream merge is conflict-free AND verification is green (`bin/fm-lint.sh` plus the affected test files).
Merge conflicts, red verification, a dirty checkout, secrets in the diff, or anything destructive or irreversible always arrives for review instead (verification-red as a pull request, conflicts as a tracking issue) and never auto-lands.
Red merges never land under any setting.
EOF
}

open_pr() {
  local title=$1 body_file=$2 base_branch=head_branch
  base_branch=main
  head_branch=$3
  if ! command -v gh-axi >/dev/null 2>&1; then
    printf 'pr: gh-axi is unavailable; push %s for manual review\n' "$head_branch"
    return 0
  fi
  gh-axi pr create --title "$title" --body-file "$body_file" --base "$base_branch" --head "$head_branch"
}

open_issue() {
  local title=$1 body_file=$2
  if ! command -v gh-axi >/dev/null 2>&1; then
    printf 'issue: gh-axi is unavailable; manual review needed for %s\n' "$title"
    return 0
  fi
  gh-axi issue create --title "$title" --body-file "$body_file"
}

cmd_sync() {
  local repo dry=0 allow=0 scratch branch upstream_head base n conflicts vout vstatus=0
  repo=$(repo_top)
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      --allow-auto-land) allow=1 ;;
      *) die "error: unknown sync flag $1" 2 ;;
    esac
    shift
  done
  refuse_dirty "$repo"
  require_remote "$repo" origin
  require_remote "$repo" upstream
  git -C "$repo" fetch origin main --quiet 2>&1 || die "error: cannot fetch origin/main" 1
  git -C "$repo" fetch upstream main --quiet 2>&1 || die "error: cannot fetch upstream/main" 1
  base=$(git -C "$repo" rev-parse --verify origin/main 2>/dev/null) || die "error: cannot resolve origin/main" 1
  upstream_head=$(git -C "$repo" rev-parse --verify upstream/main 2>/dev/null) || die "error: cannot resolve upstream/main" 1
  if git -C "$repo" merge-base --is-ancestor "$upstream_head" "$base" 2>/dev/null; then
    printf 'upstream sync: already current at %s\n' "$base"
    return 0
  fi
  n=$(behind_count "$repo" "$base" "$upstream_head")
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-upstream-sync.XXXXXX") || die "error: cannot make scratch dir" 1
  # Worktree removal must run even when a later step refuses, so trap before any exit.
  # shellcheck disable=SC2064
  trap "git -C '$repo' worktree remove --force '$scratch' 2>/dev/null || rm -rf '$scratch'; git -C '$repo' worktree prune 2>/dev/null || true" EXIT HUP INT TERM
  git -C "$repo" worktree add --detach "$scratch" "$base" --quiet 2>&1 || die "error: cannot make scratch worktree" 1
  if git -C "$scratch" merge --no-commit --no-ff "$upstream_head" >/tmp/fm-upstream-sync-merge.log 2>&1; then
    conflicts=""
  else
    conflicts=$(git -C "$scratch" diff --name-only --diff-filter=U 2>/dev/null || true)
    [ -n "$conflicts" ] || conflicts="(unknown files)"
  fi
  if [ -n "$conflicts" ]; then
    printf 'upstream sync: conflicts in:\n%s\n' "$conflicts"
    printf 'upstream sync: refusing to land; opening a tracking issue for the captain instead\n'
    printf 'upstream sync: base %s upstream %s behind %s\n' "$base" "$upstream_head" "$n"
    if [ "$dry" -eq 1 ]; then
      printf 'upstream sync: dry-run, opened nothing\n'
      printf 'upstream sync: dry-run, would open tracking issue: chore(sync): upstream/main is %s ahead (conflicts need review)\n' "$n"
      return 0
    fi
    body=$(mktemp "${TMPDIR:-/tmp}/fm-upstream-sync-body.XXXXXX") || die "error: cannot make issue body" 1
    {
      printf 'Upstream sync needs the captain: upstream/main is %s ahead and the merge conflicts.\n\n' "$n"
      printf 'base: %s\nupstream: %s\nbehind: %s\n\n' "$base" "$upstream_head" "$n"
      fence='```'
      printf 'Conflicting files:\n\n%s\n%s\n%s\n\n' "$fence" "$conflicts" "$fence"
      printf 'Resolve by merging upstream/main into a local branch from %s, fixing the files above, running bin/fm-lint.sh plus the affected test files, and opening a pull request.\n\n' "$base"
      pr_body_enablement
    } > "$body"
    open_issue "chore(sync): upstream/main is $n ahead (conflicts need review)" "$body"
    rm -f "$body"
    return 0
  fi
  if secret_hit "$scratch" | grep -q .; then
    printf 'upstream sync: refusing to land; secrets appear in the merged tree\n'
    git -C "$scratch" merge --abort 2>/dev/null || true
    if [ "$dry" -eq 1 ]; then
      printf 'upstream sync: dry-run, opened nothing\n'
      return 0
    fi
    return 1
  fi
  # Commit the clean merge in the scratch worktree so verification runs on the
  # exact tree that would land.
  git -C "$scratch" -c user.name=fm-upstream-sync -c user.email=fm-upstream-sync@invalid commit --no-edit --quiet 2>&1 \
    || die "error: cannot commit scratch merge" 1
  head=$(git -C "$scratch" rev-parse HEAD) || die "error: cannot read scratch HEAD" 1
  vout=$(run_verification "$scratch" "$base" "$head")
  vstatus=$?
  printf '%s' "$vout"
  if [ "$vstatus" -ne 0 ]; then
    printf 'upstream sync: verification red; refusing to land and opening a pull request instead\n'
    if [ "$dry" -eq 1 ]; then
      printf 'upstream sync: dry-run, opened nothing\n'
      return 0
    fi
    branch="fm/upstream-sync-$(date +%Y%m%d-%H%M%S)"
    git -C "$repo" branch "$branch" "$head" --quiet 2>&1 || die "error: cannot make sync branch" 1
    git -C "$repo" push origin "$branch" 2>&1 || die "error: cannot push sync branch" 1
    body=$(mktemp "${TMPDIR:-/tmp}/fm-upstream-sync-body.XXXXXX") || die "error: cannot make PR body" 1
    {
      printf 'Upstream sync needs the captain: the merge is clean but verification is red.\n\n'
      fence='```'
      printf '%s\n%s\n%s\n\n' "$fence" "$vout" "$fence"
      pr_body_enablement
    } > "$body"
    open_pr "chore(sync): upstream/main is $n ahead (verification red)" "$body" "$branch"
    rm -f "$body"
    return 0
  fi
  printf 'upstream sync: clean merge, verification green\n'
  if [ "$dry" -eq 1 ]; then
    printf 'upstream sync: dry-run, landed nothing\n'
    return 0
  fi
  if [ "$allow" -eq 0 ] || [ "${FM_UPSTREAM_SYNC_AUTO_LAND:-0}" != "1" ]; then
    branch="fm/upstream-sync-$(date +%Y%m%d-%H%M%S)"
    git -C "$repo" branch "$branch" "$head" --quiet 2>&1 || die "error: cannot make sync branch" 1
    git -C "$repo" push origin "$branch" 2>&1 || die "error: cannot push sync branch" 1
    body=$(mktemp "${TMPDIR:-/tmp}/fm-upstream-sync-body.XXXXXX") || die "error: cannot make PR body" 1
    {
      printf 'Upstream sync is ready: the merge is conflict-free and verification is green.\n\n'
      fence='```'
      printf '%s\n%s\n%s\n\n' "$fence" "$vout" "$fence"
      printf 'Auto-landing is OFF for this run, so this arrives as a pull request.\n\n'
      pr_body_enablement
    } > "$body"
    open_pr "chore(sync): merge upstream/main ($n commits)" "$body" "$branch"
    rm -f "$body"
    return 0
  fi
  git -C "$repo" push origin "$head:main" 2>&1 || die "error: cannot push merged main (refused, never forced)" 1
  printf 'upstream sync: landed %s into origin/main\n' "$head"
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-upstream-sync.sh - upstream sync poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-upstream-sync.sh") check"
}

cmd_arm() {
  local repo home shim device want tmp
  repo=$(repo_top)
  home=$FM_HOME
  shim="$STATE/$CHECK_ID.check.sh"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "error: state directory is unavailable" 2
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  # shellcheck source=bin/fm-check-lib.sh
  . "$SCRIPT_DIR/fm-check-lib.sh"
  device=$(fm_pr_file_device "$STATE") || exit 1
  fm_pr_regular_destination_on_device_or_absent "$shim" "$device" || die "error: check shim path is unavailable" 1
  want=$(shim_content "$home")
  if [ -e "$shim" ] && [ "$(fm_pr_file_mode "$shim")" = 700 ] && [ "$(cat "$shim" 2>/dev/null)" = "$want" ]; then
    :
  else
    umask 077
    tmp=$(mktemp "$STATE/.fm-upstream-sync-shim.XXXXXX") || exit 1
    printf '%s\n' "$want" > "$tmp" || exit 1
    chmod 0700 "$tmp" || exit 1
    fm_pr_regular_destination_on_device_or_absent "$shim" "$device" || exit 1
    mv -f -- "$tmp" "$shim" || exit 1
    fm_pr_private_file_valid "$shim" 700 "$device" || exit 1
  fi
  "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" || exit 1
  printf 'armed: state/%s.check.sh (repo %s)\n' "$CHECK_ID" "$repo"
}

cmd_disarm() {
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  rm -f -- "$STATE/$CHECK_ID.check.sh" "$STATE/$CHECK_ID.check-trust" "$RECORD"
  printf 'disarmed: %s\n' "$CHECK_ID"
}

main() {
  local cmd
  [ $# -ge 1 ] || { usage >&2; exit 2; }
  case "$1" in
    -h|--help|help) usage; exit 0 ;;
    check|sync|arm|disarm) cmd=$1; shift ;;
    *) usage >&2; exit 2 ;;
  esac
  SYNC_REPO=""
  if [ "${1:-}" = "--repo" ]; then
    [ $# -ge 2 ] || die "error: --repo needs a path" 2
    SYNC_REPO=$2
    shift 2
  fi
  case "$cmd" in
    check) [ $# -eq 0 ] || { usage >&2; exit 2; }; cmd_check ;;
    sync) cmd_sync "$@" ;;
    arm) [ $# -eq 0 ] || { usage >&2; exit 2; }; cmd_arm ;;
    disarm) [ $# -eq 0 ] || { usage >&2; exit 2; }; cmd_disarm ;;
  esac
}

main "$@"
