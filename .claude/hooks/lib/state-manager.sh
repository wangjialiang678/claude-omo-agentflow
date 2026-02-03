#!/bin/bash
# 状态管理函数

STATE_DIR=".orchestrator/state"

get_workflow_state() {
  local file="$STATE_DIR/workflow-state.json"
  if [ -f "$file" ]; then
    cat "$file"
  else
    echo '{"active":false}'
  fi
}

is_workflow_active() {
  local state=$(get_workflow_state)
  local active=$(echo "$state" | jq -r '.active // false')
  [ "$active" = "true" ]
}

get_pending_stages() {
  local state=$(get_workflow_state)
  echo "$state" | jq -r '(.pending_stages // []) | length'
}

get_current_stage() {
  local state=$(get_workflow_state)
  echo "$state" | jq -r '.current_stage // "none"'
}

count_pending_tasks() {
  local pool=".orchestrator/tasks/task-pool.json"
  if [ -f "$pool" ]; then
    jq '[.tasks[] | select(.status == "pending" or .status == "claimed")] | length' "$pool" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

count_incomplete_todos() {
  local plan=".orchestrator/plans/current-plan.md"
  if [ -f "$plan" ]; then
    grep -c '^\- \[ \]' "$plan" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}
