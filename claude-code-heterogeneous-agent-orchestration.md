# Claude Code 异构多代理编排技术方案

> **版本**: v1.0
> **日期**: 2025-02
> **状态**: 技术方案

---

## 一、背景与目标

### 1.1 要解决的核心问题

在使用 Claude Code 进行复杂软件工程任务时，存在三个关键痛点：

**痛点一：子代理完成后主线程无法自动继续**

Claude Code 的架构是基于回合制的（turn-based）。当主代理派发后台子任务（subagent）后，主代理会"让出"控制权，进入等待用户输入的状态。即使子代理已经完成工作，主代理也不会自动读取结果并推进到下一步——它需要用户手动发送一条消息来"唤醒"。这导致在并行任务场景下，用户必须频繁手动触发，无法实现真正的自动化编排。

**痛点二：缺乏结构化的多代理编排机制**

Claude Code 原生的 Task 工具支持子代理，但没有提供：
- 规划与执行的分离机制
- 任务依赖关系管理
- 子代理权限隔离
- 跨任务的知识积累

这意味着复杂项目中的任务分解、委派、验证都依赖用户手动管理，难以规模化。

**痛点三：子代理模型选择受限**

Claude Code 原生子代理的 `model` 字段仅支持 Claude 系列模型（Opus / Sonnet / Haiku）。但在实际工作中，不同类型的任务适合不同的模型：
- 快速代码搜索适合极速模型（如 Grok）
- 前端 UI 生成适合擅长创意的模型（如 Gemini）
- 深度推理适合长链思考模型（如 DeepSeek Reasoner）
- 核心代码实现适合最强通用模型（如 Claude Opus）

无法为不同子代理指定不同厂商的模型，限制了整体效率。

### 1.2 目标架构要实现的能力

1. **自动编排**：主代理按计划自动委派任务、自动推进，不需要用户每步手动触发
2. **并行执行**：独立子任务可同时运行，子代理上下文彼此隔离
3. **文档驱动**：任务通过 Markdown 文档描述和传递，可读、可审计、可追溯
4. **异构模型路由**：不同子代理可使用不同厂商的大模型，按任务特点选择最优模型
5. **Provider 可插拔**：模型路由层与编排逻辑解耦，切换 API 提供商（OpenRouter、国内中转站等）不需要修改任何代理定义

---

## 二、已有方案分析与选型

### 2.1 社区主流方案概览

通过对技术社区的调研，目前解决上述问题的方案可归纳为四种编排模式：

#### 模式一：分层角色编排 — OMO / oh-my-claude

OMO（Oh My OpenCode）是目前编排设计最精致的开源项目之一。它将系统分为三层：

- **规划层**：Prometheus（规划师）通过访谈模式收集需求，Metis（顾问）补充分析，Momus（审核者）检查遗漏
- **执行层**：Atlas（指挥家）读取计划文档，逐任务委派给工作层
- **工作层**：Sisyphus（执行者）、Oracle（架构）、Explore（搜索）、Librarian（文档研究）、Frontend（UI/UX）等专业代理

核心机制：
- 规划与执行严格分离 — 规划者不写代码，执行者不做规划
- 文档即接口 — `.sisyphus/plans/`、`drafts/`、`notepads/` 是所有代理间的共享通信层
- 子代理权限隔离 — 只读代理不能修改文件，防止意外破坏
- 累积学习 — `learnings.md` / `decisions.md` 跨任务传递经验
- "Boulder" 状态机 — `boulder.json` 追踪执行进度，Stop Hook 阻止主代理在计划未完成时停下

oh-my-claude（stefandevo 版）将 OMO 的完整编排体系移植到了 Claude Code，用 Shell Hooks 替代 OpenCode 的 Plugin SDK，用 MCP Server 替代 Plugin Tools，保持了完全一致的状态文件结构和编排逻辑。

**优点**：编排逻辑最完整，文档驱动对人类友好，规划-执行分离清晰
**缺点**：子代理间不能直接通信（必须通过主编排器中转）；oh-my-claude 原版未实现异构模型路由

#### 模式二：邮件/消息总线编排 — MCP Agent Mail

GitHub: [Dicklesworthstone/mcp_agent_mail](https://github.com/Dicklesworthstone/mcp_agent_mail)

给 AI 代理建了一个"Gmail"式通信系统。每个代理有自己的身份、收件箱/发件箱，通过消息进行协调。支持文件预留（lease）防止多代理互相覆盖，Git 存储消息历史。配套的 iOS 应用可在手机上指挥异构代理舰队。

**优点**：去中心化，代理间可直接通信，支持任意异构代理
**缺点**：没有"主代理"概念，不适合需要集中编排的场景；配置较复杂

#### 模式三：任务依赖图编排 — CC Mirror

主代理定义任务 JSON（包含 `blockedBy` / `blocks` 依赖关系）。无依赖的任务立即启动子代理，上游任务完成后自动触发下游。零外部依赖，纯文件+后台进程。

**优点**：轻量，显式依赖声明，自动触发
**缺点**：仅支持 Claude 模型，任务描述用 JSON 而非 Markdown，编排能力较简单

#### 模式四：群体智能编排 — Claude Flow v3 / ccswarm

Claude Flow 支持 6 种 LLM Provider，智能路由选择最便宜的合格模型。Swarm 模式下多代理共享向量数据库记忆，通过共识投票合并输出。

**优点**：功能最完整，智能路由，共享记忆
**缺点**：极其复杂（250k+ 行代码），对简单场景严重过重

#### 其他轻量方案

- **Claude Squad** — 终端多窗口管理器，支持 Claude/Codex/Gemini/Aider 并行运行，但不做自动路由和编排
- **myclaude (cexll)** — Go 编写的多后端包装器，支持 Codex/Claude/Gemini/OpenCode 按任务类型自动路由，通过 `dev-plan.md` 驱动并行执行
- **Claudish** — CLI 工具，通过 OpenRouter 让 Claude Code 的界面运行任意模型
- **PAL MCP Server** — 支持 `clink` 工具从 Claude Code 内部启动隔离的外部 CLI 子代理（Gemini CLI、Codex CLI 等）

### 2.2 方案对比

| 方案 | 主代理指挥 | 子代理独立上下文 | MD 文档驱动 | 并行处理 | 异构模型 | 自动继续 | 复杂度 |
|------|:---------:|:---------------:|:-----------:|:-------:|:-------:|:-------:|:------:|
| **OMO / oh-my-claude** | ✅ | ✅ 严格隔离 | ✅ `.sisyphus/plans/` | ✅ | ⚠️ 需扩展 | ✅ boulder+hook | 中 |
| **MCP Agent Mail** | ❌ 去中心化 | ✅ | ✅ AGENTS.md | ✅ | ✅ 任意代理 | ⚠️ 需自建 | 中 |
| **CC Mirror** | ✅ | ✅ | ⚠️ JSON 驱动 | ✅ | ❌ 仅 Claude | ✅ 依赖图 | 低 |
| **Claude Flow v3** | ✅ | ⚠️ 共享记忆 | ❌ 命令驱动 | ✅ | ✅ 6种 | ✅ | 高 |
| **myclaude** | ✅ | ✅ | ✅ dev-plan.md | ✅ | ✅ 3种 | ✅ | 中 |
| **Claude Squad** | ❌ 手动 | ✅ | ❌ | ✅ | ✅ | ❌ | 低 |

### 2.3 为什么选择 oh-my-claude + Claude Code Router

综合评估后，本方案选择 **oh-my-claude（编排层）+ Claude Code Router（路由层）** 的双层叠加架构，原因如下：

**选择 oh-my-claude 作为编排层：**

1. **编排逻辑最成熟** — 继承了 OMO 经过打磨的 Prometheus/Atlas/Sisyphus 体系，规划-执行分离、子代理权限隔离、累积学习等机制完整
2. **自动继续已内置** — `boulder.json` 状态机 + `stop.sh` Hook 解决了"子代理完成后主线程不继续"的核心问题
3. **文档驱动** — 一切通过 Markdown 文件通信，人类可读可审计
4. **对 Claude Code 零侵入** — 纯 Shell Hooks + MD 文件实现，不修改 Claude Code 本体

**选择 Claude Code Router 作为路由层：**

1. **透明代理** — 子代理以为自己在调 Claude API，实际请求被 CCR 拦截后转发给指定模型，对编排层完全透明
2. **Provider 可插拔** — 编排层不需要知道"Grok 的 API 地址是什么"，只需在代理 `.md` 文件中声明 `<CCR-SUBAGENT-MODEL>provider,model</CCR-SUBAGENT-MODEL>` 标签
3. **切换 Provider 只改配置** — 从 OpenRouter 切到国内中转站，只改 `config.json`，不动任何代理文件
4. **主代理不受影响** — `"default": "anthropic-native"` 确保主代理始终走 Claude 原生订阅

**这个组合的核心设计原则是：编排层和路由层完全解耦。** oh-my-claude 负责"谁做什么事"，CCR 负责"用什么模型做"。任何一层都可以独立替换或升级。

---

## 三、技术方案

### 3.1 架构总览

```
┌─────────────────────────────────────────────────────────────────┐
│                      Claude Code Session                        │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │           oh-my-claude 编排层 (stefandevo)                │  │
│  │                                                           │  │
│  │  Prometheus(规划) → Atlas(指挥) → 子代理(执行)            │  │
│  │       │                 │              │                  │  │
│  │       ▼                 ▼              ▼                  │  │
│  │  .sisyphus/plans/   boulder.json   background_task        │  │
│  │                                                           │  │
│  │  Stop Hook: 自动继续机制                                  │  │
│  └───────────────────────────────────────────────────────────┘  │
│                          │                                      │
│                          ▼                                      │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │           Claude Code Router (musistudio)                  │  │
│  │                                                           │  │
│  │  拦截子代理请求 → 按 <CCR-SUBAGENT-MODEL> 标签路由         │  │
│  │                                                           │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │         Provider 配置层（可插拔）                     │  │  │
│  │  │                                                     │  │  │
│  │  │  Profile A: OpenRouter（统一接入多模型）             │  │  │
│  │  │  Profile B: Foxcode 中转站（国内直连）               │  │  │
│  │  │  Profile C: 直连官方 API（各家分别配置）             │  │  │
│  │  │  Profile D: 混合配置（按模型选最优线路）             │  │  │
│  │  └─────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                 │
│  主代理 ────→ Claude 原生订阅（不经过路由层）                    │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 代理角色与模型映射

| 代理角色 | 职责 | 理想模型 | 回退模型 | 选型理由 |
|---------|------|---------|---------|---------|
| Sisyphus (主执行) | 核心代码实现 | Claude Opus 4.5 | Claude Sonnet 4.5 | 最强推理，走原生订阅 |
| Atlas (编排指挥) | 任务委派和验证 | Claude Sonnet 4.5 | — | 平衡速度和能力 |
| Prometheus (规划) | 需求访谈和计划生成 | Claude Opus 4.5 | Claude Sonnet 4.5 | 深度理解，走原生订阅 |
| **explore** | 快速搜索/文件查找 | Grok 3 (Fast) | Gemini 3 Flash | 极速搜索，成本低 |
| **frontend-engineer** | UI/UX 实现 | Gemini 2.5 Pro | GPT-5.2 Codex | 擅长创意 UI |
| **document-writer** | 文档撰写 | Gemini 3 Flash | Gemini 2.5 Flash | 写作快且好 |
| **oracle** | 架构分析/深度调试 | DeepSeek Reasoner | GPT-5.2 Codex | 深度推理链 |
| **librarian** | 文档研究/示例查找 | Gemini 3 Flash | Gemini 2.5 Flash | 大上下文窗口 |

> **粗体**行的代理通过 CCR 路由到外部模型，其余走 Claude 原生订阅。

### 3.3 实施步骤

#### Phase 1: 安装 oh-my-claude (stefandevo 版)

```bash
# 进入你的项目目录
cd ~/your-project

# 克隆 oh-my-claude
git clone https://github.com/stefandevo/oh-my-claude.git /tmp/oh-my-claude

# 运行安装脚本（选择项目级安装）
cd /tmp/oh-my-claude
chmod +x install.sh
./install.sh
```

安装脚本会提示选择安装位置，**选择项目级安装**（安装到当前项目的 `.claude/` 目录）。

验证安装：

```bash
ls -la .claude/oh-my-claude/
# 应该看到：hooks/ agents/ mcp/ skills/ config/

cat .claude/settings.json
# 应该看到 hooks 配置包含 PreToolUse、PostToolUse、Stop、UserPromptSubmit
```

**关键确认：Stop hook 必须存在**——这是自动继续机制的核心。

#### Phase 2: 安装 Claude Code Router

```bash
npm install -g @musistudio/claude-code-router
```

创建 CCR 配置文件 `~/.claude-code-router/config.json`。根据你使用的 Provider 方案，从附录中选择对应的配置模板：
- **附录 A**: OpenRouter 配置
- **附录 B**: Foxcode 中转站配置
- **附录 C**: 混合配置模板

所有配置模板共享同一个结构：

```json
{
  "APIKEY": "placeholder",
  "LOG": true,
  "LOG_LEVEL": "info",
  "Providers": [ ... ],
  "Router": {
    "default": "anthropic-native",
    "subagent": {
      "enabled": true
    }
  }
}
```

`"default": "anthropic-native"` 确保主代理始终走 Claude 原生订阅，只有带 `<CCR-SUBAGENT-MODEL>` 标签的子代理请求才被路由到外部模型。

设置环境变量（按需选择）：

```bash
# OpenRouter
export OPENROUTER_API_KEY="sk-or-v1-你的密钥"

# Foxcode 中转站
export FOXCODE_API_KEY="你的foxcode密钥"
```

启动并验证：

```bash
ccr start          # 启动 CCR 代理
ccr status         # 应该看到 Running
```

从此使用 `ccr code` 或 `eval $(ccr activate) && claude` 启动 Claude Code。

#### Phase 3: 创建异构模型子代理

每个子代理的 `.md` 文件 prompt body 第一行包含一个 CCR 路由标签：

```
<CCR-SUBAGENT-MODEL>{provider},{model}</CCR-SUBAGENT-MODEL>
```

其中 `{provider}` 对应 `config.json` 中某个 Provider 的 `name` 字段，`{model}` 对应该 Provider `models` 数组中的模型名。**要切换 Provider，只需改这一行标签**。

在 `.claude/agents/` 下创建以下代理定义文件：

**explore.md** — 快速搜索代理

```markdown
---
name: explore
description: |
  Fast codebase exploration and file search agent.
model: haiku
tools:
  - Read
  - Glob
  - Grep
  - Bash
---

<!-- === CCR 路由标签（选择一个，注释其余） === -->
<!-- OpenRouter + Grok:    <CCR-SUBAGENT-MODEL>openrouter,x-ai/grok-3-fast</CCR-SUBAGENT-MODEL> -->
<!-- OpenRouter + Gemini:  <CCR-SUBAGENT-MODEL>openrouter,google/gemini-3-flash</CCR-SUBAGENT-MODEL> -->
<!-- Foxcode + Gemini:     <CCR-SUBAGENT-MODEL>foxcode-gemini,gemini-3-flash</CCR-SUBAGENT-MODEL> -->
<CCR-SUBAGENT-MODEL>openrouter,x-ai/grok-3-fast</CCR-SUBAGENT-MODEL>

You are Explore, a fast codebase search specialist.

## Rules
- NEVER modify any files
- Only search, read, and report
- Be extremely fast and concise
```

**frontend-engineer.md** — 前端 UI 代理

```markdown
---
name: frontend-engineer
description: |
  Frontend UI/UX implementation specialist.
model: sonnet
tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
---

<!-- OpenRouter: <CCR-SUBAGENT-MODEL>openrouter,google/gemini-2.5-pro-preview</CCR-SUBAGENT-MODEL> -->
<!-- Foxcode:    <CCR-SUBAGENT-MODEL>foxcode-gemini,gemini-2.5-pro</CCR-SUBAGENT-MODEL> -->
<CCR-SUBAGENT-MODEL>openrouter,google/gemini-2.5-pro-preview</CCR-SUBAGENT-MODEL>

You are a Senior Frontend Engineer specializing in UI/UX implementation.
```

**oracle.md** — 深度推理代理

```markdown
---
name: oracle
description: |
  Architecture and deep reasoning specialist.
model: opus
tools:
  - Read
  - Glob
  - Grep
  - Bash
---

<!-- OpenRouter + DeepSeek: <CCR-SUBAGENT-MODEL>openrouter,deepseek/deepseek-reasoner</CCR-SUBAGENT-MODEL> -->
<!-- OpenRouter + Codex:    <CCR-SUBAGENT-MODEL>openrouter,openai/gpt-5.2-codex</CCR-SUBAGENT-MODEL> -->
<!-- Foxcode + Codex:       <CCR-SUBAGENT-MODEL>foxcode-codex,gpt-5.2-codex</CCR-SUBAGENT-MODEL> -->
<CCR-SUBAGENT-MODEL>openrouter,deepseek/deepseek-reasoner</CCR-SUBAGENT-MODEL>

You are Oracle, an Architecture and Deep Reasoning Specialist.

## Rules
- NEVER modify code directly
- Think step by step, show your reasoning
```

**document-writer.md** 和 **librarian.md** 结构类似，路由到 Gemini 3 Flash。

#### Phase 4: 配置编排指令

在项目 `CLAUDE.md` 中添加代理委派策略和自动继续规则：

```markdown
## 多代理编排规则

### 代理委派策略
| 任务类型 | 委派给 | 说明 |
|---------|--------|------|
| 代码搜索/文件查找 | explore | 快速搜索，只读 |
| 前端 UI/UX 实现 | frontend-engineer | 创意 UI 实现 |
| 文档撰写 | document-writer | 技术文档 |
| 架构分析/深度调试 | oracle | 深度推理，只读 |
| 文档研究/示例查找 | librarian | 信息收集，只读 |
| 核心代码实现 | 原生子代理 (Sisyphus) | 走 Claude 原生订阅 |

### 自动继续规则
- 后台任务完成后，检查 .sisyphus/plans/ 中的当前计划
- 还有未完成的 TODO → 立即执行下一个
- 所有 TODO 完成 → 生成最终报告并等待用户
```

创建 `AGENTS.md` 代理注册表，记录每个代理的职责、权限、理想模型和触发条件。

#### Phase 5: 配置自动继续机制 (Stop Hook)

oh-my-claude 已内置 `stop.sh`（continuation enforcement）。核心逻辑：

```bash
#!/bin/bash
# 检查是否有活跃的 boulder（正在执行的计划）
if [ -f ".sisyphus/boulder.json" ]; then
    CURRENT_PLAN=$(cat ".sisyphus/boulder.json" | grep -o '"plan":"[^"]*"' | cut -d'"' -f4)
    if [ -n "$CURRENT_PLAN" ]; then
        UNCHECKED=$(grep -c "^\- \[ \]" ".sisyphus/plans/$CURRENT_PLAN" || echo "0")
        if [ "$UNCHECKED" -gt 0 ]; then
            echo "计划还有 $UNCHECKED 个未完成任务。继续执行。" >&2
            exit 2  # exit 2 + stderr → 阻止主代理停下，强制继续
        fi
    fi
fi
exit 0
```

**重要**：防止无限循环。Stop hook 的 `exit 2` 如果条件永远不满足，主代理会被困住。必须加超时或最大重试次数。

#### Phase 6: 端到端测试

```bash
# 启动系统
ccr start && ccr code

# 测试单个外部模型代理
> Use the explore subagent to list all JavaScript files in this project

# 测试并行执行
> Run these as background tasks:
> 1. explore: find all API endpoint definitions
> 2. librarian: research JWT authentication best practices
> 3. oracle: review current security architecture

# 测试完整编排流程
> @plan I want to add a dark mode toggle feature
> /start-work
```

监控 CCR 路由日志：`tail -f ~/.claude-code-router/logs/ccr-*.log`

#### Phase 7: 故障排除

| 问题 | 排查 | 解决 |
|------|------|------|
| 子代理返回 401/403 | API Key 未设置 | 检查环境变量 |
| 子代理返回「模型不存在」 | 模型名与 Provider 不一致 | 查 Provider 文档确认模型名 |
| CCR 未路由（走了原生） | 标签位置不对 | 确保标签在 prompt body **第一行** |
| 主代理也被路由了 | Router.default 配置错误 | 确保 `"default": "anthropic-native"` |
| Atlas 不自动继续 | Stop hook 未注册或无权限 | 检查 `.claude/settings.json` 和 `chmod +x` |
| boulder.json 卡住 | 状态文件损坏 | `rm .sisyphus/boulder.json` 重新 `/start-work` |

### 3.4 完整文件清单

```
项目根目录/
├── CLAUDE.md                              # 编排规则
├── AGENTS.md                              # 代理注册表
├── .claude/
│   ├── settings.json                      # hooks 配置
│   ├── agents/
│   │   ├── explore.md                     # 搜索代理 → Grok / Gemini Flash
│   │   ├── frontend-engineer.md           # 前端代理 → Gemini Pro
│   │   ├── document-writer.md             # 文档代理 → Gemini Flash
│   │   ├── oracle.md                      # 推理代理 → DeepSeek / Codex
│   │   └── librarian.md                   # 研究代理 → Gemini Flash
│   ├── hooks/
│   │   └── stop-continuation.sh           # 自动继续 hook
│   └── oh-my-claude/                      # oh-my-claude 安装目录
├── .sisyphus/                             # 运行时状态（自动创建）
│   ├── plans/                             # 计划文档
│   ├── drafts/                            # 草稿
│   ├── notepads/                          # 笔记（含 learnings.md）
│   └── boulder.json                       # 执行状态机
└── ~/.claude-code-router/
    ├── config.json                        # CCR 配置
    └── logs/                              # 路由日志
```

---

## 四、附录

### 附录 A: OpenRouter Provider 配置

OpenRouter (openrouter.ai) 通过统一 API 接入 300+ 模型，一个 Key 即可访问 Grok、Gemini、DeepSeek、GPT 等所有主流模型。

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
        "x-ai/grok-3-fast",
        "x-ai/grok-3",
        "google/gemini-2.5-pro-preview",
        "google/gemini-3-flash",
        "google/gemini-2.5-flash",
        "deepseek/deepseek-reasoner",
        "deepseek/deepseek-chat-v3-0324",
        "openai/gpt-5.2-codex"
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

子代理标签写法示例：
```
<CCR-SUBAGENT-MODEL>openrouter,x-ai/grok-3-fast</CCR-SUBAGENT-MODEL>
<CCR-SUBAGENT-MODEL>openrouter,google/gemini-2.5-pro-preview</CCR-SUBAGENT-MODEL>
<CCR-SUBAGENT-MODEL>openrouter,deepseek/deepseek-reasoner</CCR-SUBAGENT-MODEL>
```

注意事项：
- OpenRouter 模型名格式为 `provider/model`（如 `x-ai/grok-3-fast`），完整列表见 https://openrouter.ai/models
- 中国大陆可能需要代理才能访问 OpenRouter

### 附录 B: Foxcode 中转站 Provider 配置

Foxcode (foxcode.hshwk.org) 是国内中转站，统一 Key、三个独立端点（OpenAI / Anthropic / Google 格式各不兼容）。适合中国大陆直连使用。

端点信息：
- OpenAI 格式：`https://code.newcli.com/codex/v1`
- Anthropic 格式：`https://code.newcli.com/claude/droid`
- Google Gemini 格式：`https://code.newcli.com/gemini`

```json
{
  "APIKEY": "placeholder",
  "LOG": true,
  "LOG_LEVEL": "info",
  "Providers": [
    {
      "name": "foxcode-codex",
      "api_base_url": "https://code.newcli.com/codex/v1/chat/completions",
      "api_key": "$FOXCODE_API_KEY",
      "models": ["gpt-5.2-codex", "gpt-4o", "o3-mini"],
      "transformer": { "use": [] }
    },
    {
      "name": "foxcode-gemini",
      "api_base_url": "https://code.newcli.com/gemini/v1beta/models/",
      "api_key": "$FOXCODE_API_KEY",
      "models": ["gemini-3-flash", "gemini-2.5-pro", "gemini-2.5-flash"],
      "transformer": { "use": ["gemini"] }
    },
    {
      "name": "foxcode-claude",
      "api_base_url": "https://code.newcli.com/claude/droid",
      "api_key": "$FOXCODE_API_KEY",
      "models": ["claude-sonnet-4-5-20250929", "claude-opus-4-5-20251101"],
      "transformer": { "use": ["anthropic"] }
    }
  ],
  "Router": {
    "default": "anthropic-native",
    "subagent": { "enabled": true }
  }
}
```

**三端点的 URL 拼接规则**（CCR 根据 transformer 自动拼接最终请求 URL）：

| Provider | api_base_url | transformer | 最终请求 URL |
|----------|-------------|-------------|-------------|
| foxcode-codex | `.../codex/v1/chat/completions` | 空（原生 OpenAI） | 直接使用 base_url |
| foxcode-gemini | `.../gemini/v1beta/models/` | gemini | `{base_url}{model}:generateContent` |
| foxcode-claude | `.../claude/droid` | anthropic | `{base_url}/v1/messages` |

**模型回退**：Foxcode 目前没有 Grok 和 DeepSeek 端点：
- explore 理想模型 Grok 3 Fast → 回退为 Gemini 3 Flash
- oracle 理想模型 DeepSeek Reasoner → 回退为 GPT-5.2 Codex

### 附录 C: 混合 Provider 配置模板

当需要组合多个 Provider 时（如 Grok 走 OpenRouter、Gemini 走 Foxcode），在 Providers 数组中并列配置，CCR 按标签中的 Provider 名精确路由：

```json
{
  "Providers": [
    {
      "name": "openrouter",
      "api_base_url": "https://openrouter.ai/api/v1/chat/completions",
      "api_key": "$OPENROUTER_API_KEY",
      "models": ["x-ai/grok-3-fast", "deepseek/deepseek-reasoner"],
      "transformer": { "use": ["openrouter"] }
    },
    {
      "name": "foxcode-gemini",
      "api_base_url": "https://code.newcli.com/gemini/v1beta/models/",
      "api_key": "$FOXCODE_API_KEY",
      "models": ["gemini-3-flash", "gemini-2.5-pro"],
      "transformer": { "use": ["gemini"] }
    },
    {
      "name": "foxcode-codex",
      "api_base_url": "https://code.newcli.com/codex/v1/chat/completions",
      "api_key": "$FOXCODE_API_KEY",
      "models": ["gpt-5.2-codex"],
      "transformer": { "use": [] }
    }
  ]
}
```

混合路由效果：

| 代理 | 标签 | 走哪条线路 | 理由 |
|------|------|-----------|------|
| explore | `openrouter,x-ai/grok-3-fast` | OpenRouter → Grok | 理想模型 |
| oracle | `openrouter,deepseek/deepseek-reasoner` | OpenRouter → DeepSeek | 深度推理 |
| frontend-engineer | `foxcode-gemini,gemini-2.5-pro` | Foxcode → Gemini | 国内低延迟 |
| document-writer | `foxcode-gemini,gemini-3-flash` | Foxcode → Gemini | 国内低延迟 |
| librarian | `foxcode-gemini,gemini-3-flash` | Foxcode → Gemini | 国内低延迟 |

**自定义其他中转站**：任何兼容 OpenAI / Anthropic / Google API 格式的中转站都可以作为 Provider 接入，只需配置 `name`、`api_base_url`、`api_key`、`models`、`transformer`。

Transformer 选择参考：

| 中转站 API 格式 | transformer | 说明 |
|----------------|-------------|------|
| OpenAI 兼容 (`/v1/chat/completions`) | `[]` 或 `["openrouter"]` | 大多数中转站 |
| Anthropic 原生 (`/v1/messages`) | `["anthropic"]` | Anthropic 官方或兼容站 |
| Google Gemini (`/v1beta/models/`) | `["gemini"]` | Google 官方或兼容站 |

### 附录 D: 相关开源项目参考

| 项目 | GitHub | 简介 | 特点 |
|------|--------|------|------|
| **OMO (Oh My OpenCode)** | [anthropics/opencode](https://github.com/anthropics/opencode) 生态 | 多层代理编排框架（规划/执行/工作层），OpenCode 平台原生 | 编排设计最完善，原生支持异构模型，文档驱动 |
| **oh-my-claude (stefandevo)** | [stefandevo/oh-my-claude](https://github.com/stefandevo/oh-my-claude) | OMO 到 Claude Code 的移植版 | Shell Hooks 实现，保持 `.sisyphus/` 状态结构 |
| **oh-my-claude (lgcyaxi)** | [lgcyaxi/oh-my-claude](https://github.com/lgcyaxi/oh-my-claude) | oh-my-claude 的多 Provider MCP 扩展 | 通过 MCP Server 路由到 DeepSeek / 智谱 GLM / MiniMax |
| **Claude Code Router** | [musistudio/claude-code-router](https://github.com/musistudio/claude-code-router) | 透明 API 代理，按标签路由子代理到不同模型 | 对编排层零侵入，Provider 可插拔 |
| **CC Mirror** | 社区项目 | 任务依赖图编排，blockedBy/blocks 自动触发 | 轻量，零外部依赖 |
| **MCP Agent Mail** | [Dicklesworthstone/mcp_agent_mail](https://github.com/Dicklesworthstone/mcp_agent_mail) | 代理间"Gmail"通信系统 | 去中心化，文件预留锁，支持任意异构代理 |
| **Claude Flow v3** | [ruvnet/claude-flow](https://github.com/ruvnet/claude-flow) | 重型编排平台，6 种 LLM Provider，智能路由 | 功能最完整，250k+ 行代码，企业级 |
| **Claude Squad** | [smtg-ai/claude-squad](https://github.com/smtg-ai/claude-squad) | 终端多代理窗口管理器 | 轻量，支持 Claude/Codex/Gemini/Aider |
| **myclaude** | [cexll/myclaude](https://github.com/cexll/myclaude) | Go 编写的多后端代理包装器 | 按任务类型自动路由 Codex/Claude/Gemini |
| **Claudish** | 社区工具 | CLI 工具，通过 OpenRouter 运行任意模型 | `npm install -g claudish`，最简单的异构方案 |
| **PAL MCP Server** | 社区项目 | 多模型 MCP，支持 clink 启动外部 CLI 子代理 | 可从 Claude Code 内启动 Gemini CLI / Codex CLI |
| **ccswarm** | 社区项目 | Rust 编写的编排器，基于 Claude ACP | Swarm/群体智能模式 |
| **Agentrooms** | 社区项目 | Web 界面的多代理协调平台 | 可视化编排 |

### 附录 E: 子代理自动继续的技术原理

Claude Code 的 Hooks 事件系统中，两个 hook 直接解决"子代理完成后主线程自动继续"的问题：

**Stop Hook**：当主代理想要停止（等待用户输入）时触发。脚本返回 `exit 2` + stderr 消息 → Claude Code 会将 stderr 内容作为错误反馈给主代理，**阻止它停下来**，强制它继续工作。

**SubagentStop Hook**：在子代理完成任务时触发，可用于做信号通知（如更新完成计数、删除 pending 标记文件）。

**Prompt-based Hook**（进阶）：用轻量级模型（Haiku）判断主代理是否应该继续，返回 `decision: "block"` 阻止停止，`decision: "approve"` 允许停止。比硬编码逻辑更灵活。

OMO 的 "Boulder" 机制：`boulder.json` 维护状态机，Atlas 知道"我在计划中的哪一步"，每完成一个任务自动推进到下一个。Stop hook 确保中途不会停下。Sisyphus 的名字来源于神话——永远推石头上山，如果任务未完成就不会停下。
