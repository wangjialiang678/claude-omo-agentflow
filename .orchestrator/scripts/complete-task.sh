#!/bin/bash
# 标记任务完成
# 用法: ./complete-task.sh <task-id> [result-file-path]

set -euo pipefail

POOL_FILE=".orchestrator/tasks/task-pool.json"
LOCK_DIR=".orchestrator/tasks/task-pool.lock.d"
TASK_ID="$1"
RESULT_FILE="${2:-}"

lock_acquire() {
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do sleep 0.1; done
}
lock_release() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

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
