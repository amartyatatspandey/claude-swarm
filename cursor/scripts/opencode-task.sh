#!/usr/bin/env bash
# Run one headless OpenCode task against a workspace.
# Usage: opencode-task.sh <workspace-dir> <prompt-file> <output-file>
# Env: OPENCODE_SWARM_MODEL (provider/model id), SWARM_TASK_TIMEOUT (seconds, default 900)
# Exit: 0 ok · 124 timed out · 127 not installed · other = worker's own failure
set -uo pipefail

WORKSPACE="${1:?usage: opencode-task.sh <workspace-dir> <prompt-file> <out-file>}"
PROMPT_FILE="${2:?missing prompt file}"
OUT_FILE="${3:?missing output file}"
MODEL="${OPENCODE_SWARM_MODEL:-opencode/nemotron-3-ultra-free}"
TIMEOUT="${SWARM_TASK_TIMEOUT:-900}"

if ! command -v opencode >/dev/null 2>&1; then
  echo "opencode not found on PATH." >&2
  exit 127
fi
[ -d "$WORKSPACE" ] || { echo "workspace not a directory: $WORKSPACE" >&2; exit 2; }
[ -s "$PROMPT_FILE" ] || { echo "prompt file missing or empty: $PROMPT_FILE" >&2; exit 2; }

# opencode run has no --workspace flag — use --dir to set the run directory.
opencode run "$(cat "$PROMPT_FILE")" \
  --dir "$WORKSPACE" \
  --model "$MODEL" \
  --format json \
  --auto > "$OUT_FILE" 2>&1 &
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
