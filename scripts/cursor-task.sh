#!/usr/bin/env bash
# Run one headless Cursor Agent task (Grok 4.6 Medium) against a workspace.
# Usage: cursor-task.sh <workspace-dir> <prompt-file> <output-json-file>
set -euo pipefail

WORKSPACE="$1"
PROMPT_FILE="$2"
OUT_FILE="$3"
MODEL="${CURSOR_SWARM_MODEL:-cursor-grok-4.6-medium}"

if ! command -v cursor-agent >/dev/null 2>&1; then
  echo "cursor-agent not found on PATH. Run: curl https://cursor.com/install -fsS | bash" >&2
  exit 127
fi

cursor-agent -p \
  --model "$MODEL" \
  --output-format json \
  --force \
  --workspace "$WORKSPACE" \
  "$(cat "$PROMPT_FILE")" > "$OUT_FILE" 2>&1

cat "$OUT_FILE"
