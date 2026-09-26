#!/usr/bin/env bash
# Remove a swarm worktree (and its branch) after its diff has been integrated or discarded.
# Usage: cleanup-worktree.sh <repo-root> <worktree-dir>
set -euo pipefail

REPO="$1"
WT_DIR="$2"

cd "$REPO"
BRANCH="$(git -C "$WT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

git worktree remove --force "$WT_DIR" 2>/dev/null || rm -rf "$WT_DIR"

if [ -n "${BRANCH:-}" ] && [ "$BRANCH" != "HEAD" ]; then
  git branch -D "$BRANCH" 2>/dev/null || true
fi
