#!/usr/bin/env bash
# Run one headless CommandCode task against a workspace.
# Usage: commandcode-task.sh <workspace-dir> <prompt-file> <output-json-file>
set -euo pipefail

WORKSPACE="$1"
PROMPT_FILE="$2"
OUT_FILE="$3"
MODEL="${COMMANDCODE_SWARM_MODEL:-poolside/laguna-s-2.1-free}"

if ! command -v commandcode >/dev/null 2>&1; then
  echo "commandcode not found on PATH." >&2
  exit 127
fi

# commandcode has no --workspace flag (unlike cursor-agent) — cd into the
# worktree so it's the primary workspace rather than just added context.
(
  cd "$WORKSPACE"
  commandcode -p "$(cat "$PROMPT_FILE")" \
    -m "$MODEL" \
    --output-format json \
    --yolo \
    --skip-onboarding \
    --no-session
) > "$OUT_FILE" 2>&1

cat "$OUT_FILE"
