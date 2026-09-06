#!/usr/bin/env bash
# Report everything the orchestrator needs to know before delegating, in one call.
# Usage: preflight.sh <repo-root>
# Never mutates anything. Exit 0 always if the path exists — read the fields.
set -uo pipefail

REPO="${1:-.}"

if [ ! -d "$REPO" ]; then
  echo "error=no-such-directory"
  exit 1
fi

cd "$REPO" || exit 1

echo "repo=$(pwd -P)"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "git=no"
  echo "# No version control: worker isolation is UNAVAILABLE. See SKILL.md §4."
  exit 0
fi

echo "git=yes"
echo "root=$(git rev-parse --show-toplevel)"
echo "branch=$(git rev-parse --abbrev-ref HEAD)"
echo "head=$(git rev-parse --short HEAD 2>/dev/null || echo none)"

DIRTY="$(git status --porcelain 2>/dev/null)"
if [ -z "$DIRTY" ]; then
  echo "clean=yes"
else
  echo "clean=no"
  echo "dirty_count=$(printf '%s\n' "$DIRTY" | wc -l | tr -d ' ')"
  printf '%s\n' "$DIRTY" | head -20 | sed 's/^/  /'
  [ "$(printf '%s\n' "$DIRTY" | wc -l)" -gt 20 ] && echo "  ...truncated"
fi

# Existing swarm worktrees — stale ones from interrupted runs show up here.
WT="$(git worktree list 2>/dev/null | grep -c 'swarm/' || true)"
echo "swarm_worktrees=${WT:-0}"

command -v cursor-agent >/dev/null 2>&1 && echo "cursor=on-path" || echo "cursor=MISSING"
command -v commandcode >/dev/null 2>&1 && echo "commandcode=on-path" || echo "commandcode=MISSING"
