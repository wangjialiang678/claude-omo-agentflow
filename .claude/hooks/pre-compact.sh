#!/bin/bash
# 上下文压缩前保存状态
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$HOOK_DIR/lib/state-manager.sh" 2>/dev/null || true

mkdir -p .orchestrator/state/snapshots
SNAPSHOT=".orchestrator/state/snapshots/$(date +%s).json"

WF_STATE=$(get_workflow_state 2>/dev/null || echo '{"active":false}')
TASKS=$(count_pending_tasks 2>/dev/null || echo "0")
TODOS=$(count_incomplete_todos 2>/dev/null || echo "0")

cat << EOF > "$SNAPSHOT"
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "workflow": $WF_STATE,
  "pending_tasks": $TASKS,
  "incomplete_todos": $TODOS
}
EOF

CURRENT=$(echo "$WF_STATE" | jq -r '.current_stage // "idle"' 2>/dev/null || echo "idle")
cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreCompact",
    "preserveContext": "工作流: $CURRENT。待处理任务: $TASKS。未完成TODO: $TODOS。"
  }
}
EOF

exit 0
