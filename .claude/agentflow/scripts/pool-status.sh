#!/bin/bash
# 查看任务池状态
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$PROJECT_ROOT/.claude/agentflow/scripts/path-resolver.sh" 2>/dev/null || true
TASKS_DIR="$(resolve_path "tasks" 2>/dev/null || echo ".orchestrator/tasks")"
POOL_FILE="$TASKS_DIR/task-pool.json"

if [ ! -f "$POOL_FILE" ]; then
  echo "No task pool found"
  exit 0
fi

POOL_ID=$(jq -r '.pool_id' "$POOL_FILE")
TOTAL=$(jq '.tasks | length' "$POOL_FILE")
PENDING=$(jq '[.tasks[] | select(.status == "pending")] | length' "$POOL_FILE")
CLAIMED=$(jq '[.tasks[] | select(.status == "claimed")] | length' "$POOL_FILE")
COMPLETED=$(jq '[.tasks[] | select(.status == "completed")] | length' "$POOL_FILE")

echo "Pool: $POOL_ID"
echo "Total: $TOTAL | Pending: $PENDING | Claimed: $CLAIMED | Completed: $COMPLETED"

if [ "$CLAIMED" -gt 0 ]; then
  echo ""
  echo "Claimed tasks:"
  jq -r '.tasks[] | select(.status == "claimed") | "  \(.id) [\(.agent)] → \(.claimed_by) since \(.claimed_at)"' "$POOL_FILE"
fi
