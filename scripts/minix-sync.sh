#!/usr/bin/env bash
# [Minix] Merge the upstream mirror into minix, then reconcile and verify.
#
#   scripts/minix-sync.sh [ios|android|both]
#   scripts/minix-sync.sh [ios|android|both] --no-verify
#   scripts/minix-sync.sh [ios|android|both] --no-build
#
# The default platform is both. If a merge stops on conflicts, resolve them,
# stage the resolutions, and run the same command again; the script detects
# MERGE_HEAD and completes the existing merge before continuing.

set -euo pipefail

MAIN_BRANCH="main"
WORK_BRANCH="minix"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="both"
PLATFORM_SET=0
DO_BUILD=1
DO_VERIFY=1

usage() {
  sed -n '2,10s/^# \{0,1\}//p' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    ios|android|both)
      [ "$PLATFORM_SET" -eq 0 ] || { echo "platform specified more than once" >&2; exit 2; }
      PLATFORM="$1"
      PLATFORM_SET=1
      ;;
    --no-build) DO_BUILD=0 ;;
    --no-verify) DO_VERIFY=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok() { printf '\033[1;32m[ok] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit "${2:-1}"; }

show_conflicts() {
  local file
  printf '\nConflicted files:\n' >&2
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    printf '  %s\n' "$file" >&2
    rg -n -A2 -B2 '^(<<<<<<<|=======|>>>>>>>)' "$file" 2>/dev/null |
      head -60 >&2 || true
  done <<EOF
$(git diff --name-only --diff-filter=U)
EOF
  cat >&2 <<'EOF'

Resolve according to AGENTS.md:
  - Keep Minix behavior in customized domains.
  - Accept upstream logic elsewhere unless it breaks a Minix invariant.
  - Stage every resolution with git add, then rerun this command.
  - Abort only when intended: git merge --abort
EOF
}

cd "$REPO_ROOT"
command -v rg >/dev/null 2>&1 || die "ripgrep (rg) is required"

for branch in "$MAIN_BRANCH" "$WORK_BRANCH"; do
  git show-ref --verify --quiet "refs/heads/$branch" ||
    die "local branch '$branch' does not exist"
done

ORIGINAL_BRANCH="$(git branch --show-current)"
MERGE_HEAD_PATH="$(git rev-parse --git-path MERGE_HEAD)"

if [ -f "$MERGE_HEAD_PATH" ]; then
  say "Continuing the existing merge"
  [ "$ORIGINAL_BRANCH" = "$WORK_BRANCH" ] ||
    die "merge continuation must be on '$WORK_BRANCH', currently '$ORIGINAL_BRANCH'"
  if [ -n "$(git diff --name-only --diff-filter=U)" ]; then
    show_conflicts
    exit 10
  fi
  git diff --quiet ||
    die "resolved files still have unstaged changes; review and stage them with git add"
  GIT_EDITOR=true git merge --continue
  ok "Existing merge completed"
else
  if [ -n "$(git status --porcelain --untracked-files=normal --ignore-submodules=untracked)" ]; then
    git status --short --ignore-submodules=untracked >&2
    die "working tree is not clean; commit or stash changes before syncing"
  fi

  say "Updating $MAIN_BRANCH from origin"
  git checkout "$MAIN_BRANCH"
  before="$(git rev-parse HEAD)"
  git pull --ff-only origin "$MAIN_BRANCH" ||
    die "git pull was not fast-forward; inspect: git log origin/$MAIN_BRANCH..$MAIN_BRANCH"
  after="$(git rev-parse HEAD)"
  if [ "$before" = "$after" ]; then
    ok "$MAIN_BRANCH is current"
  else
    ok "$MAIN_BRANCH updated: ${before:0:12} -> ${after:0:12}"
  fi

  say "Merging $MAIN_BRANCH into $WORK_BRANCH"
  git checkout "$WORK_BRANCH"
  if git merge --no-edit "$MAIN_BRANCH"; then
    ok "Merge completed"
  else
    show_conflicts
    exit 10
  fi
fi

say "Checking Minix invariants"
if ! "$REPO_ROOT/scripts/minix-check-invariants.sh"; then
  die "Minix invariants failed; review git diff main...minix against AGENTS.md" 50
fi
ok "Minix invariants passed"

if [ "$DO_BUILD" -eq 0 ]; then
  warn "--no-build: skipped native dependencies and app builds"
else
  "$REPO_ROOT/scripts/minix-deps.sh" "$PLATFORM" ||
    die "native dependency reconciliation failed" 30

  if [ "$DO_VERIFY" -eq 0 ]; then
    warn "--no-verify: skipped app builds"
  else
    case "$PLATFORM" in
      ios) "$REPO_ROOT/scripts/minix-debug.sh" ios ;;
      android) "$REPO_ROOT/scripts/minix-debug.sh" android ;;
      both)
        "$REPO_ROOT/scripts/minix-debug.sh" ios
        "$REPO_ROOT/scripts/minix-debug.sh" android
        ;;
    esac
  fi
fi

say "Sync complete"
ok "$WORK_BRANCH contains the latest $MAIN_BRANCH"
printf 'Current branch: %s\n' "$(git branch --show-current)"
printf 'Latest commit: %s\n' "$(git log --oneline -1)"
[ "$ORIGINAL_BRANCH" = "$WORK_BRANCH" ] ||
  warn "started on '$ORIGINAL_BRANCH'; now on '$WORK_BRANCH'"
printf 'Push when ready: git push origin %s\n' "$WORK_BRANCH"
