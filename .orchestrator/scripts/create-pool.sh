#!/bin/bash
# 创建任务池
# 用法: ./create-pool.sh <pool-name> <task-descriptions-file>
# task-descriptions-file 每行格式: agent-name: description

set -euo pipefail

POOL_NAME="$1"
TASKS_FILE="$2"
POOL_FILE=".orchestrator/tasks/task-pool.json"

mkdir -p .orchestrator/tasks

TASKS_JSON="[]"
COUNTER=1

while IFS=: read -r agent desc; do
  agent=$(echo "$agent" | xargs)  # trim whitespace
  desc=$(echo "$desc" | xargs)
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

cat << EOF > "$POOL_FILE"
{
  "pool_id": "$POOL_NAME",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "tasks": $TASKS_JSON
}
EOF

echo "Created pool '$POOL_NAME' with $((COUNTER - 1)) tasks"
