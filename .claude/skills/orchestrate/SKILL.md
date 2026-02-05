---
name: orchestrate
description: |
  掌天瓶：异构多代理掌天瓶系统。当用户需要多代理协作时自动触发：
  - 说"启用掌天瓶"、"orchestrate"、"多代理"、"并行处理"
  - 使用流水线指令（"按 review 流水线..."、"按 implement 流水线..."）
  - 说"@plan"触发 Autopilot 模式
  - 说"并行修复"、"swarm"触发 Swarm 模式
  关键词：掌天瓶、orchestrate、流水线、pipeline、swarm、autopilot、并行、多代理
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
  - Task
  - AskUserQuestion
---

# 掌天瓶 (Orchestrate) — 异构多代理系统

## 代理委派策略

当需要执行以下类型的任务时，使用对应的子代理：

| 任务类型 | 委派给 | 模型路由 | 权限 |
|---------|--------|---------|------|
| 后端代码实现 | backend-coder | Codex (via CCR) | Server-side only |
| 前端 UI/UX 实现 | frontend-coder | Gemini Pro (via CCR) | Client-side only |
| 代码审核/Review | reviewer | Codex (via CCR) | Read-only + test |
| 技术调研 | researcher | Gemini Flash (via CCR) | Read-only + web |
| 代码搜索/文件查找 | explorer | Gemini Flash (via CCR) | Read-only |
| 文档撰写 | doc-writer | Gemini Flash (via CCR) | .md only |
| 需求规划 | planner | Claude Opus (native) | Read-only |
| 核心代码 | 主代理自行处理 | Claude Opus (native) | Full |

完整注册表见 `.claude/agentflow/agents.md`。

## 三种执行模式

### Pipeline（流水线）

多阶段链式执行，每阶段委派给不同代理。

**触发方式**：
- "按 review 流水线审查 {target}"
- "按 implement 流水线实现 {feature}"
- "按 research 流水线调研 {topic}"
- "按 debug 流水线修复 {bug}"

**可用预设**（定义在 `.claude/agentflow/workflows/`）：

| 预设 | 阶段 |
|------|------|
| review | explore → review → fix → verify |
| implement | plan → implement → review |
| research | explore → research → summarize |
| debug | explore → analyze → fix |

**执行流程**：
1. 读取 `.claude/agentflow/workflows/{预设}.yaml`
2. 设置 workflow-state.json: `active=true`, 记录 stages
3. 按顺序委派每个 stage 给对应代理
4. 每个 stage 完成后更新 state
5. Stop Hook 自动阻止中途停止
6. 全部完成 → `active=false` → 允许停止

### Autopilot（自主模式）

planner 规划 → 自动按计划执行。

**触发方式**：
- "@plan {需求描述}"
- "规划并实现 {feature}"

**执行流程**：
1. 调用 planner 子代理生成 `current-plan.md`（含 TODO 列表）
2. 按 TODO 逐项委派给合适的代理
3. 每完成一项更新 checkbox
4. Stop Hook 检查未勾选 TODO → 阻止停止
5. 全部完成 → 允许停止

### Swarm（蜂群并行）

多 worker 从共享任务池并行处理。

**触发方式**：
- "并行修复所有 {问题类型}"
- "并行处理以下任务: {task1}, {task2}, ..."

**执行流程**：
1. 分解为原子任务，写入 task-pool.json
2. 启动多个子代理（background task）
3. 每个子代理调用 `claim-task.sh` 原子认领
4. 完成后调用 `complete-task.sh`
5. Stop Hook 检查 task-pool → 阻止停止
6. 全部完成 → 允许停止

**任务池脚本**（`.claude/agentflow/scripts/`）：
- `create-pool.sh <name> <tasks-file>` — 创建任务池
- `claim-task.sh <worker-id> [agent]` — 原子认领
- `complete-task.sh <task-id> [result]` — 标记完成
- `release-timeout.sh [seconds]` — 释放超时任务
- `pool-status.sh` — 查看状态

## 自动继续规则

掌天瓶启用时，Stop Hook 在以下条件阻止主代理停止：
- 工作流 active + 有 pending stages
- 任务池有 pending/claimed 任务
- 计划文档有未勾选 TODO

**紧急退出**：`touch /tmp/FORCE_STOP`

## 结果输出规范

所有子代理输出写入 `.claude/agentflow/results/`：
- 代码任务: `{task-id}.json`（含 verdict, issues, tests_passed）
- 调研任务: `{task-id}.md`（Markdown 报告）
- 搜索任务: `{task-id}.json`（文件列表和代码片段）

## 工作流状态管理

状态文件：`.claude/agentflow/state/workflow-state.json`

```json
{
  "active": true,
  "mode": "pipeline",
  "workflow": "review",
  "current_stage": "explore",
  "completed_stages": [],
  "pending_stages": ["review", "fix", "verify"],
  "target": "src/auth/"
}
```

启动工作流时写入此文件，完成后设 `active: false`。
