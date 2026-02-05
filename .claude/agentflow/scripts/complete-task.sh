#!/bin/bash
# 标记任务完成
# 用法: ./complete-task.sh <task-id> [result-file-path]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$PROJECT_ROOT/.claude/agentflow/scripts/path-resolver.sh" 2>/dev/null || true
TASKS_DIR="$(resolve_path "tasks" 2>/dev/null || echo ".orchestrator/tasks")"
POOL_FILE="$TASKS_DIR/task-pool.json"
LOCK_DIR="$TASKS_DIR/task-pool.lock.d"
TASK_ID="$1"
RESULT_FILE="${2:-}"

source "$SCRIPT_DIR/lib/file-lock.sh"

lock_acquire
trap lock_release EXIT

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg id "$TASK_ID" --arg now "$NOW" --arg result "$RESULT_FILE" \
  '.tasks |= map(
    if .id == $id
    then .status = "completed" | .completed_at = $now | .result_file = $result
    else . end
  )' "$POOL_FILE" > "$POOL_FILE.tmp"
mv "$POOL_FILE.tmp" "$POOL_FILE"

echo "Task $TASK_ID completed"
