#!/bin/bash
# 原子认领任务
# 用法: ./claim-task.sh <worker-id> [agent-filter]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$PROJECT_ROOT/.claude/agentflow/scripts/path-resolver.sh" 2>/dev/null || true
TASKS_DIR="$(resolve_path "tasks" 2>/dev/null || echo ".orchestrator/tasks")"
POOL_FILE="$TASKS_DIR/task-pool.json"
LOCK_DIR="$TASKS_DIR/task-pool.lock.d"
WORKER_ID="$1"
AGENT_FILTER="${2:-}"

source "$SCRIPT_DIR/lib/file-lock.sh"

if [ ! -f "$POOL_FILE" ]; then
  echo "No task pool found" >&2
  exit 1
fi

lock_acquire
trap lock_release EXIT

# 查找第一个 pending 任务
if [ -n "$AGENT_FILTER" ]; then
  TASK_ID=$(jq -r --arg agent "$AGENT_FILTER" \
    '.tasks[] | select(.status == "pending" and .agent == $agent) | .id' \
    "$POOL_FILE" | head -n 1)
else
  TASK_ID=$(jq -r '.tasks[] | select(.status == "pending") | .id' \
    "$POOL_FILE" | head -n 1)
fi

if [ -z "$TASK_ID" ] || [ "$TASK_ID" = "null" ]; then
  echo "No pending tasks" >&2
  exit 1
fi

# 标记为 claimed
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg id "$TASK_ID" --arg worker "$WORKER_ID" --arg now "$NOW" \
  '.tasks |= map(
    if .id == $id
    then .status = "claimed" | .claimed_by = $worker | .claimed_at = $now
    else . end
  )' "$POOL_FILE" > "$POOL_FILE.tmp"
mv "$POOL_FILE.tmp" "$POOL_FILE"

# 输出任务详情
jq --arg id "$TASK_ID" '.tasks[] | select(.id == $id)' "$POOL_FILE"
