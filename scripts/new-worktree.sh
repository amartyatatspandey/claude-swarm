#!/usr/bin/env bash
# Create an isolated git worktree for a coding agent.
# Usage: new-worktree.sh <repo-root> <agent-name> [base-ref]
# Prints the new worktree path on stdout (only line on success).
set -euo pipefail

REPO="$1"
AGENT="$2"
BASE="${3:-HEAD}"

cd "$REPO"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Not a git repository: $REPO" >&2
  exit 1
fi

REPO_NAME="$(basename "$(git rev-parse --show-toplevel)")"
TS="$(date +%Y%m%d-%H%M%S)"
BRANCH="swarm/${AGENT}-${TS}"
BASE_DIR="$HOME/.swarm/worktrees/${REPO_NAME}"
WT_DIR="${BASE_DIR}/${AGENT}-${TS}"

mkdir -p "$BASE_DIR"
git worktree add -b "$BRANCH" "$WT_DIR" "$BASE" >&2

echo "$WT_DIR"
