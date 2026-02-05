#!/bin/bash
# 创建任务池
# 用法: ./create-pool.sh <pool-name> <task-descriptions-file>
# task-descriptions-file 每行格式: agent-name: description

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <pool-name> <task-descriptions-file>" >&2
  echo "  task-descriptions-file: each line format: agent-name: description" >&2
  exit 1
fi

POOL_NAME="$1"
TASKS_FILE="$2"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$PROJECT_ROOT/.claude/agentflow/scripts/path-resolver.sh" 2>/dev/null || true
TASKS_DIR="$(resolve_path "tasks" 2>/dev/null || echo ".orchestrator/tasks")"
POOL_FILE="$TASKS_DIR/task-pool.json"

if [ ! -f "$TASKS_FILE" ]; then
  echo "Error: tasks file '$TASKS_FILE' not found" >&2
  exit 1
fi

mkdir -p "$TASKS_DIR"

TASKS_JSON="[]"
COUNTER=1

while IFS= read -r line || [ -n "$line" ]; do
  # skip empty lines and comments
  [ -z "$line" ] && continue
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  # must contain a colon separator
  if [[ "$line" != *:* ]]; then
    echo "Warning: skipping malformed line (no colon): $line" >&2
    continue
  fi
  agent="${line%%:*}"
  desc="${line#*:}"
  agent=$(echo "$agent" | xargs)  # trim whitespace
  desc=$(echo "$desc" | xargs)
  # skip if agent or description is empty after trimming
  if [ -z "$agent" ] || [ -z "$desc" ]; then
    echo "Warning: skipping line with empty agent or description: $line" >&2
    continue
  fi
  TASK_ID=$(printf "task-%03d" $COUNTER)
  TASKS_JSON=$(echo "$TASKS_JSON" | jq \
    --arg id "$TASK_ID" \
    --arg agent "$agent" \
    --arg desc "$desc" \
    '. + [{
      "id": $id,
      "description": $desc,
      "agent": $agent,
      "status": "pending",
      "depends_on": [],
      "claimed_by": null,
      "claimed_at": null,
      "completed_at": null,
      "result_file": null
    }]')
  COUNTER=$((COUNTER + 1))
done < "$TASKS_FILE"

jq -n \
  --arg pool_id "$POOL_NAME" \
  --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson tasks "$TASKS_JSON" \
  '{pool_id:$pool_id, created_at:$created_at, tasks:$tasks}' \
  > "$POOL_FILE"

echo "Created pool '$POOL_NAME' with $((COUNTER - 1)) tasks"
