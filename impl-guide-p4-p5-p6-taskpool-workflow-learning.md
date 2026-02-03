# 实施指南 P4+P5+P6: 任务池、工作流引擎与知识积累

> **阶段**: P4 (任务池) + P5 (工作流引擎) + P6 (知识积累)
> **前置依赖**: P1 (自动继续) + P2 (代理定义)
> **关联**: plan-and-spec.md Section 六-八

---

## Part A: P4 — 任务池

### Step 1: 创建任务池管理脚本

#### .orchestrator/scripts/create-pool.sh

```bash
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
```

#### .orchestrator/scripts/claim-task.sh

```bash
#!/bin/bash
# 原子认领任务
# 用法: ./claim-task.sh <worker-id> [agent-filter]
# agent-filter: 可选，只认领指定 agent 的任务

set -euo pipefail

POOL_FILE=".orchestrator/tasks/task-pool.json"
LOCK_FILE=".orchestrator/tasks/task-pool.lock"
WORKER_ID="$1"
AGENT_FILTER="${2:-}"

if [ ! -f "$POOL_FILE" ]; then
  echo "No task pool found" >&2
  exit 1
fi

# macOS 兼容: 使用 mkdir 作为锁
lock_acquire() {
  while ! mkdir "$LOCK_FILE.d" 2>/dev/null; do
    sleep 0.1
  done
}

lock_release() {
  rmdir "$LOCK_FILE.d" 2>/dev/null || true
}

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
```

#### .orchestrator/scripts/complete-task.sh

```bash
#!/bin/bash
# 标记任务完成
# 用法: ./complete-task.sh <task-id> [result-file-path]

set -euo pipefail

POOL_FILE=".orchestrator/tasks/task-pool.json"
LOCK_FILE=".orchestrator/tasks/task-pool.lock"
TASK_ID="$1"
RESULT_FILE="${2:-}"

lock_acquire() {
  while ! mkdir "$LOCK_FILE.d" 2>/dev/null; do sleep 0.1; done
}
lock_release() {
  rmdir "$LOCK_FILE.d" 2>/dev/null || true
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
```

#### .orchestrator/scripts/release-timeout.sh

```bash
#!/bin/bash
# 释放超时任务
# 用法: ./release-timeout.sh [timeout-seconds]

set -euo pipefail

POOL_FILE=".orchestrator/tasks/task-pool.json"
LOCK_FILE=".orchestrator/tasks/task-pool.lock"
TIMEOUT="${1:-300}"

if [ ! -f "$POOL_FILE" ]; then
  exit 0
fi

lock_acquire() {
  while ! mkdir "$LOCK_FILE.d" 2>/dev/null; do sleep 0.1; done
}
lock_release() {
  rmdir "$LOCK_FILE.d" 2>/dev/null || true
}

lock_acquire
trap lock_release EXIT

# jq 的 now 和时间计算在某些版本不支持 fromdateiso8601
# 用 shell 时间比较
CURRENT_TIME=$(date +%s)

# 读取所有 claimed 任务
jq -r '.tasks[] | select(.status == "claimed") | "\(.id) \(.claimed_at)"' "$POOL_FILE" | \
while read -r id claimed_at; do
  if [ -n "$claimed_at" ] && [ "$claimed_at" != "null" ]; then
    # 将 ISO 时间转为 epoch (macOS 兼容)
    if command -v gdate &>/dev/null; then
      CLAIMED_EPOCH=$(gdate -d "$claimed_at" +%s 2>/dev/null || echo "0")
    else
      CLAIMED_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$claimed_at" +%s 2>/dev/null || echo "0")
    fi
    ELAPSED=$((CURRENT_TIME - CLAIMED_EPOCH))
    if [ "$ELAPSED" -gt "$TIMEOUT" ]; then
      jq --arg id "$id" \
        '.tasks |= map(
          if .id == $id
          then .status = "pending" | .claimed_by = null | .claimed_at = null
          else . end
        )' "$POOL_FILE" > "$POOL_FILE.tmp"
      mv "$POOL_FILE.tmp" "$POOL_FILE"
      echo "Released timeout task: $id (${ELAPSED}s > ${TIMEOUT}s)"
    fi
  fi
done
```

#### .orchestrator/scripts/pool-status.sh

```bash
#!/bin/bash
# 查看任务池状态

POOL_FILE=".orchestrator/tasks/task-pool.json"

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
```

### Step 2: 设置权限

```bash
chmod +x .orchestrator/scripts/*.sh
```

### Step 3: P4 验收测试

```bash
echo "=== P4 Tests ==="

# 创建测试任务池
cat << 'EOF' > /tmp/test-tasks.txt
backend-coder: Fix type errors in auth.ts
frontend-coder: Add dark mode toggle
backend-coder: Write API endpoint
EOF
.orchestrator/scripts/create-pool.sh test-pool /tmp/test-tasks.txt
echo "PASS: pool created"

# 认领
TASK=$(.orchestrator/scripts/claim-task.sh worker-1)
echo "$TASK" | jq -r .id | grep -q "task-001" && echo "PASS: claimed task-001" || echo "FAIL"

# 状态
.orchestrator/scripts/pool-status.sh | grep -q "Pending: 2" && echo "PASS: 2 pending" || echo "FAIL"

# 完成
.orchestrator/scripts/complete-task.sh task-001 ".orchestrator/results/task-001.json"
.orchestrator/scripts/pool-status.sh | grep -q "Completed: 1" && echo "PASS: 1 completed" || echo "FAIL"

# 清理
echo '{"pool_id":"empty","tasks":[]}' > .orchestrator/tasks/task-pool.json
rm /tmp/test-tasks.txt
echo "=== P4 Done ==="
```

---

## Part B: P5 — 工作流引擎

### Step 1: 创建 Pipeline 预设

创建以下 4 个 YAML 文件到 `.orchestrator/workflows/`:

**review.yaml**, **implement.yaml**, **research.yaml**, **debug.yaml**

完整内容见设计文档 `claude-omo-agentflow-v2.md` Section 4.4。

### Step 2: 更新 CLAUDE.md 工作流指令

在 CLAUDE.md 中添加：

```markdown
## 工作流引擎

### 可用的 Pipeline 预设

| 预设 | 阶段 | 触发方式 |
|------|------|---------|
| review | explore → review → fix → verify | "按 review 流水线审查 {target}" |
| implement | plan → implement → review | "按 implement 流水线实现 {feature}" |
| research | explore → research → summarize | "按 research 流水线调研 {topic}" |
| debug | explore → analyze → fix | "按 debug 流水线修复 {bug}" |

### 执行模式

| 模式 | 触发方式 | 说明 |
|------|---------|------|
| Pipeline | "按 {预设} 流水线..." | 多阶段链式执行 |
| Autopilot | "@plan {需求}" | planner 规划 → 自动执行 |
| Swarm | "并行处理..." | 多 worker 并行执行任务池 |

### 工作流状态管理

当工作流开始时：
1. 写入 `.orchestrator/state/workflow-state.json`（active=true）
2. 按 stages 顺序执行，每完成一个更新 completed_stages
3. Stop Hook 读取状态，阻止在未完成时停止
4. 所有 stages 完成后，设置 active=false

当使用 Swarm 模式时：
1. 将任务写入 `.orchestrator/tasks/task-pool.json`
2. 启动多个子代理（background task）
3. 每个子代理调用 claim-task.sh 认领任务
4. Stop Hook 检查 task-pool 中是否有未完成任务
```

### Step 3: 工作流执行示例

#### Pipeline 模式示例对话

```
用户: 按 review 流水线审查 src/auth/

主代理:
1. 读取 .orchestrator/workflows/review.yaml
2. 设置 workflow-state.json:
   {
     "active": true,
     "mode": "pipeline",
     "workflow": "review",
     "current_stage": "explore",
     "pending_stages": ["review", "fix", "verify"],
     "completed_stages": [],
     "target": "src/auth/"
   }
3. 委派 explorer 子代理搜索 src/auth/
4. → Stop Hook 阻止停止 (3 stages pending)
5. explorer 完成，更新 state:
   current_stage: "review", completed_stages: ["explore"]
6. 委派 reviewer 子代理审查
7. → Stop Hook 阻止停止 (2 stages pending)
8. ... 重复直到 verify 完成
9. 设置 active: false
10. → Stop Hook 允许停止
```

### Step 4: P5 验收测试

```bash
echo "=== P5 Tests ==="

# Pipeline YAML 存在
for wf in review implement research debug; do
  test -f ".orchestrator/workflows/$wf.yaml" && echo "PASS: $wf.yaml" || echo "FAIL: $wf.yaml"
done

# 工作流状态文件格式正确
echo '{"active":true,"mode":"pipeline","current_stage":"explore","pending_stages":["review"],"completed_stages":[]}' \
  > .orchestrator/state/workflow-state.json

# Stop Hook 应阻止
RESULT=$(echo '{"stop_hook_active":false}' | .claude/hooks/stop.sh 2>/dev/null)
echo "$RESULT" | jq -r '.decision' | grep -q "block" && echo "PASS: blocks on active workflow" || echo "FAIL"

# 设为非活跃
echo '{"active":false}' > .orchestrator/state/workflow-state.json

# Stop Hook 应允许
echo '{"stop_hook_active":false}' | .claude/hooks/stop.sh > /dev/null 2>&1
echo "exit code: $? (expect 0)"

echo "=== P5 Done ==="
```

---

## Part C: P6 — 知识积累

### Step 1: 创建模板文件

#### .orchestrator/learnings/decisions.md

```markdown
# Decision Log

Record all significant technical decisions here.

## Format

### YYYY-MM-DD: Decision Title
- **Context**: Why this decision was needed
- **Decision**: What was decided
- **Rationale**: Why this option was chosen
- **Alternatives**: Other options considered
- **Impact**: Consequences of this decision
```

#### .orchestrator/learnings/learnings.md

```markdown
# Learnings Log

Record lessons learned from tasks, debugging, and problem-solving.

## Format

### YYYY-MM-DD: Learning Title
- **Scenario**: When/where this happened
- **Problem**: What went wrong or was surprising
- **Solution**: How it was resolved
- **Takeaway**: What to do differently next time
```

### Step 2: 更新代理 Prompt 添加经验记录

在 `reviewer.md` 和 `backend-coder.md` 的 Rules 章节末尾添加：

```markdown
## Knowledge Recording
- After completing a task, if you made a significant technical decision,
  append it to `.orchestrator/learnings/decisions.md`
- If you encountered an unexpected issue and solved it,
  append the learning to `.orchestrator/learnings/learnings.md`
- Keep entries concise (3-5 lines each)
```

### Step 3: P6 验收测试

```bash
echo "=== P6 Tests ==="

test -f .orchestrator/learnings/decisions.md && echo "PASS: decisions.md" || echo "FAIL"
test -f .orchestrator/learnings/learnings.md && echo "PASS: learnings.md" || echo "FAIL"

# 代理包含知识记录指令
grep -q "Knowledge Recording\|learnings" .claude/agents/reviewer.md \
  && echo "PASS: reviewer has learning rules" || echo "WARN: reviewer missing learning rules"

echo "=== P6 Done ==="
```

---

## 完整端到端验收

以上所有阶段完成后，运行完整的端到端测试：

```bash
echo "==============================="
echo "  Full System Integration Test"
echo "==============================="

# 1. 目录结构
echo "--- Directory Structure ---"
for d in .claude/hooks/lib .claude/agents .orchestrator/plans .orchestrator/tasks .orchestrator/results .orchestrator/state .orchestrator/workflows .orchestrator/learnings .orchestrator/scripts; do
  test -d "$d" && echo "  ✓ $d" || echo "  ✗ $d"
done

# 2. Hooks
echo "--- Hooks ---"
for f in stop.sh subagent-stop.sh pre-compact.sh; do
  test -x ".claude/hooks/$f" && echo "  ✓ $f (executable)" || echo "  ✗ $f"
done

# 3. Agents
echo "--- Agents ---"
for a in planner backend-coder frontend-coder reviewer researcher explorer doc-writer; do
  test -f ".claude/agents/$a.md" && echo "  ✓ $a.md" || echo "  ✗ $a.md"
done

# 4. CCR
echo "--- CCR ---"
which ccr >/dev/null 2>&1 && echo "  ✓ ccr installed" || echo "  ✗ ccr not found"
test -f ~/.claude-code-router/config.json && echo "  ✓ config.json" || echo "  ✗ config.json"

# 5. Workflows
echo "--- Workflows ---"
for w in review implement research debug; do
  test -f ".orchestrator/workflows/$w.yaml" && echo "  ✓ $w.yaml" || echo "  ✗ $w.yaml"
done

# 6. Scripts
echo "--- Scripts ---"
for s in create-pool.sh claim-task.sh complete-task.sh release-timeout.sh pool-status.sh; do
  test -x ".orchestrator/scripts/$s" && echo "  ✓ $s" || echo "  ✗ $s"
done

# 7. Stop Hook behavior
echo "--- Stop Hook ---"
echo '{"stop_hook_active":false}' | .claude/hooks/stop.sh > /dev/null 2>&1 && echo "  ✓ exits cleanly when idle" || echo "  ✗ stop hook error"

echo ""
echo "==============================="
echo "  Integration test complete"
echo "==============================="
```
