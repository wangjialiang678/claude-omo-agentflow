# Claude Code 异构多代理编排方案 v2

> **版本**: v2.0
> **日期**: 2026-02-03
> **状态**: 综合设计方案（含调研勘误）
> **前置文档**: claude-code-heterogeneous-agent-orchestration.md (v1)

---

## 目录

1. [背景与目标](#一背景与目标)
2. [已有方案分析与选型（含勘误）](#二已有方案分析与选型含勘误)
3. [架构设计](#三架构设计)
4. [模块详细设计](#四模块详细设计)
5. [代理角色与模型路由](#五代理角色与模型路由)
6. [工作流引擎](#六工作流引擎)
7. [自动继续机制](#七自动继续机制)
8. [任务池与并行执行](#八任务池与并行执行)
9. [安装与配置](#九安装与配置)
10. [附录](#十附录)

---

## 一、背景与目标

### 1.1 要解决的核心问题

在使用 Claude Code 进行复杂软件工程任务时，存在三个关键痛点：

**痛点一：子代理完成后主线程无法自动继续**

Claude Code 的架构是回合制的（turn-based）。当主代理派发后台子任务后，主代理会"让出"控制权，进入等待用户输入的状态。即使子代理已经完成工作，主代理也不会自动读取结果并推进到下一步——需要用户手动发送消息来"唤醒"。后台任务完成通知也存在已知可靠性问题（Issue #6854, #20525, #21048）。

**痛点二：缺乏结构化的多代理编排机制**

Claude Code 原生 Task 工具支持子代理，但没有提供：
- 规划与执行的分离机制
- 任务依赖关系管理
- 子代理权限隔离
- 跨任务的知识积累
- 并行任务池和链式工作流

**痛点三：子代理模型选择受限**

Claude Code 原生子代理的 `model` 字段仅支持 Claude 系列模型（Opus / Sonnet / Haiku）。但不同类型的任务适合不同的模型：
- 后端核心代码适合最强推理模型（Codex / Opus）
- 前端 UI 生成适合擅长创意的模型（Gemini）
- 调研任务适合大上下文极速模型（Gemini Flash）
- 代码审核适合严谨的推理模型（Codex / Opus）

### 1.2 目标架构能力

1. **自动编排**：主代理按计划自动委派任务、自动推进，不需要用户每步手动触发
2. **并行执行**：独立子任务可同时运行，子代理上下文彼此隔离，支持任务池和原子认领
3. **文档驱动**：任务通过 Markdown 文档描述和传递，可读、可审计、可追溯
4. **异构模型路由**：不同子代理可使用不同厂商的大模型，按任务特点选择最优模型
5. **工作流引擎**：支持 Pipeline（链式）、Swarm（蜂群并行）、Autopilot（自主）等多种执行模式
6. **模块化解耦**：各组件（编排、路由、任务池、工作流、自动继续）独立运作，可单独替换或升级

### 1.3 设计原则

- **KISS** — 保持简单，能用 Shell + Markdown 解决的不引入复杂框架
- **模块化** — 每个模块独立目录、独立配置，模块间通过文件系统通信
- **解耦** — 编排层不需要知道路由层细节，路由层不需要知道编排层逻辑
- **渐进式** — 从最小可用系统开始，逐步添加高级功能
- **文件即接口** — 模块间通信主要通过 JSON/Markdown 文件，而非进程间通信

---

## 二、已有方案分析与选型（含勘误）

### 2.1 调研的开源项目

通过对 10+ 个开源项目的深入调研（含代码审计），我们评估了以下方案：

| 项目 | Stars | 定位 | 调研结论 |
|------|-------|------|---------|
| **oh-my-opencode (OMO)** | 27.4k | OpenCode 多代理编排 | 架构最成熟，但绑定 OpenCode 平台，受 Anthropic OAuth 封锁影响 |
| **oh-my-claudecode (Yeachan-Heo)** | 4.3k | Claude Code 多代理插件 | 5 种执行模式，32 代理，零配置；Plugin exit 2 bug |
| **oh-my-claude (stefandevo)** | 4 | OMO → Claude Code 移植 | 架构设计好但代码有严重 bug（stop.sh JSON schema 错误） |
| **Claude Code Router (CCR)** | 27.1k | 透明 API 路由代理 | 子代理级路由控制，但 705 开放 issues |
| **myclaude (cexll)** | — | Go 多后端包装器 | Phase-based Stop Hook，按任务路由 |
| **claude-flow v3** | — | 重型编排平台 | 功能最全但 250k+ 行代码，过重 |
| **MCP Agent Mail** | — | 代理间通信系统 | 去中心化设计，不适合集中编排 |

### 2.2 v1 方案中的关键勘误

经过深入调研，v1 文档中存在以下事实性错误，在 v2 中已修正：

| 错误 | 事实 | 来源 |
|------|------|------|
| stefandevo 版有 Atlas 代理 | **没有 Atlas**。使用 Prometheus → Sisyphus 两层结构 | 代码审计 |
| Sisyphus 是"执行者" | Sisyphus 是**编排者/协调器**，Sisyphus-Junior 才是执行者 | OMO 源码 |
| stop.sh 使用 `exit 2` 可靠 | stefandevo 的 stop.sh 用了**错误的 JSON schema**（`{"decision":"allow"}` 属于 PreToolUse），9 处需修复 | Issue #1 |
| Plugin 安装 Stop Hook 正常工作 | Plugin 安装的 Stop Hook **exit code 2 不工作**（Issue #10412），必须直接安装到 `.claude/hooks/` | 社区验证 |
| 后台任务完成后会自动通知主代理 | 通知**不可靠**（Issue #6854, #20525, #21048），需要 Stop Hook 主动检查 | 官方 Issues |

### 2.3 借鉴策略

基于调研结论，v2 采用**自主整合**策略，从多个项目中借鉴优秀设计：

| 借鉴来源 | 借鉴内容 | 不借鉴的内容 |
|---------|---------|-------------|
| **oh-my-claudecode (Yeachan-Heo)** | 任务池设计（原子认领 + 超时释放）、Pipeline 链式工作流（6 种预设）、5 种执行模式架构、技能学习系统框架、Hook 生命周期管理 | 32 个代理（过重）、Plugin SDK 安装方式（有 bug）、Haiku/Sonnet/Opus 路由（改用自定义路由） |
| **oh-my-opencode (OMO)** | Prometheus 规划理念（访谈模式 + 顾问模式）、Metis 预规划分析（间隙检测）、QA 可执行性原则、防 AI-slop 约束、工具限制机制 | TypeScript 实现（改用 Markdown）、OpenCode 绑定、OAuth 认证方式 |
| **stefandevo/oh-my-claude** | MIGRATION.md 架构映射思路、Hook 简化设计（22→5）、Boulder 状态机概念、文档驱动通信 | 具体代码实现（有 bug）、安装脚本 |
| **Claude Code Router** | CCR-SUBAGENT-MODEL 标签机制、Transformer 系统（API 格式转换）、Provider 可插拔架构 | 整体依赖（705 issues） |
| **myclaude** | Phase-based 循环控制、completion_promise 完成标志 | Go 语言实现 |

### 2.4 自主设计部分

以下功能采用我们自己的设计方案：

1. **智能模型路由** — 按任务类型+领域映射（非复杂度评分），偏好 Codex/Opus 而非 Sonnet
2. **模块化目录结构** — 6 个独立模块，各自目录和配置
3. **四层循环防护** — `stop_hook_active` + 最大重试 + 超时 + 紧急开关
4. **混合安装方式** — Hooks 直装 `.claude/hooks/`，其余组件用标准目录结构

---

## 三、架构设计

### 3.1 模块化架构总览

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Claude Code Session                          │
│                                                                     │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────┐               │
│  │  Module 1   │  │  Module 2    │  │  Module 3   │               │
│  │  编排引擎    │  │  模型路由     │  │  任务池     │               │
│  │             │  │              │  │             │               │
│  │ Agents      │  │ CCR Config   │  │ Task Pool   │               │
│  │ Prompts     │  │ Provider Map │  │ Claim/Rel   │               │
│  │ Planner     │  │ Transformer  │  │ Timeout     │               │
│  └──────┬──────┘  └──────┬───────┘  └──────┬──────┘               │
│         │                │                  │                       │
│  ┌──────┴──────┐  ┌──────┴───────┐  ┌──────┴──────┐               │
│  │  Module 4   │  │  Module 5    │  │  Module 6   │               │
│  │  工作流引擎  │  │  自动继续     │  │  知识积累   │               │
│  │             │  │              │  │             │               │
│  │ Pipeline    │  │ Stop Hook    │  │ Learnings   │               │
│  │ Swarm       │  │ Loop Guard   │  │ Decisions   │               │
│  │ Autopilot   │  │ PreCompact   │  │ Skills      │               │
│  └─────────────┘  └──────────────┘  └─────────────┘               │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    文件系统通信层                              │   │
│  │  .orchestrator/plans/ tasks/ results/ state/ learnings/      │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.2 六大模块职责

| 模块 | 目录 | 职责 | 依赖 |
|------|------|------|------|
| **M1: 编排引擎** | `.claude/agents/`, `AGENTS.md` | 代理定义、角色分配、委派策略 | 无 |
| **M2: 模型路由** | `~/.claude-code-router/` | 子代理请求拦截、模型映射、API 格式转换 | CCR |
| **M3: 任务池** | `.orchestrator/tasks/` | 任务分解、原子认领、超时释放、完成追踪 | 文件锁(flock) |
| **M4: 工作流引擎** | `.orchestrator/workflows/` | Pipeline/Swarm/Autopilot 模式选择和执行 | M1, M3 |
| **M5: 自动继续** | `.claude/hooks/` | Stop Hook、循环防护、PreCompact 状态保存 | jq |
| **M6: 知识积累** | `.orchestrator/learnings/` | 决策记录、经验提取、技能复用 | 无 |

### 3.3 模块间通信

模块之间**不直接调用**，通过文件系统通信：

```
M4 工作流引擎
  ├─ 写入 → .orchestrator/plans/current-plan.md    ← M1 编排引擎读取
  ├─ 写入 → .orchestrator/tasks/task-pool.json     ← M3 任务池管理
  └─ 写入 → .orchestrator/state/workflow-state.json ← M5 自动继续读取

M5 自动继续
  ├─ 读取 → .orchestrator/state/workflow-state.json
  ├─ 读取 → .orchestrator/tasks/task-pool.json
  └─ 决定是否阻止主代理停下

M3 任务池
  ├─ 读写 → .orchestrator/tasks/task-pool.json（带文件锁）
  └─ 写入 → .orchestrator/results/{task-id}.json  ← M4 读取结果

M6 知识积累
  ├─ 读取 → .orchestrator/results/
  └─ 写入 → .orchestrator/learnings/
```

### 3.4 完整文件结构

```
项目根目录/
├── CLAUDE.md                              # 编排规则（含代理委派策略）
├── AGENTS.md                              # 代理注册表
├── .claude/
│   ├── settings.json                      # hooks + 权限配置
│   ├── agents/                            # 代理 prompt 定义
│   │   ├── planner.md                     # 规划代理
│   │   ├── backend-coder.md               # 后端代码代理
│   │   ├── frontend-coder.md              # 前端代码代理
│   │   ├── reviewer.md                    # 代码审核代理
│   │   ├── researcher.md                  # 调研代理
│   │   ├── explorer.md                    # 快速搜索代理
│   │   └── doc-writer.md                  # 文档撰写代理
│   └── hooks/                             # 直接安装（不用 plugin！）
│       ├── stop.sh                        # 自动继续 + 循环防护
│       ├── subagent-stop.sh               # 子代理完成追踪
│       ├── pre-compact.sh                 # 上下文压缩前状态保存
│       └── lib/                           # Hook 共享工具库
│           ├── json-utils.sh              # JSON 工具函数
│           ├── state-manager.sh           # 状态文件管理
│           └── loop-guard.sh              # 循环防护
├── .orchestrator/                         # 运行时状态（自动创建）
│   ├── plans/                             # 计划文档
│   │   └── current-plan.md
│   ├── tasks/                             # 任务池
│   │   ├── task-pool.json
│   │   └── task-pool.lock
│   ├── results/                           # 任务结果
│   │   └── {task-id}.json
│   ├── state/                             # 工作流状态
│   │   ├── workflow-state.json
│   │   └── iterations.txt
│   ├── workflows/                         # 工作流预设
│   │   ├── review.yaml
│   │   ├── implement.yaml
│   │   ├── debug.yaml
│   │   └── research.yaml
│   └── learnings/                         # 知识积累
│       ├── decisions.md
│       └── learnings.md
└── ~/.claude-code-router/                 # CCR 配置（全局）
    ├── config.json
    └── logs/
```

---

## 四、模块详细设计

### 4.1 M1: 编排引擎

#### 代理定义规范

每个代理是一个 `.md` 文件，使用 YAML frontmatter + Markdown 正文：

```markdown
---
name: backend-coder
description: 后端代码实现专家
model: opus                    # Claude Code 原生模型声明
tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
---

<CCR-SUBAGENT-MODEL>openrouter,openai/gpt-5.2-codex</CCR-SUBAGENT-MODEL>

# Backend Coder

You are a Senior Backend Engineer specializing in server-side implementation.

## Identity
- You write production-quality code on the first attempt
- You follow SOLID principles and clean architecture

## Rules
- ALWAYS write tests alongside implementation code
- NEVER modify frontend files (*.tsx, *.jsx, *.css, *.vue)
- Output results to `.orchestrator/results/{task-id}.json`
- Update task status in `.orchestrator/tasks/task-pool.json`

## QA Enforcement (borrowed from OMO Metis)
- All acceptance criteria MUST be executable by concrete commands
- Reject subjective criteria like "user confirms" or "looks good"
- Every task must have a verifiable done-condition

## Anti AI-Slop Patterns (borrowed from OMO)
- Do NOT add features beyond the task scope
- Do NOT refactor surrounding code unless explicitly requested
- Do NOT add comments to code you didn't change
```

#### 代理注册表 (AGENTS.md)

```markdown
# Agent Registry

| Agent | Type | Model Route | Tools | Permissions |
|-------|------|------------|-------|-------------|
| planner | Planning | Claude Opus (native) | Read, Glob, Grep, AskUserQuestion | Read-only |
| backend-coder | Execution | Codex → Opus fallback | Read, Write, Edit, Bash, Glob, Grep | Full write |
| frontend-coder | Execution | Gemini 2.5 Pro | Read, Write, Edit, Bash, Glob, Grep | Full write |
| reviewer | QA | Codex → Opus fallback | Read, Glob, Grep, Bash | Read-only + test run |
| researcher | Research | Gemini Flash | Read, Glob, Grep, WebSearch, WebFetch | Read-only |
| explorer | Search | Gemini Flash | Read, Glob, Grep | Read-only |
| doc-writer | Documentation | Gemini Flash | Read, Write, Glob, Grep | Write .md only |
```

#### 委派策略（写入 CLAUDE.md）

```markdown
## 多代理编排规则

### 代理委派策略
| 任务类型 | 委派给 | 说明 |
|---------|--------|------|
| 后端代码实现 | backend-coder | Codex/Opus，严格后端权限 |
| 前端 UI/UX 实现 | frontend-coder | Gemini Pro，创意 UI |
| 代码审核/Review | reviewer | Codex/Opus，只读+测试 |
| 技术调研 | researcher | Gemini Flash，大上下文 |
| 代码搜索/文件查找 | explorer | Gemini Flash，极速只读 |
| 文档撰写 | doc-writer | Gemini Flash |
| 需求规划 | planner | Claude Opus 原生 |
| 核心代码（不路由） | 主代理自行处理 | Claude Opus/Sonnet 原生订阅 |
```

### 4.2 M2: 模型路由

#### 路由策略

**核心原则**：按**任务领域**而非复杂度路由。

| 领域 | 首选模型 | 次选模型 | 禁用 | 理由 |
|------|---------|---------|------|------|
| 后端代码 | Codex | Claude Opus | ~~Sonnet~~ | 最强代码生成能力 |
| 代码审核 | Codex | Claude Opus | ~~Sonnet~~ | 严格审查需要顶级推理 |
| 前端代码 | Gemini 2.5 Pro | — | — | 创意 UI 擅长 |
| 调研 | Gemini Flash | Gemini 2.5 Flash | — | 大上下文 + 极速 |
| 快速搜索 | Gemini Flash | — | — | 极速 + 低成本 |
| 文档 | Gemini Flash | — | — | 写作快且好 |
| 规划 | Claude Opus (原生) | — | — | 走原生订阅，最强理解力 |
| 核心编排 | Claude Opus (原生) | — | — | 主代理始终走原生 |

> **关键决策**：后端代码和代码审核场景**不使用 Sonnet**，只用 Codex 或 Opus。

#### CCR 配置模板

**OpenRouter 方案**（推荐，一个 Key 接入所有模型）：

```json
{
  "APIKEY": "placeholder",
  "LOG": true,
  "LOG_LEVEL": "info",
  "Providers": [
    {
      "name": "openrouter",
      "api_base_url": "https://openrouter.ai/api/v1/chat/completions",
      "api_key": "$OPENROUTER_API_KEY",
      "models": [
        "openai/gpt-5.2-codex",
        "google/gemini-2.5-pro-preview",
        "google/gemini-3-flash",
        "google/gemini-2.5-flash"
      ],
      "transformer": {
        "use": ["openrouter"]
      }
    }
  ],
  "Router": {
    "default": "anthropic-native",
    "subagent": { "enabled": true }
  }
}
```

**代理标签映射表**：

| 代理 | CCR 标签 | 路由目标 |
|------|---------|---------|
| backend-coder | `<CCR-SUBAGENT-MODEL>openrouter,openai/gpt-5.2-codex</CCR-SUBAGENT-MODEL>` | Codex |
| frontend-coder | `<CCR-SUBAGENT-MODEL>openrouter,google/gemini-2.5-pro-preview</CCR-SUBAGENT-MODEL>` | Gemini Pro |
| reviewer | `<CCR-SUBAGENT-MODEL>openrouter,openai/gpt-5.2-codex</CCR-SUBAGENT-MODEL>` | Codex |
| researcher | `<CCR-SUBAGENT-MODEL>openrouter,google/gemini-3-flash</CCR-SUBAGENT-MODEL>` | Gemini Flash |
| explorer | `<CCR-SUBAGENT-MODEL>openrouter,google/gemini-3-flash</CCR-SUBAGENT-MODEL>` | Gemini Flash |
| doc-writer | `<CCR-SUBAGENT-MODEL>openrouter,google/gemini-3-flash</CCR-SUBAGENT-MODEL>` | Gemini Flash |
| planner | **无标签**（走原生 Opus 订阅） | Claude Opus |

> `"default": "anthropic-native"` 确保主代理和 planner 始终走 Claude 原生订阅。

#### Provider 可插拔

切换 Provider **只改 config.json**，不动任何代理文件：

```
# 从 OpenRouter 切到直连各厂 API
# 只需在 config.json 中添加新 Provider，修改代理 .md 中的标签

# 或者 Foxcode 中转站（国内直连）
# 参见附录 A：Provider 配置模板集
```

### 4.3 M3: 任务池

借鉴 oh-my-claudecode 的任务池设计，使用文件锁保证原子性。

#### 数据结构

```json
// .orchestrator/tasks/task-pool.json
{
  "pool_id": "feature-dark-mode",
  "created_at": "2026-02-03T10:00:00Z",
  "tasks": [
    {
      "id": "task-001",
      "description": "Implement dark mode toggle component",
      "agent": "frontend-coder",
      "status": "pending",
      "depends_on": [],
      "claimed_by": null,
      "claimed_at": null,
      "completed_at": null,
      "result_file": null
    },
    {
      "id": "task-002",
      "description": "Add theme context provider",
      "agent": "frontend-coder",
      "status": "claimed",
      "depends_on": [],
      "claimed_by": "worker-1",
      "claimed_at": "2026-02-03T10:05:00Z",
      "completed_at": null,
      "result_file": null
    },
    {
      "id": "task-003",
      "description": "Write dark mode API endpoint",
      "agent": "backend-coder",
      "status": "completed",
      "depends_on": [],
      "claimed_by": "worker-2",
      "claimed_at": "2026-02-03T10:03:00Z",
      "completed_at": "2026-02-03T10:12:00Z",
      "result_file": ".orchestrator/results/task-003.json"
    }
  ]
}
```

#### 原子认领脚本

```bash
#!/bin/bash
# .orchestrator/scripts/claim-task.sh
# 使用 flock 保证原子性

POOL_FILE=".orchestrator/tasks/task-pool.json"
LOCK_FILE=".orchestrator/tasks/task-pool.lock"
WORKER_ID="$1"

claimed_task=$(
  flock "$LOCK_FILE" -c "
    task_id=\$(jq -r '.tasks[] | select(.status == \"pending\") | .id' \"$POOL_FILE\" | head -n 1)
    if [ -n \"\$task_id\" ] && [ \"\$task_id\" != \"null\" ]; then
      jq --arg id \"\$task_id\" --arg worker \"$WORKER_ID\" --arg now \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \
        '.tasks |= map(
          if .id == \$id
          then .status = \"claimed\" | .claimedBy = \$worker | .claimed_at = \$now
          else . end
        )' \"$POOL_FILE\" > \"$POOL_FILE.tmp\"
      mv \"$POOL_FILE.tmp\" \"$POOL_FILE\"
      echo \"\$task_id\"
    fi
  "
)

if [ -n "$claimed_task" ]; then
  jq -r --arg id "$claimed_task" '.tasks[] | select(.id == $id)' "$POOL_FILE"
else
  echo "No pending tasks" >&2
  exit 1
fi
```

#### 超时释放脚本

```bash
#!/bin/bash
# .orchestrator/scripts/release-timeout.sh
# 5 分钟超时自动释放

POOL_FILE=".orchestrator/tasks/task-pool.json"
LOCK_FILE=".orchestrator/tasks/task-pool.lock"
TIMEOUT_SECONDS=300

flock "$LOCK_FILE" -c "
  jq --arg timeout \"$TIMEOUT_SECONDS\" '
    .tasks |= map(
      if .status == \"claimed\" and
         (.claimed_at | fromdateiso8601) < (now - (\$timeout | tonumber))
      then .status = \"pending\" | .claimed_by = null | .claimed_at = null
      else . end
    )
  ' \"$POOL_FILE\" > \"$POOL_FILE.tmp\"
  mv \"$POOL_FILE.tmp\" \"$POOL_FILE\"
"
```

### 4.4 M4: 工作流引擎

借鉴 oh-my-claudecode 的 Pipeline 预设和执行模式。

#### 三种执行模式

| 模式 | 适用场景 | 说明 |
|------|---------|------|
| **Autopilot** | 简单端到端任务 | 单代理持续工作，Stop Hook 驱动继续 |
| **Pipeline** | 多阶段链式处理 | 代理按顺序执行，上一阶段输出作为下一阶段输入 |
| **Swarm** | 大规模并行任务 | 多 worker 从共享任务池认领任务并行处理 |

#### Pipeline 预设

```yaml
# .orchestrator/workflows/review.yaml
name: code-review
description: 完整代码审查流水线
stages:
  - name: explore
    agent: explorer
    description: 搜索相关代码和依赖
    output: .orchestrator/results/explore-output.md

  - name: review
    agent: reviewer
    description: 深度代码审查
    input: .orchestrator/results/explore-output.md
    output: .orchestrator/results/review-output.md

  - name: fix
    agent: backend-coder
    description: 修复审查发现的问题
    input: .orchestrator/results/review-output.md
    output: .orchestrator/results/fix-output.md

  - name: verify
    agent: reviewer
    description: 验证修复结果
    input: .orchestrator/results/fix-output.md
    output: .orchestrator/results/verify-output.md
```

```yaml
# .orchestrator/workflows/implement.yaml
name: feature-implement
description: 新功能实现流水线
stages:
  - name: plan
    agent: planner
    description: 分析需求并制定实施计划
    output: .orchestrator/plans/current-plan.md

  - name: implement
    agent: backend-coder
    description: 实现核心逻辑
    input: .orchestrator/plans/current-plan.md
    output: .orchestrator/results/impl-output.md

  - name: review
    agent: reviewer
    description: 代码审查
    input: .orchestrator/results/impl-output.md
    output: .orchestrator/results/review-output.md
```

```yaml
# .orchestrator/workflows/research.yaml
name: technical-research
description: 技术调研流水线
stages:
  - name: explore
    agent: explorer
    description: 快速搜索相关代码
    output: .orchestrator/results/explore-output.md

  - name: research
    agent: researcher
    description: 深度调研和分析
    input: .orchestrator/results/explore-output.md
    output: .orchestrator/results/research-output.md

  - name: summarize
    agent: doc-writer
    description: 撰写调研报告
    input: .orchestrator/results/research-output.md
    output: .orchestrator/results/research-report.md
```

```yaml
# .orchestrator/workflows/debug.yaml
name: bug-fix
description: Bug 修复流水线
stages:
  - name: explore
    agent: explorer
    description: 定位问题代码
    output: .orchestrator/results/explore-output.md

  - name: analyze
    agent: reviewer
    description: 分析根因
    input: .orchestrator/results/explore-output.md
    output: .orchestrator/results/analysis-output.md

  - name: fix
    agent: backend-coder
    description: 修复 bug
    input: .orchestrator/results/analysis-output.md
    output: .orchestrator/results/fix-output.md
```

### 4.5 M5: 自动继续机制

#### Stop Hook 完整实现

```bash
#!/bin/bash
# .claude/hooks/stop.sh
# JSON Decision 模式 + 四层循环防护

set -euo pipefail

# === 加载工具库 ===
HOOK_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$HOOK_DIR/lib/json-utils.sh" 2>/dev/null || true
source "$HOOK_DIR/lib/loop-guard.sh" 2>/dev/null || true

# === 读取输入 ===
INPUT=$(cat)
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')

# === 防护层 1: stop_hook_active 检查 ===
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    exit 0
fi

# === 防护层 2: 紧急退出开关 ===
if [ -f /tmp/FORCE_STOP ]; then
    rm -f /tmp/FORCE_STOP
    exit 0
fi

# === 防护层 3: 最大重试次数 ===
RETRY_FILE=".orchestrator/state/stop-retries.txt"
MAX_RETRIES=5
RETRY_COUNT=$(cat "$RETRY_FILE" 2>/dev/null || echo "0")
if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
    echo "0" > "$RETRY_FILE"
    exit 0  # 允许停止
fi

# === 防护层 4: 超时 ===
TIMEOUT_FILE=".orchestrator/state/stop-start-time.txt"
TIMEOUT_SECONDS=300  # 5 分钟
if [ -f "$TIMEOUT_FILE" ]; then
    START_TIME=$(cat "$TIMEOUT_FILE")
    ELAPSED=$(( $(date +%s) - START_TIME ))
    if [ "$ELAPSED" -gt "$TIMEOUT_SECONDS" ]; then
        rm -f "$TIMEOUT_FILE" "$RETRY_FILE"
        exit 0  # 超时，允许停止
    fi
else
    date +%s > "$TIMEOUT_FILE"
fi

# === 核心逻辑: 检查是否有未完成的工作 ===

# 检查 1: 工作流状态
WORKFLOW_STATE=".orchestrator/state/workflow-state.json"
if [ -f "$WORKFLOW_STATE" ]; then
    ACTIVE=$(jq -r '.active // false' "$WORKFLOW_STATE")
    if [ "$ACTIVE" = "true" ]; then
        PENDING=$(jq -r '.pending_stages | length' "$WORKFLOW_STATE" 2>/dev/null || echo "0")
        CURRENT=$(jq -r '.current_stage // "unknown"' "$WORKFLOW_STATE")
        if [ "$PENDING" -gt 0 ]; then
            echo $((RETRY_COUNT + 1)) > "$RETRY_FILE"
            cat << EOF
{
  "decision": "block",
  "reason": "工作流进行中。当前阶段: $CURRENT，剩余 $PENDING 个阶段。请继续执行。"
}
EOF
            exit 0
        fi
    fi
fi

# 检查 2: 任务池状态
TASK_POOL=".orchestrator/tasks/task-pool.json"
if [ -f "$TASK_POOL" ]; then
    PENDING_TASKS=$(jq '[.tasks[] | select(.status == "pending" or .status == "claimed")] | length' "$TASK_POOL" 2>/dev/null || echo "0")
    if [ "$PENDING_TASKS" -gt 0 ]; then
        echo $((RETRY_COUNT + 1)) > "$RETRY_FILE"
        cat << EOF
{
  "decision": "block",
  "reason": "任务池中还有 $PENDING_TASKS 个未完成任务。请继续处理。"
}
EOF
        exit 0
    fi
fi

# 检查 3: 计划文档中的 TODO
PLAN_FILE=".orchestrator/plans/current-plan.md"
if [ -f "$PLAN_FILE" ]; then
    INCOMPLETE=$(grep -c '^\- \[ \]' "$PLAN_FILE" 2>/dev/null || echo "0")
    if [ "$INCOMPLETE" -gt 0 ]; then
        echo $((RETRY_COUNT + 1)) > "$RETRY_FILE"
        cat << EOF
{
  "decision": "block",
  "reason": "计划中还有 $INCOMPLETE 个未完成的 TODO。请继续执行。"
}
EOF
        exit 0
    fi
fi

# === 全部完成，清理状态，允许停止 ===
rm -f "$TIMEOUT_FILE" "$RETRY_FILE"
exit 0
```

#### SubagentStop Hook

```bash
#!/bin/bash
# .claude/hooks/subagent-stop.sh
# 追踪子代理完成，更新任务池

INPUT=$(cat)
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // "unknown"')
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "unknown"')

# 记录完成
mkdir -p .orchestrator/results
COMPLETION_LOG=".orchestrator/results/completions.jsonl"
echo "{\"agent_id\":\"$AGENT_ID\",\"agent_type\":\"$AGENT_TYPE\",\"completed_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" >> "$COMPLETION_LOG"

exit 0
```

#### PreCompact Hook

```bash
#!/bin/bash
# .claude/hooks/pre-compact.sh
# 上下文压缩前保存关键状态

INPUT=$(cat)

# 保存当前状态快照
SNAPSHOT_DIR=".orchestrator/state/snapshots"
mkdir -p "$SNAPSHOT_DIR"
SNAPSHOT_FILE="$SNAPSHOT_DIR/$(date +%s).json"

WORKFLOW_STATE=""
if [ -f ".orchestrator/state/workflow-state.json" ]; then
    WORKFLOW_STATE=$(cat ".orchestrator/state/workflow-state.json")
fi

TASK_SUMMARY=""
if [ -f ".orchestrator/tasks/task-pool.json" ]; then
    TASK_SUMMARY=$(jq '{
      total: (.tasks | length),
      pending: [.tasks[] | select(.status == "pending")] | length,
      claimed: [.tasks[] | select(.status == "claimed")] | length,
      completed: [.tasks[] | select(.status == "completed")] | length
    }' ".orchestrator/tasks/task-pool.json")
fi

cat << EOF > "$SNAPSHOT_FILE"
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "workflow": $WORKFLOW_STATE,
  "tasks": $TASK_SUMMARY
}
EOF

# 输出 preserveContext 给 Claude
cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreCompact",
    "preserveContext": "工作流状态: $(echo "$WORKFLOW_STATE" | jq -r '.current_stage // "idle"')。任务进度: $(echo "$TASK_SUMMARY" | jq -r '"完成\(.completed)/\(.total)"')。"
  }
}
EOF

exit 0
```

### 4.6 M6: 知识积累

#### 决策记录

```markdown
<!-- .orchestrator/learnings/decisions.md -->
# 决策记录

## 2026-02-03: 选择 Codex 而非 Sonnet 作为后端模型
- **背景**: 后端代码审核需要最高推理质量
- **决策**: Codex 优先，Opus 次选，禁用 Sonnet
- **理由**: Codex 在代码生成基准测试中表现最佳
- **影响**: 成本较高但质量更好

## 2026-02-03: 使用 JSON Decision 而非 exit 2
- **背景**: Stop Hook 需要可靠的控制机制
- **决策**: 使用 JSON `{"decision":"block"}` + exit 0
- **理由**: 避免 Plugin exit code 2 bug（Issue #10412）
- **影响**: 更结构化，可携带更多上下文
```

#### 经验积累

```markdown
<!-- .orchestrator/learnings/learnings.md -->
# 经验积累

## 工具使用经验
- `flock` 在 macOS 上需要安装：`brew install flock` 或使用 `shlock`
- `jq` 的 `fromdateiso8601` 在某些版本不支持，用 `date -d` 替代
- `.claude/hooks/` 中的脚本必须 `chmod +x`

## 代理协作经验
- explorer 代理结果需要结构化（JSON > 纯文本），下游代理更易解析
- backend-coder 和 frontend-coder 不应修改同一文件，用接口文件隔离
- reviewer 代理发现问题后，不应自行修复，应回传给对应 coder
```

---

## 五、代理角色与模型路由

### 5.1 代理角色定义

#### Planner（规划代理）

借鉴 OMO Prometheus 的**访谈模式**和 Metis 的**间隙检测**。

```markdown
---
name: planner
description: 需求分析和实施规划专家
model: opus
tools:
  - Read
  - Glob
  - Grep
  - AskUserQuestion
---

# Planner - Strategic Planning Agent

## Identity
You are a Senior Technical Planner. You analyze requirements, identify gaps,
and create detailed implementation plans.

## Workflow (borrowed from OMO Prometheus)

### Phase 1: Intent Classification
Classify the request:
- New Feature / Refactoring / Bug Fix / Research / Architecture Change

### Phase 2: Gap Detection (borrowed from OMO Metis)
Before planning, identify:
- Ambiguous requirements
- Missing acceptance criteria
- Hidden dependencies
- Potential failure modes
- Scope creep risks

Use AskUserQuestion to clarify any gaps found.

### Phase 3: Plan Generation
Output a plan to `.orchestrator/plans/current-plan.md`:
```markdown
# Plan: {title}
## Objective
## Tasks
- [ ] Task 1: {description} → agent: {agent-name}
- [ ] Task 2: {description} → agent: {agent-name}
## Dependencies
## Acceptance Criteria (must be machine-verifiable)
## Risks
```

## QA Enforcement
- Every acceptance criterion must be testable via command
- Reject "user confirms" / "looks good" type criteria
- Each task must specify which agent handles it

## Anti AI-Slop
- Do NOT plan more than what was requested
- Keep plans concise (max 10 tasks for MVP)
- Flag scope creep explicitly
```

#### Backend Coder

```markdown
---
name: backend-coder
description: 后端代码实现专家
model: opus
tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
---

<CCR-SUBAGENT-MODEL>openrouter,openai/gpt-5.2-codex</CCR-SUBAGENT-MODEL>

# Backend Coder

You are a Senior Backend Engineer. Write production-quality server-side code.

## Rules
- Follow SOLID principles
- Write tests alongside implementation
- NEVER touch frontend files (*.tsx, *.jsx, *.css, *.vue)
- Update task status when done:
  1. Write results to `.orchestrator/results/{task-id}.json`
  2. Mark task as "completed" in task-pool.json

## Code Quality
- No premature optimization
- No unnecessary abstractions
- Clear error handling at system boundaries only
- Type safety where the language supports it
```

#### Frontend Coder

```markdown
---
name: frontend-coder
description: 前端 UI/UX 实现专家
model: sonnet
tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
---

<CCR-SUBAGENT-MODEL>openrouter,google/gemini-2.5-pro-preview</CCR-SUBAGENT-MODEL>

# Frontend Coder

You are a Senior Frontend Engineer specializing in UI/UX implementation.

## Rules
- NEVER touch backend files (*.go, *.py, *.rs, server.*)
- Follow existing UI patterns and design system
- Write component tests
- Ensure responsive design
- Update task status when done
```

#### Reviewer

```markdown
---
name: reviewer
description: 代码审核与质量保证专家
model: opus
tools:
  - Read
  - Glob
  - Grep
  - Bash
---

<CCR-SUBAGENT-MODEL>openrouter,openai/gpt-5.2-codex</CCR-SUBAGENT-MODEL>

# Code Reviewer

You are a Senior Code Reviewer focused on quality, security, and correctness.

## Rules
- NEVER modify source code directly
- Run tests: report pass/fail status
- Check for OWASP Top 10 vulnerabilities
- Check for race conditions, memory leaks, error handling gaps
- Output structured review to `.orchestrator/results/{task-id}.json`:
  ```json
  {
    "verdict": "approve" | "request_changes",
    "issues": [{"severity": "critical|major|minor", "file": "...", "line": N, "description": "..."}],
    "tests_passed": true|false
  }
  ```
```

#### Researcher

```markdown
---
name: researcher
description: 技术调研与最佳实践分析专家
model: haiku
tools:
  - Read
  - Glob
  - Grep
  - WebSearch
  - WebFetch
---

<CCR-SUBAGENT-MODEL>openrouter,google/gemini-3-flash</CCR-SUBAGENT-MODEL>

# Technical Researcher

You are a Research Specialist focused on finding best practices,
analyzing documentation, and evaluating technical options.

## Rules
- NEVER modify any files except writing reports
- Output research report to `.orchestrator/results/{task-id}.md`
- Cite sources with URLs
- Provide actionable recommendations (not just information dumps)
```

#### Explorer

```markdown
---
name: explorer
description: 快速代码搜索和文件查找
model: haiku
tools:
  - Read
  - Glob
  - Grep
---

<CCR-SUBAGENT-MODEL>openrouter,google/gemini-3-flash</CCR-SUBAGENT-MODEL>

# Explorer - Fast Codebase Search

You are a fast search specialist. Find files, functions, patterns quickly.

## Rules
- NEVER modify any files
- Be extremely concise
- Output structured results (file paths, line numbers, snippets)
- Respond in under 30 seconds
```

---

## 六、工作流引擎

### 6.1 Pipeline 执行流程

```
用户: "按 review 流水线审查 src/auth/ 目录"
  │
  ▼
主代理解析指令
  │
  ▼
读取 .orchestrator/workflows/review.yaml
  │
  ▼
设置 workflow-state.json:
{
  "active": true,
  "workflow": "review",
  "current_stage": "explore",
  "pending_stages": ["review", "fix", "verify"],
  "completed_stages": []
}
  │
  ▼
委派 Stage 1: explorer 代理搜索 src/auth/
  │
  ▼
explorer 完成 → 结果写入 explore-output.md
  │
  ▼
Stop Hook 检查: workflow active, 3 stages pending → block
  │
  ▼
主代理继续: 委派 Stage 2: reviewer 代理审查
  │
  ▼
reviewer 完成 → 结果写入 review-output.md
  │
  ▼
... 重复直到所有 stages 完成
  │
  ▼
workflow-state.json: { "active": false }
  │
  ▼
Stop Hook 检查: workflow 非活跃 → 允许停止
```

### 6.2 Swarm 执行流程

```
用户: "并行修复所有 TypeScript 类型错误"
  │
  ▼
主代理分析代码库，分解为原子任务
  │
  ▼
写入 task-pool.json (N 个 pending 任务)
  │
  ▼
启动多个 backend-coder 子代理 (background)
  │
  ▼
每个子代理:
  1. 调用 claim-task.sh 认领任务（原子操作）
  2. 执行任务
  3. 写入结果
  4. 标记任务 completed
  5. 尝试认领下一个 pending 任务
  │
  ▼
Stop Hook 检查: task-pool 中有未完成 → block
  │
  ▼
所有任务完成后 → 允许停止
```

### 6.3 Autopilot 执行流程

```
用户: "实现 dark mode 功能"
  │
  ▼
主代理: 调用 planner 代理制定计划
  │
  ▼
planner 输出 current-plan.md (含 TODO 列表)
  │
  ▼
主代理: 按 TODO 逐项委派给合适的代理
  │
  ▼
每完成一项 → 更新 plan 中的 checkbox
  │
  ▼
Stop Hook 检查: plan 中有 unchecked TODO → block
  │
  ▼
所有 TODO 完成 → 允许停止
```

---

## 七、自动继续机制

### 7.1 settings.json 配置

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/stop.sh",
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
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/subagent-stop.sh",
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
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/pre-compact.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

### 7.2 四层循环防护总结

| 层级 | 机制 | 默认值 | 说明 |
|------|------|--------|------|
| 1 | `stop_hook_active` 检查 | — | 官方防重复触发标志 |
| 2 | 紧急退出开关 | `/tmp/FORCE_STOP` | 用户手动创建文件即可退出 |
| 3 | 最大重试次数 | 5 次 | 超过后强制停止 |
| 4 | 超时时间 | 5 分钟 | 超过后强制停止 |

### 7.3 关键注意事项

1. **必须直接安装到 `.claude/hooks/`**，不要用 Plugin 安装（exit code 2 bug, Issue #10412）
2. **使用 JSON Decision 模式**（`{"decision":"block"}`），而非 exit code 2（更可靠）
3. **不依赖后台通知**（通知不可靠），Stop Hook 主动检查状态文件
4. **配合 PreCompact Hook** 防止上下文溢出

---

## 八、任务池与并行执行

### 8.1 并行执行策略

| 参数 | 值 | 说明 |
|------|---|------|
| 最大并行 worker | 2-5 | 根据任务复杂度调整 |
| 任务超时 | 5 分钟 | 超时自动释放 |
| 认领方式 | flock 文件锁 | 保证原子性 |
| 任务粒度 | 单文件/单函数 | 尽量原子化 |

### 8.2 macOS 兼容性

macOS 默认没有 `flock`，替代方案：

```bash
# 方案 1: 安装 flock
brew install flock

# 方案 2: 使用 shlock (macOS 内置)
shlock -f "$LOCK_FILE" -p $$

# 方案 3: 使用 mkdir 作为锁（最简单可靠）
while ! mkdir "$LOCK_FILE.d" 2>/dev/null; do sleep 0.1; done
# ... 临界区操作 ...
rmdir "$LOCK_FILE.d"
```

---

## 九、安装与配置

### 9.1 前置依赖

| 依赖 | 用途 | 安装方式 |
|------|------|---------|
| Claude Code CLI v2.1.0+ | 基础平台 | 官方安装 |
| jq | JSON 处理 | `brew install jq` |
| flock (可选) | 文件锁 | `brew install flock` 或用 mkdir 替代 |
| Node.js 18+ | CCR 运行 | `brew install node` |
| CCR | 模型路由 | `npm i -g @musistudio/claude-code-router` |

### 9.2 安装步骤

#### Step 1: 创建目录结构

```bash
mkdir -p .claude/hooks/lib
mkdir -p .claude/agents
mkdir -p .orchestrator/{plans,tasks,results,state,workflows,learnings}
```

#### Step 2: 安装 Hooks（直接安装，不用 Plugin！）

```bash
# 复制 hook 脚本到 .claude/hooks/
# （脚本内容见第四章 M5 节）
chmod +x .claude/hooks/*.sh
```

#### Step 3: 安装代理定义

```bash
# 复制代理 .md 文件到 .claude/agents/
# （内容见第五章）
```

#### Step 4: 配置 settings.json

```bash
# 写入 .claude/settings.json
# （内容见第七章 7.1 节）
```

#### Step 5: 安装和配置 CCR

```bash
npm install -g @musistudio/claude-code-router
# 编辑 ~/.claude-code-router/config.json
# （内容见第四章 M2 节）

export OPENROUTER_API_KEY="sk-or-v1-你的密钥"
```

#### Step 6: 安装工作流预设

```bash
# 复制 workflow YAML 到 .orchestrator/workflows/
# （内容见第四章 M4 节）
```

#### Step 7: 启动和验证

```bash
# 启动 CCR
ccr start
ccr status  # 确认 Running

# 使用 CCR 启动 Claude Code
ccr code
# 或
eval $(ccr activate) && claude

# 测试单个代理
> Use the explorer subagent to list all TypeScript files

# 测试 Stop Hook
> Plan and implement a simple hello world endpoint
# 观察是否自动继续执行计划
```

### 9.3 更新 CLAUDE.md

在项目 CLAUDE.md 中添加编排规则（见第四章 M1 节的委派策略）。

---

## 十、附录

### 附录 A: Provider 配置模板集

#### OpenRouter（推荐，一个 Key 接入所有模型）

```json
{
  "Providers": [
    {
      "name": "openrouter",
      "api_base_url": "https://openrouter.ai/api/v1/chat/completions",
      "api_key": "$OPENROUTER_API_KEY",
      "models": [
        "openai/gpt-5.2-codex",
        "google/gemini-2.5-pro-preview",
        "google/gemini-3-flash",
        "google/gemini-2.5-flash"
      ],
      "transformer": { "use": ["openrouter"] }
    }
  ],
  "Router": {
    "default": "anthropic-native",
    "subagent": { "enabled": true }
  }
}
```

#### Foxcode 中转站（国内直连）

```json
{
  "Providers": [
    {
      "name": "foxcode-codex",
      "api_base_url": "https://code.newcli.com/codex/v1/chat/completions",
      "api_key": "$FOXCODE_API_KEY",
      "models": ["gpt-5.2-codex"],
      "transformer": { "use": [] }
    },
    {
      "name": "foxcode-gemini",
      "api_base_url": "https://code.newcli.com/gemini/v1beta/models/",
      "api_key": "$FOXCODE_API_KEY",
      "models": ["gemini-3-flash", "gemini-2.5-pro"],
      "transformer": { "use": ["gemini"] }
    }
  ],
  "Router": {
    "default": "anthropic-native",
    "subagent": { "enabled": true }
  }
}
```

#### 混合配置（按模型选最优线路）

```json
{
  "Providers": [
    {
      "name": "openrouter",
      "api_base_url": "https://openrouter.ai/api/v1/chat/completions",
      "api_key": "$OPENROUTER_API_KEY",
      "models": ["openai/gpt-5.2-codex"],
      "transformer": { "use": ["openrouter"] }
    },
    {
      "name": "foxcode-gemini",
      "api_base_url": "https://code.newcli.com/gemini/v1beta/models/",
      "api_key": "$FOXCODE_API_KEY",
      "models": ["gemini-3-flash", "gemini-2.5-pro"],
      "transformer": { "use": ["gemini"] }
    }
  ]
}
```

### 附录 B: 故障排除

| 问题 | 排查 | 解决 |
|------|------|------|
| 子代理返回 401/403 | API Key 未设置 | 检查环境变量 |
| 子代理返回「模型不存在」| 模型名与 Provider 不一致 | 查 Provider 文档确认模型名 |
| CCR 未路由（走了原生）| 标签位置不对 | 确保标签在 prompt body **第一行** |
| 主代理也被路由了 | Router.default 配置错误 | 确保 `"default": "anthropic-native"` |
| Stop Hook 不阻止 | 装在 plugin 里了 | 移到 `.claude/hooks/` 目录 |
| 自动继续死循环 | 完成条件永远不满足 | 检查四层防护是否配置正确 |
| flock 命令找不到 | macOS 默认无 flock | `brew install flock` 或用 mkdir 锁 |
| task-pool.json 损坏 | 并发写入冲突 | 确保使用文件锁；`rm` 后重新创建 |
| 上下文溢出 | 自动继续消耗太多 context | 确认 PreCompact Hook 已配置 |
| Stop Hook 不触发 | 脚本没有执行权限 | `chmod +x .claude/hooks/*.sh` |

### 附录 C: 开源项目参考清单

| 项目 | GitHub | 我们借鉴了什么 |
|------|--------|---------------|
| oh-my-opencode (OMO) | code-yeongyu/oh-my-opencode | Prometheus 规划理念、Metis 间隙检测、QA 可执行性原则、防 AI-slop 约束 |
| oh-my-claudecode | Yeachan-Heo/oh-my-claudecode | 任务池设计、Pipeline 预设、执行模式架构、技能学习框架、Hook 生命周期 |
| oh-my-claude | stefandevo/oh-my-claude | MIGRATION.md 架构映射、Boulder 状态机概念、文档驱动通信 |
| Claude Code Router | musistudio/claude-code-router | CCR-SUBAGENT-MODEL 标签、Transformer API 转换、Provider 可插拔 |
| myclaude | cexll/myclaude | Phase-based 循环控制、completion_promise 模式 |

### 附录 D: Exit Code 和 Decision 对照表

| Exit Code | JSON Decision | 效果 | 推荐度 |
|-----------|--------------|------|--------|
| `exit 0` | 无 | 允许停止 | ✅ 正常退出 |
| `exit 0` | `{"decision":"block","reason":"..."}` | 阻止停止（推荐） | ✅✅ 首选方式 |
| `exit 0` | `{"continue":false}` | 全局停止（最高优先） | 🔴 紧急用 |
| `exit 2` | 无 (stderr 作为错误) | 阻止停止 | ⚠️ 仅 .claude/hooks/ |
| `exit 1` | 无 | 非阻塞警告 | — |

### 附录 E: 已知 Bug 和限制

| Bug / 限制 | Issue | 状态 | 我们的规避方案 |
|-----------|-------|------|--------------|
| Plugin Stop Hook exit 2 失败 | #10412 | 未修复 | 直接安装到 `.claude/hooks/` |
| 后台任务完成通知不可靠 | #6854, #20525, #21048 | 未修复 | Stop Hook 主动检查状态文件 |
| SubagentStop 无法区分子代理 | #7881 | 未修复 | 用 `agent_type` + 外部状态文件 |
| 跨会话 Stop Hook 触发 | #15047 | 未修复 | 避免同时运行多个实例 |
| stefandevo stop.sh JSON 错误 | oh-my-claude #1 | 未修复 | 自行实现正确版本 |

---

> **版本历史**
> - v1.0 (2026-02-03): 初始方案，基于 oh-my-claude + CCR
> - v2.0 (2026-02-03): 综合多项目调研勘误，模块化重设计，借鉴 oh-my-claudecode 任务池/工作流，自定义模型路由（Codex/Opus 优先，禁用 Sonnet）
