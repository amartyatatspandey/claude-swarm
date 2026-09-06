#!/usr/bin/env bash
# Run one headless Cursor Agent task against a workspace. This is the default worker.
# Usage: cursor-task.sh <workspace-dir> <prompt-file> <output-json-file>
# Env: CURSOR_SWARM_MODEL (model id), SWARM_TASK_TIMEOUT (seconds, default 900)
# Exit: 0 ok · 124 timed out · 127 not installed · other = worker's own failure
set -uo pipefail

WORKSPACE="${1:?usage: cursor-task.sh <workspace-dir> <prompt-file> <out-file>}"
PROMPT_FILE="${2:?missing prompt file}"
OUT_FILE="${3:?missing output file}"
MODEL="${CURSOR_SWARM_MODEL:-cursor-grok-4.6-medium}"
TIMEOUT="${SWARM_TASK_TIMEOUT:-900}"

if ! command -v cursor-agent >/dev/null 2>&1; then
  echo "cursor-agent not found on PATH. Run: curl https://cursor.com/install -fsS | bash" >&2
  exit 127
fi
[ -d "$WORKSPACE" ] || { echo "workspace not a directory: $WORKSPACE" >&2; exit 2; }
[ -s "$PROMPT_FILE" ] || { echo "prompt file missing or empty: $PROMPT_FILE" >&2; exit 2; }

cursor-agent -p \
  --model "$MODEL" \
  --output-format json \
  --force \
  --workspace "$WORKSPACE" \
  "$(cat "$PROMPT_FILE")" > "$OUT_FILE" 2>&1 &
PID=$!

# macOS has no coreutils `timeout`; poll instead.
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
