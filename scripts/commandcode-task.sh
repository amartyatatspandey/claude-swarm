#!/usr/bin/env bash
# Run one headless CommandCode task against a workspace. Fallback worker only —
# Cursor is the default (see SKILL.md §2).
# Usage: commandcode-task.sh <workspace-dir> <prompt-file> <output-json-file>
# Env: COMMANDCODE_SWARM_MODEL (model id), SWARM_TASK_TIMEOUT (seconds, default 900)
# Exit: 0 ok · 124 timed out · 127 not installed · other = worker's own failure
set -uo pipefail

WORKSPACE="${1:?usage: commandcode-task.sh <workspace-dir> <prompt-file> <out-file>}"
PROMPT_FILE="${2:?missing prompt file}"
OUT_FILE="${3:?missing output file}"
MODEL="${COMMANDCODE_SWARM_MODEL:-poolside/laguna-s-2.1-free}"
TIMEOUT="${SWARM_TASK_TIMEOUT:-900}"

if ! command -v commandcode >/dev/null 2>&1; then
  echo "commandcode not found on PATH." >&2
  exit 127
fi
[ -d "$WORKSPACE" ] || { echo "workspace not a directory: $WORKSPACE" >&2; exit 2; }
[ -s "$PROMPT_FILE" ] || { echo "prompt file missing or empty: $PROMPT_FILE" >&2; exit 2; }

# commandcode has no --workspace flag (unlike cursor-agent) — cd into the
# worktree so it's the primary workspace rather than just added context.
(
  cd "$WORKSPACE" || exit 2
  commandcode -p "$(cat "$PROMPT_FILE")" \
    -m "$MODEL" \
    --output-format json \
    --yolo \
    --skip-onboarding \
    --no-session
) > "$OUT_FILE" 2>&1 &
PID=$!

WAITED=0
while kill -0 "$PID" 2>/dev/null; do
  if [ "$WAITED" -ge "$TIMEOUT" ]; then
    kill -TERM "$PID" 2>/dev/null
    sleep 3
    kill -KILL "$PID" 2>/dev/null
    echo "TIMEOUT after ${TIMEOUT}s — partial work may exist in $WORKSPACE" >> "$OUT_FILE"
    cat "$OUT_FILE"
    exit 124
  fi
  sleep 2
  WAITED=$((WAITED + 2))
done

wait "$PID"
RC=$?
cat "$OUT_FILE"
exit "$RC"
