# 实施计划与规格说明

> **版本**: v1.0
> **日期**: 2026-02-03
> **关联设计文档**: claude-omo-agentflow-v2.md
> **STATUS**: PENDING

---

## 一、实施总览

### 1.1 分阶段交付策略

采用**渐进式交付**，每个阶段都是独立可用的最小系统：

| 阶段 | 名称 | 核心交付 | 前置依赖 | 验收标准 |
|------|------|---------|---------|---------|
| **P0** | 基础骨架 | 目录结构 + settings.json + 空 Hook 脚本 | 无 | 目录存在，Hook 可执行 |
| **P1** | 自动继续 | Stop Hook + 循环防护 + PreCompact | P0 | 主代理在有 TODO 时不停止，4 层防护全部生效 |
| **P2** | 代理定义 | 7 个代理 .md 文件 + AGENTS.md + CLAUDE.md 编排规则 | P0 | 每个代理可独立调用并返回正确格式结果 |
| **P3** | 模型路由 | CCR 安装 + config.json + 代理 CCR 标签 | P2 | 子代理请求被路由到指定模型，主代理走原生 |
| **P4** | 任务池 | task-pool.json + claim/release 脚本 + 超时机制 | P1 | 多 worker 可原子认领任务，超时自动释放 |
| **P5** | 工作流引擎 | 4 个 Pipeline YAML 预设 + Autopilot/Swarm 模式 | P2, P4 | Pipeline 完整执行，Stop Hook 驱动推进 |
| **P6** | 知识积累 | decisions.md + learnings.md + 技能模板 | P5 | 任务完成后自动记录决策和经验 |

### 1.2 验收流程

每个阶段完成后：
1. 运行该阶段的验收测试（见各阶段详细 spec）
2. 确认没有回归（前置阶段功能仍正常）
3. 标记阶段为 DONE

---

## 二、P0: 基础骨架

### 2.1 任务清单

- [ ] 创建 `.claude/hooks/` 目录
- [ ] 创建 `.claude/hooks/lib/` 目录
- [ ] 创建 `.claude/agents/` 目录
- [ ] 创建 `.orchestrator/` 及其子目录（plans/, tasks/, results/, state/, workflows/, learnings/）
- [ ] 创建空的 `.claude/hooks/stop.sh`（仅 `exit 0`）
- [ ] 创建空的 `.claude/hooks/subagent-stop.sh`（仅 `exit 0`）
- [ ] 创建空的 `.claude/hooks/pre-compact.sh`（仅 `exit 0`）
- [ ] 设置所有 Hook 脚本 `chmod +x`
- [ ] 创建 `.claude/settings.json`，注册 3 个 Hook
- [ ] 创建 `.orchestrator/state/workflow-state.json`（初始空状态）
- [ ] 创建 `.orchestrator/tasks/task-pool.json`（初始空池）

### 2.2 验收标准

```bash
# 目录存在
test -d .claude/hooks/lib && echo "PASS"
test -d .claude/agents && echo "PASS"
test -d .orchestrator/plans && echo "PASS"
test -d .orchestrator/tasks && echo "PASS"
test -d .orchestrator/results && echo "PASS"
test -d .orchestrator/state && echo "PASS"
test -d .orchestrator/workflows && echo "PASS"
test -d .orchestrator/learnings && echo "PASS"

# Hook 可执行
test -x .claude/hooks/stop.sh && echo "PASS"
test -x .claude/hooks/subagent-stop.sh && echo "PASS"
test -x .claude/hooks/pre-compact.sh && echo "PASS"

# settings.json 配置正确
jq '.hooks.Stop' .claude/settings.json && echo "PASS"
jq '.hooks.SubagentStop' .claude/settings.json && echo "PASS"
jq '.hooks.PreCompact' .claude/settings.json && echo "PASS"

# 空 Hook 不阻止（exit 0）
echo '{}' | .claude/hooks/stop.sh; echo "exit code: $?"  # 应该是 0
```

---

## 三、P1: 自动继续机制

### 3.1 任务清单

- [ ] 实现 `.claude/hooks/lib/json-utils.sh`（JSON 工具函数）
- [ ] 实现 `.claude/hooks/lib/loop-guard.sh`（循环防护函数）
- [ ] 实现 `.claude/hooks/lib/state-manager.sh`（状态管理函数）
- [ ] 实现 `.claude/hooks/stop.sh`（完整版，含四层防护 + 三项检查）
- [ ] 实现 `.claude/hooks/subagent-stop.sh`（完成追踪）
- [ ] 实现 `.claude/hooks/pre-compact.sh`（状态保存）
- [ ] 测试：紧急退出开关（`/tmp/FORCE_STOP`）
- [ ] 测试：最大重试次数（5 次后允许停止）
- [ ] 测试：超时机制（5 分钟后允许停止）
- [ ] 测试：`stop_hook_active` 防重复触发
- [ ] 测试：有 TODO 时阻止停止
- [ ] 测试：所有 TODO 完成后允许停止

### 3.2 lib/json-utils.sh 规格

```bash
#!/bin/bash
# 输入: JSON 字符串
# 输出: 提取的值

# json_get <json_string> <key> - 提取字段值
json_get() {
  echo "$1" | jq -r ".$2 // empty"
}

# json_get_default <json_string> <key> <default> - 带默认值提取
json_get_default() {
  echo "$1" | jq -r ".$2 // \"$3\""
}

# json_block_decision <reason> - 生成 block 决策 JSON
json_block_decision() {
  cat << EOF
{
  "decision": "block",
  "reason": "$1"
}
EOF
}
```

### 3.3 lib/loop-guard.sh 规格

```bash
#!/bin/bash
# 四层循环防护

GUARD_STATE_DIR=".orchestrator/state"

# check_force_stop - 检查紧急退出开关
# 返回: 0 = 应强制停止, 1 = 继续
check_force_stop() {
  if [ -f /tmp/FORCE_STOP ]; then
    rm -f /tmp/FORCE_STOP
    return 0
  fi
  return 1
}

# check_max_retries <max> - 检查重试次数
# 返回: 0 = 已超限, 1 = 未超限
check_max_retries() {
  local max="${1:-5}"
  local file="$GUARD_STATE_DIR/stop-retries.txt"
  local count=$(cat "$file" 2>/dev/null || echo "0")
  if [ "$count" -ge "$max" ]; then
    echo "0" > "$file"
    return 0
  fi
  echo $((count + 1)) > "$file"
  return 1
}

# check_timeout <seconds> - 检查超时
# 返回: 0 = 已超时, 1 = 未超时
check_timeout() {
  local timeout="${1:-300}"
  local file="$GUARD_STATE_DIR/stop-start-time.txt"
  if [ -f "$file" ]; then
    local start=$(cat "$file")
    local elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -gt "$timeout" ]; then
      rm -f "$file" "$GUARD_STATE_DIR/stop-retries.txt"
      return 0
    fi
  else
    date +%s > "$file"
  fi
  return 1
}

# cleanup_guard_state - 重置所有防护状态
cleanup_guard_state() {
  rm -f "$GUARD_STATE_DIR/stop-retries.txt" "$GUARD_STATE_DIR/stop-start-time.txt"
}
```

### 3.4 Stop Hook 行为矩阵

| 条件 | 预期行为 |
|------|---------|
| `stop_hook_active = true` | 立即 exit 0 |
| `/tmp/FORCE_STOP` 存在 | 删除文件, exit 0 |
| 重试次数 >= 5 | 重置计数, exit 0 |
| 超时 >= 300s | 清理状态, exit 0 |
| workflow-state.json active=true + pending>0 | 输出 block decision |
| task-pool.json 有 pending/claimed 任务 | 输出 block decision |
| current-plan.md 有 `- [ ]` | 输出 block decision |
| 以上均不满足 | 清理状态, exit 0 |

### 3.5 验收标准

```bash
# 测试 1: 有 TODO 时阻止
echo "- [ ] task 1" > .orchestrator/plans/current-plan.md
echo '{"stop_hook_active":false}' | .claude/hooks/stop.sh
# 输出应包含 "decision": "block"

# 测试 2: TODO 完成后允许停止
echo "- [x] task 1" > .orchestrator/plans/current-plan.md
echo '{"stop_hook_active":false}' | .claude/hooks/stop.sh
# exit code 应为 0，无 block output

# 测试 3: 紧急退出
touch /tmp/FORCE_STOP
echo '{"stop_hook_active":false}' | .claude/hooks/stop.sh
# exit code 应为 0
test ! -f /tmp/FORCE_STOP  # 文件应被删除

# 测试 4: stop_hook_active 防重复
echo '{"stop_hook_active":true}' | .claude/hooks/stop.sh
# exit code 应为 0，无 block output
```

---

## 四、P2: 代理定义

### 4.1 任务清单

- [ ] 创建 `.claude/agents/planner.md`
- [ ] 创建 `.claude/agents/backend-coder.md`
- [ ] 创建 `.claude/agents/frontend-coder.md`
- [ ] 创建 `.claude/agents/reviewer.md`
- [ ] 创建 `.claude/agents/researcher.md`
- [ ] 创建 `.claude/agents/explorer.md`
- [ ] 创建 `.claude/agents/doc-writer.md`
- [ ] 创建 `AGENTS.md`（代理注册表）
- [ ] 更新 `CLAUDE.md`（添加编排规则和委派策略）
- [ ] 测试每个代理可被 Claude Code 正常调用

### 4.2 代理 Prompt 规范

每个代理 `.md` 文件必须包含：

1. **YAML Frontmatter**:
   - `name`: 代理标识符（小写短横线）
   - `description`: 中文简介
   - `model`: Claude Code 原生模型声明
   - `tools`: 允许的工具列表

2. **CCR 标签**（如需路由）:
   - 位于正文第一行
   - 格式: `<CCR-SUBAGENT-MODEL>provider,model</CCR-SUBAGENT-MODEL>`

3. **Identity 章节**: 代理角色和身份

4. **Rules 章节**: 严格的行为约束
   - 文件权限限制（只读代理 NEVER modify）
   - 输出格式要求
   - 任务状态更新要求

5. **QA Enforcement 章节**（借鉴 OMO）:
   - 可执行验收标准
   - 防 AI-slop 约束

### 4.3 验收标准

```bash
# 每个代理文件存在
for agent in planner backend-coder frontend-coder reviewer researcher explorer doc-writer; do
  test -f ".claude/agents/$agent.md" && echo "PASS: $agent"
done

# YAML frontmatter 格式正确
for agent in .claude/agents/*.md; do
  head -1 "$agent" | grep -q "^---$" && echo "PASS: $(basename $agent) has frontmatter"
done

# AGENTS.md 存在
test -f AGENTS.md && echo "PASS"

# CLAUDE.md 包含编排规则
grep -q "代理委派策略" CLAUDE.md && echo "PASS"
```

---

## 五、P3: 模型路由

### 5.1 任务清单

- [ ] 安装 CCR: `npm i -g @musistudio/claude-code-router`
- [ ] 创建 `~/.claude-code-router/config.json`（使用 OpenRouter 模板）
- [ ] 设置环境变量 `OPENROUTER_API_KEY`
- [ ] 为 backend-coder 添加 CCR 标签（Codex）
- [ ] 为 frontend-coder 添加 CCR 标签（Gemini Pro）
- [ ] 为 reviewer 添加 CCR 标签（Codex）
- [ ] 为 researcher 添加 CCR 标签（Gemini Flash）
- [ ] 为 explorer 添加 CCR 标签（Gemini Flash）
- [ ] 为 doc-writer 添加 CCR 标签（Gemini Flash）
- [ ] 确认 planner 无标签（走原生 Opus）
- [ ] 启动 CCR 并验证状态
- [ ] 测试子代理路由是否生效
- [ ] 确认主代理未被路由

### 5.2 路由验证清单

| 测试 | 命令 | 预期日志 |
|------|------|---------|
| 主代理不路由 | 直接提问 | 无 CCR 日志 |
| backend-coder 路由到 Codex | 调用 backend-coder 子代理 | CCR 日志显示 → openai/gpt-5.2-codex |
| frontend-coder 路由到 Gemini | 调用 frontend-coder 子代理 | CCR 日志显示 → google/gemini-2.5-pro |
| explorer 路由到 Flash | 调用 explorer 子代理 | CCR 日志显示 → google/gemini-3-flash |
| planner 走原生 | 调用 planner 子代理 | 无 CCR 日志（走原生 API） |

### 5.3 验收标准

```bash
# CCR 运行中
ccr status | grep -q "Running" && echo "PASS"

# CCR 日志可查
test -d ~/.claude-code-router/logs && echo "PASS"

# 配置文件格式正确
jq '.Router.default' ~/.claude-code-router/config.json | grep -q "anthropic-native" && echo "PASS"
```

---

## 六、P4: 任务池

### 6.1 任务清单

- [ ] 实现 `.orchestrator/scripts/claim-task.sh`
- [ ] 实现 `.orchestrator/scripts/release-timeout.sh`
- [ ] 实现 `.orchestrator/scripts/complete-task.sh`
- [ ] 实现 `.orchestrator/scripts/create-pool.sh`（初始化任务池）
- [ ] 实现 `.orchestrator/scripts/pool-status.sh`（查看任务池状态）
- [ ] 确认 macOS 文件锁兼容方案（flock / mkdir）
- [ ] 测试原子认领（2 个 worker 并发认领同一任务）
- [ ] 测试超时释放
- [ ] 测试任务完成标记

### 6.2 脚本接口规格

#### create-pool.sh

```bash
# 用法: ./create-pool.sh <pool-name> <task-descriptions-file>
# task-descriptions-file 格式:
#   backend-coder: Fix auth.ts type errors
#   frontend-coder: Add dark mode toggle
#   backend-coder: Write API endpoint for theme

# 输出: 创建 .orchestrator/tasks/task-pool.json
```

#### claim-task.sh

```bash
# 用法: ./claim-task.sh <worker-id>
# 输出 (stdout): 被认领任务的 JSON
# 退出码: 0=成功认领, 1=无可用任务
```

#### complete-task.sh

```bash
# 用法: ./complete-task.sh <task-id> <result-file-path>
# 效果: 更新 task-pool.json 中该任务状态为 completed
```

#### release-timeout.sh

```bash
# 用法: ./release-timeout.sh [timeout-seconds]
# 默认 timeout: 300 (5分钟)
# 效果: 将超时的 claimed 任务重置为 pending
```

#### pool-status.sh

```bash
# 用法: ./pool-status.sh
# 输出:
#   Pool: feature-dark-mode
#   Total: 5 | Pending: 2 | Claimed: 1 | Completed: 2
```

### 6.3 验收标准

```bash
# 创建测试任务池
echo "backend-coder: task A
frontend-coder: task B
backend-coder: task C" > /tmp/test-tasks.txt
./create-pool.sh test-pool /tmp/test-tasks.txt

# 认领任务
TASK=$(./claim-task.sh worker-1)
echo "$TASK" | jq .id  # 应输出 task-001

# 并发认领不重复
TASK1=$(./claim-task.sh worker-1 &)
TASK2=$(./claim-task.sh worker-2 &)
wait
# TASK1 和 TASK2 应不同

# 超时释放
sleep 1
TIMEOUT=1 ./release-timeout.sh  # 1秒超时用于测试
./pool-status.sh  # claimed 应减少
```

---

## 七、P5: 工作流引擎

### 7.1 任务清单

- [ ] 创建 `.orchestrator/workflows/review.yaml`
- [ ] 创建 `.orchestrator/workflows/implement.yaml`
- [ ] 创建 `.orchestrator/workflows/research.yaml`
- [ ] 创建 `.orchestrator/workflows/debug.yaml`
- [ ] 更新 CLAUDE.md 添加工作流指令说明
- [ ] 测试 Pipeline 模式: review 流水线完整执行
- [ ] 测试 Autopilot 模式: planner 生成计划 → 自动执行
- [ ] 测试 Swarm 模式: 并行任务池执行

### 7.2 工作流指令格式

```markdown
## 工作流指令

用户可通过以下方式触发工作流：

### Pipeline 模式
- `按 review 流水线审查 <target>`
- `按 implement 流水线实现 <feature>`
- `按 research 流水线调研 <topic>`
- `按 debug 流水线修复 <bug>`

### Autopilot 模式
- `规划并实现 <feature>`
- `@plan <需求描述>` → 调用 planner → 自动执行计划

### Swarm 模式
- `并行修复所有 <问题类型>`
- `并行处理以下任务: <task1>, <task2>, ...`
```

### 7.3 工作流状态机

```json
// .orchestrator/state/workflow-state.json
{
  "active": true,
  "mode": "pipeline",          // pipeline | autopilot | swarm
  "workflow": "review",         // 预设名称
  "current_stage": "explore",   // 当前阶段
  "completed_stages": [],
  "pending_stages": ["review", "fix", "verify"],
  "started_at": "2026-02-03T10:00:00Z",
  "target": "src/auth/"         // 工作目标
}
```

### 7.4 验收标准

```bash
# YAML 预设存在且格式正确
for wf in review implement research debug; do
  test -f ".orchestrator/workflows/$wf.yaml" && echo "PASS: $wf"
done

# 工作流状态文件格式正确
echo '{"active":false}' > .orchestrator/state/workflow-state.json
jq . .orchestrator/state/workflow-state.json && echo "PASS"

# Pipeline 执行:
# 1. 触发 review 流水线
# 2. 观察 4 个阶段依次执行
# 3. 每个阶段完成后 Stop Hook 阻止停止
# 4. 最后一个阶段完成后允许停止
```

---

## 八、P6: 知识积累

### 8.1 任务清单

- [ ] 创建 `.orchestrator/learnings/decisions.md`（模板）
- [ ] 创建 `.orchestrator/learnings/learnings.md`（模板）
- [ ] 更新 CLAUDE.md 添加知识积累规则
- [ ] 在代理 prompt 中添加"完成后记录经验"指令
- [ ] 测试：任务完成后是否自动追加 decisions.md

### 8.2 知识记录规范

```markdown
## 决策记录格式

### {日期}: {决策标题}
- **背景**: 为什么需要做这个决策
- **决策**: 最终选择
- **理由**: 选择的原因
- **替代方案**: 考虑过的其他方案
- **影响**: 这个决策的后果
```

```markdown
## 经验记录格式

### {日期}: {经验标题}
- **场景**: 在什么情况下遇到的
- **问题**: 遇到了什么问题
- **解决方案**: 最终怎么解决的
- **教训**: 下次遇到类似情况应该怎么做
```

### 8.3 验收标准

```bash
# 模板文件存在
test -f .orchestrator/learnings/decisions.md && echo "PASS"
test -f .orchestrator/learnings/learnings.md && echo "PASS"

# 代理 prompt 包含经验记录指令
grep -q "learnings" .claude/agents/reviewer.md && echo "PASS"
```

---

## 九、风险登记簿

| ID | 风险 | 影响 | 概率 | 缓解措施 |
|----|------|------|------|---------|
| R1 | CCR 不稳定（705 issues） | 高 | 中 | 准备回退到 OpenRouter 直连方案 |
| R2 | Stop Hook 死循环 | 高 | 低 | 四层循环防护 |
| R3 | Codex 模型名变更 | 中 | 中 | 配置可调，不硬编码到代理定义 |
| R4 | macOS flock 不可用 | 低 | 高 | 用 mkdir 锁替代 |
| R5 | 上下文窗口溢出 | 中 | 中 | PreCompact Hook + 状态文件 |
| R6 | 子代理结果格式不一致 | 中 | 中 | 在代理 prompt 中严格约束输出格式 |
| R7 | OpenRouter 服务中断 | 高 | 低 | 配置 Foxcode 中转站作为备选 |
| R8 | Anthropic 封锁第三方路由 | 高 | 低 | 仅路由子代理，主代理走原生订阅 |

---

## 十、可配置项清单

以下参数设计为可配置，用户可根据需要调整：

| 参数 | 默认值 | 配置位置 | 说明 |
|------|--------|---------|------|
| 后端代码模型 | Codex | CCR config.json | 可改为 Opus |
| 前端代码模型 | Gemini Pro | CCR config.json | 可改为其他 |
| 调研模型 | Gemini Flash | CCR config.json | 可改为 Grok/DeepSeek |
| Stop Hook 最大重试 | 5 | stop.sh MAX_RETRIES | 增大=更持久 |
| Stop Hook 超时 | 300s | stop.sh TIMEOUT_SECONDS | |
| 任务池超时 | 300s | release-timeout.sh | |
| 最大并行 worker | 3 | 手动控制 | |
| Provider | OpenRouter | CCR config.json | 可切换 Foxcode/直连 |

---

> **下一步**: 此 plan 等待用户审批后进入 EXECUTE 模式。批准后将按 P0 → P6 顺序执行。
