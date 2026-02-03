# 实施指南 P0+P1: 基础骨架与自动继续机制

> **阶段**: P0 (基础骨架) + P1 (自动继续)
> **前置依赖**: 无
> **关联**: plan-and-spec.md, claude-omo-agentflow-v2.md

---

## Step 1: 创建目录结构

```bash
# 在项目根目录执行
mkdir -p .claude/hooks/lib
mkdir -p .claude/agents
mkdir -p .orchestrator/{plans,tasks,results,state,workflows,learnings}
mkdir -p .orchestrator/scripts
mkdir -p .orchestrator/state/snapshots
```

## Step 2: 创建 Hook 工具库

### .claude/hooks/lib/json-utils.sh

```bash
#!/bin/bash
# JSON 工具函数

json_get() {
  echo "$1" | jq -r ".$2 // empty"
}

json_get_default() {
  echo "$1" | jq -r ".$2 // \"$3\""
}

json_block_decision() {
  local reason="$1"
  cat << EOF
{
  "decision": "block",
  "reason": "$reason"
}
EOF
}
```

### .claude/hooks/lib/loop-guard.sh

```bash
#!/bin/bash
# 四层循环防护

GUARD_STATE_DIR=".orchestrator/state"

check_force_stop() {
  if [ -f /tmp/FORCE_STOP ]; then
    rm -f /tmp/FORCE_STOP
    return 0  # 应强制停止
  fi
  return 1  # 继续
}

check_max_retries() {
  local max="${1:-5}"
  local file="$GUARD_STATE_DIR/stop-retries.txt"
  mkdir -p "$GUARD_STATE_DIR"
  local count=$(cat "$file" 2>/dev/null || echo "0")
  if [ "$count" -ge "$max" ]; then
    echo "0" > "$file"
    return 0  # 已超限
  fi
  echo $((count + 1)) > "$file"
  return 1  # 未超限
}

check_timeout() {
  local timeout="${1:-300}"
  local file="$GUARD_STATE_DIR/stop-start-time.txt"
  mkdir -p "$GUARD_STATE_DIR"
  if [ -f "$file" ]; then
    local start=$(cat "$file")
    local elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -gt "$timeout" ]; then
      rm -f "$file" "$GUARD_STATE_DIR/stop-retries.txt"
      return 0  # 已超时
    fi
  else
    date +%s > "$file"
  fi
  return 1  # 未超时
}

cleanup_guard_state() {
  rm -f "$GUARD_STATE_DIR/stop-retries.txt" "$GUARD_STATE_DIR/stop-start-time.txt"
}
```

### .claude/hooks/lib/state-manager.sh

```bash
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
  echo "$state" | jq -r '.pending_stages | length // 0'
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
```

## Step 3: 创建 Stop Hook

### .claude/hooks/stop.sh

```bash
#!/bin/bash
# 自动继续机制 - JSON Decision 模式 + 四层循环防护
set -euo pipefail

HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$HOOK_DIR/lib/loop-guard.sh" 2>/dev/null || true
source "$HOOK_DIR/lib/state-manager.sh" 2>/dev/null || true
source "$HOOK_DIR/lib/json-utils.sh" 2>/dev/null || true

# 读取输入
INPUT=$(cat)
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")

# === 防护层 1: stop_hook_active ===
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# === 防护层 2: 紧急退出 ===
if check_force_stop 2>/dev/null; then
  exit 0
fi

# === 防护层 3: 最大重试 ===
if check_max_retries 5 2>/dev/null; then
  exit 0
fi

# === 防护层 4: 超时 ===
if check_timeout 300 2>/dev/null; then
  exit 0
fi

# === 检查 1: 工作流状态 ===
if is_workflow_active 2>/dev/null; then
  PENDING=$(get_pending_stages 2>/dev/null || echo "0")
  CURRENT=$(get_current_stage 2>/dev/null || echo "unknown")
  if [ "$PENDING" -gt 0 ]; then
    json_block_decision "工作流进行中。当前阶段: $CURRENT，剩余 $PENDING 个阶段。请继续执行。"
    exit 0
  fi
fi

# === 检查 2: 任务池 ===
PENDING_TASKS=$(count_pending_tasks 2>/dev/null || echo "0")
if [ "$PENDING_TASKS" -gt 0 ]; then
  json_block_decision "任务池中还有 $PENDING_TASKS 个未完成任务。请继续处理。"
  exit 0
fi

# === 检查 3: 计划 TODO ===
INCOMPLETE=$(count_incomplete_todos 2>/dev/null || echo "0")
if [ "$INCOMPLETE" -gt 0 ]; then
  json_block_decision "计划中还有 $INCOMPLETE 个未完成的 TODO。请继续执行。"
  exit 0
fi

# === 全部完成 ===
cleanup_guard_state 2>/dev/null || true
exit 0
```

## Step 4: 创建 SubagentStop Hook

### .claude/hooks/subagent-stop.sh

```bash
#!/bin/bash
# 子代理完成追踪
set -euo pipefail

INPUT=$(cat)
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // "unknown"' 2>/dev/null || echo "unknown")
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "unknown"' 2>/dev/null || echo "unknown")

mkdir -p .orchestrator/results
echo "{\"agent_id\":\"$AGENT_ID\",\"agent_type\":\"$AGENT_TYPE\",\"completed_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
  >> .orchestrator/results/completions.jsonl

exit 0
```

## Step 5: 创建 PreCompact Hook

### .claude/hooks/pre-compact.sh

```bash
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
```

## Step 6: 创建 settings.json

### .claude/settings.json

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/stop.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/subagent-stop.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/pre-compact.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

## Step 7: 初始化状态文件

```bash
echo '{"active":false}' > .orchestrator/state/workflow-state.json
echo '{"pool_id":"empty","tasks":[]}' > .orchestrator/tasks/task-pool.json
```

## Step 8: 设置权限

```bash
chmod +x .claude/hooks/stop.sh
chmod +x .claude/hooks/subagent-stop.sh
chmod +x .claude/hooks/pre-compact.sh
chmod +x .claude/hooks/lib/*.sh
```

## Step 9: 验收测试

```bash
# P0 测试: 目录和文件存在
echo "=== P0 Tests ==="
for d in .claude/hooks/lib .claude/agents .orchestrator/plans .orchestrator/tasks .orchestrator/results .orchestrator/state .orchestrator/workflows .orchestrator/learnings; do
  test -d "$d" && echo "PASS: $d" || echo "FAIL: $d"
done

for f in .claude/hooks/stop.sh .claude/hooks/subagent-stop.sh .claude/hooks/pre-compact.sh .claude/settings.json; do
  test -f "$f" && echo "PASS: $f" || echo "FAIL: $f"
done

# P1 测试: Stop Hook 行为
echo ""
echo "=== P1 Tests ==="

# 测试 1: 无活跃工作时允许停止
echo '{"stop_hook_active":false}' | .claude/hooks/stop.sh > /dev/null 2>&1
echo "exit code: $? (expect 0)"

# 测试 2: 有 TODO 时阻止
echo "- [ ] task 1" > .orchestrator/plans/current-plan.md
RESULT=$(echo '{"stop_hook_active":false}' | .claude/hooks/stop.sh 2>/dev/null)
echo "$RESULT" | jq -r '.decision' | grep -q "block" && echo "PASS: blocks on TODO" || echo "FAIL: should block on TODO"
rm .orchestrator/plans/current-plan.md

# 测试 3: stop_hook_active 防重复
RESULT=$(echo '{"stop_hook_active":true}' | .claude/hooks/stop.sh 2>/dev/null)
echo "exit code: $? (expect 0, no block output)"

# 测试 4: 紧急退出
echo "- [ ] task 1" > .orchestrator/plans/current-plan.md
touch /tmp/FORCE_STOP
echo '{"stop_hook_active":false}' | .claude/hooks/stop.sh > /dev/null 2>&1
echo "exit code: $? (expect 0, force stop)"
test ! -f /tmp/FORCE_STOP && echo "PASS: FORCE_STOP removed" || echo "FAIL: FORCE_STOP still exists"
rm -f .orchestrator/plans/current-plan.md

# 清理测试状态
rm -f .orchestrator/state/stop-retries.txt .orchestrator/state/stop-start-time.txt
echo ""
echo "=== Done ==="
```
