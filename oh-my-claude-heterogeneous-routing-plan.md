# oh-my-claude + Claude Code Router 异构模型编排方案

> **用途**: 交给 Claude Code 按 Phase 顺序执行
> **目标**: 在 Claude Code 中搭建 OMO 多代理编排系统，通过可插拔的 Provider 配置实现不同子代理使用不同大模型
> **前提**: macOS/Linux, Node.js 18+, Claude Code CLI 已安装

---

## 架构总览

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

**核心设计原则**：编排层（oh-my-claude）和路由层（CCR）完全解耦。子代理的 `.md` 定义文件中只声明 Provider 名和模型名，具体"这个 Provider 指向哪个 API 端点"由 CCR 的 `config.json` 单独配置。切换 Provider（比如从 Foxcode 换到 OpenRouter）只需改 `config.json`，不动任何代理文件。

---

## 代理→模型映射（通用设计）

下表定义了每个代理的**理想模型选择**，与 Provider 无关。实际可用模型取决于你的 Provider 支持哪些。

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

> **粗体**行的代理通过 CCR 路由到外部模型。其余走 Claude 原生订阅。

---

## Phase 1: 安装 oh-my-claude (stefandevo 版)

### 1.1 克隆并安装

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

### 1.2 验证安装结构

```bash
ls -la .claude/oh-my-claude/
# 应该看到：hooks/ agents/ mcp/ skills/ config/

ls -la .sisyphus/ 2>/dev/null || echo ".sisyphus/ 会在首次使用时创建"
```

### 1.3 验证 hooks 配置

```bash
cat .claude/settings.json
```

应该看到 hooks 配置包含 `PreToolUse`、`PostToolUse`、`Stop`、`UserPromptSubmit`。

**关键确认：Stop hook 必须存在**——这是自动继续机制的核心。

---

## Phase 2: 安装 Claude Code Router

### 2.1 全局安装

```bash
npm install -g @musistudio/claude-code-router
```

### 2.2 创建 CCR 配置

创建文件 `~/.claude-code-router/config.json`。

**根据你使用的 Provider 方案，从附录中选择对应的配置模板**：
- **附录 A**: OpenRouter 配置（最简单，一个 Key 接入所有模型）
- **附录 B**: Foxcode 中转站配置（国内直连，低延迟）
- **附录 C**: 混合配置模板（自定义任意 Provider 组合）

所有配置模板共享同一个结构：

```json
{
  "APIKEY": "placeholder",
  "LOG": true,
  "LOG_LEVEL": "info",
  "Providers": [ ... ],     // ← 不同 Provider 方案的唯一差异在这里
  "Router": {
    "default": "anthropic-native",
    "subagent": {
      "enabled": true
    }
  }
}
```

`"default": "anthropic-native"` 确保主代理始终走 Claude 原生订阅，只有带 `<CCR-SUBAGENT-MODEL>` 标签的子代理请求才被路由到外部模型。

### 2.3 设置环境变量

根据你选择的 Provider 方案，设置对应的环境变量。在 `~/.zshrc` 或 `~/.bashrc` 中添加：

```bash
# === 按需选择，设置你用到的 Key ===

# OpenRouter（附录 A）
export OPENROUTER_API_KEY="sk-or-v1-你的密钥"

# Foxcode 中转站（附录 B）
export FOXCODE_API_KEY="sk-ant-你的密钥"

# 直连官方 API（附录 C 混合配置需要时）
# export GOOGLE_API_KEY="AIza..."
# export DEEPSEEK_API_KEY="sk-..."
# export XAI_API_KEY="xai-..."
```

```bash
source ~/.zshrc
```

### 2.4 启动并验证

```bash
ccr start          # 启动 CCR 代理
ccr status         # 应该看到 Running
```

### 2.5 通过 CCR 启动 Claude Code

从现在开始用以下方式启动 Claude Code：

```bash
ccr code
# 或
eval $(ccr activate) && claude
```

---

## Phase 3: 创建异构模型子代理

### 3.1 子代理的 Provider 抽象机制

每个子代理 `.md` 文件的 prompt body 第一行包含一个 CCR 路由标签：

```
<CCR-SUBAGENT-MODEL>{provider},{model}</CCR-SUBAGENT-MODEL>
```

其中 `{provider}` 对应 `config.json` 中某个 Provider 的 `name` 字段，`{model}` 对应该 Provider 的 `models` 数组中的某个模型名。

**要切换 Provider，只需改这一行标签**。代理的其余 prompt 内容完全不变。

为了方便切换，下面的代理定义中用**变量注释**标注了不同 Provider 方案的标签写法。实际使用时选一个取消注释即可。

### 3.2 创建代理目录

```bash
mkdir -p .claude/agents
```

### 3.3 Explore 代理（快速搜索）

创建 `.claude/agents/explore.md`：

```markdown
---
name: explore
description: |
  Fast codebase exploration and file search agent. Use PROACTIVELY when
  needing to search files, find patterns, or understand project structure.
  Triggers on: explore, search, find files, grep, look for, locate
model: haiku
tools:
  - Read
  - Glob
  - Grep
  - Bash
---

<!-- === CCR 路由标签（选择你的 Provider，保留一行，删除其余） === -->
<!-- OpenRouter + Grok:    <CCR-SUBAGENT-MODEL>openrouter,x-ai/grok-3-fast</CCR-SUBAGENT-MODEL>  -->
<!-- OpenRouter + Gemini:  <CCR-SUBAGENT-MODEL>openrouter,google/gemini-3-flash</CCR-SUBAGENT-MODEL>  -->
<!-- Foxcode + Gemini:     <CCR-SUBAGENT-MODEL>foxcode-gemini,gemini-3-flash</CCR-SUBAGENT-MODEL>  -->
<CCR-SUBAGENT-MODEL>openrouter,x-ai/grok-3-fast</CCR-SUBAGENT-MODEL>

You are Explore, a fast codebase search specialist.

## Your Role
- Rapidly search and index codebases
- Find files, patterns, and code references
- Map project structure and dependencies
- Return concise, structured results

## Rules
- NEVER modify any files
- NEVER write code
- Only search, read, and report
- Be extremely fast and concise
- Return results in structured format

## Output Format
Always return results as:

### Search Results
- **Found**: [number] matches
- **Files**: [list of relevant files with paths]
- **Key Patterns**: [observed patterns]
- **Summary**: [1-2 sentence summary]
```

### 3.4 Frontend Engineer 代理（创意 UI）

创建 `.claude/agents/frontend-engineer.md`：

```markdown
---
name: frontend-engineer
description: |
  Frontend UI/UX implementation specialist. Use when building or modifying
  user interfaces, React components, CSS styling, or visual elements.
  Triggers on: frontend, UI, component, styling, CSS, React, design
model: sonnet
tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
---

<!-- === CCR 路由标签 === -->
<!-- OpenRouter:  <CCR-SUBAGENT-MODEL>openrouter,google/gemini-2.5-pro-preview</CCR-SUBAGENT-MODEL>  -->
<!-- Foxcode:     <CCR-SUBAGENT-MODEL>foxcode-gemini,gemini-2.5-pro</CCR-SUBAGENT-MODEL>  -->
<CCR-SUBAGENT-MODEL>openrouter,google/gemini-2.5-pro-preview</CCR-SUBAGENT-MODEL>

You are a Senior Frontend Engineer specializing in UI/UX implementation.

## Your Role
- Implement beautiful, responsive user interfaces
- Create React/Vue/HTML components from design specs
- Handle CSS/Tailwind styling with pixel-perfect precision
- Ensure accessibility and cross-browser compatibility

## Rules
- Write clean, maintainable frontend code
- Follow the project's existing styling patterns
- Use semantic HTML elements
- Ensure responsive design (mobile-first)
- Add appropriate ARIA attributes

## Output
- Write code directly to files
- Test with available tools
- Report what was created/modified
```

### 3.5 Document Writer 代理（快速文档）

创建 `.claude/agents/document-writer.md`：

```markdown
---
name: document-writer
description: |
  Technical documentation specialist. Use for writing docs, README files,
  API documentation, guides, and technical specifications.
  Triggers on: document, docs, README, write documentation, API docs, guide
model: sonnet
tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
---

<!-- === CCR 路由标签 === -->
<!-- OpenRouter:  <CCR-SUBAGENT-MODEL>openrouter,google/gemini-3-flash</CCR-SUBAGENT-MODEL>  -->
<!-- Foxcode:     <CCR-SUBAGENT-MODEL>foxcode-gemini,gemini-3-flash</CCR-SUBAGENT-MODEL>  -->
<CCR-SUBAGENT-MODEL>openrouter,google/gemini-3-flash</CCR-SUBAGENT-MODEL>

You are a Technical Documentation Writer.

## Your Role
- Write clear, comprehensive documentation
- Create README files, API docs, and guides
- Document code architecture and design decisions
- Maintain consistent documentation style

## Rules
- Use clear, concise language
- Include code examples where helpful
- Follow the project's existing documentation style
- Structure documents with logical hierarchy
- Always include a summary at the top

## Output Format
- Write directly to .md files
- Use proper Markdown formatting
- Include table of contents for long documents
```

### 3.6 Oracle 代理（深度推理）

创建 `.claude/agents/oracle.md`：

```markdown
---
name: oracle
description: |
  Architecture and deep reasoning specialist. Use for complex debugging,
  architectural decisions, code review, and strategic technical analysis.
  Triggers on: architecture, debug, review, analyze, strategy, design pattern
model: opus
tools:
  - Read
  - Glob
  - Grep
  - Bash
---

<!-- === CCR 路由标签 === -->
<!-- OpenRouter + DeepSeek: <CCR-SUBAGENT-MODEL>openrouter,deepseek/deepseek-reasoner</CCR-SUBAGENT-MODEL>  -->
<!-- OpenRouter + Codex:    <CCR-SUBAGENT-MODEL>openrouter,openai/gpt-5.2-codex</CCR-SUBAGENT-MODEL>  -->
<!-- Foxcode + Codex:       <CCR-SUBAGENT-MODEL>foxcode-codex,gpt-5.2-codex</CCR-SUBAGENT-MODEL>  -->
<CCR-SUBAGENT-MODEL>openrouter,deepseek/deepseek-reasoner</CCR-SUBAGENT-MODEL>

You are Oracle, an Architecture and Deep Reasoning Specialist.

## Your Role
- Analyze complex architectural decisions
- Debug difficult issues through systematic reasoning
- Review code for correctness, security, and performance
- Provide strategic technical recommendations

## Rules
- NEVER modify code directly
- Think step by step, show your reasoning
- Consider edge cases and failure modes
- Provide concrete, actionable recommendations
- Reference specific files and line numbers

## Output Format

### Analysis
- **Problem**: [clear problem statement]
- **Root Cause**: [identified cause]
- **Reasoning**: [step-by-step analysis]
- **Recommendation**: [specific action items]
- **Risk Assessment**: [potential risks of recommendation]
```

### 3.7 Librarian 代理（文档研究）

创建 `.claude/agents/librarian.md`：

```markdown
---
name: librarian
description: |
  Documentation research and codebase analysis specialist. Use for finding
  examples in external docs, analyzing OSS codebases, and researching
  implementation patterns.
  Triggers on: research, find examples, documentation lookup, how does X work
model: haiku
tools:
  - Read
  - Glob
  - Grep
  - Bash
---

<!-- === CCR 路由标签 === -->
<!-- OpenRouter:  <CCR-SUBAGENT-MODEL>openrouter,google/gemini-3-flash</CCR-SUBAGENT-MODEL>  -->
<!-- Foxcode:     <CCR-SUBAGENT-MODEL>foxcode-gemini,gemini-3-flash</CCR-SUBAGENT-MODEL>  -->
<CCR-SUBAGENT-MODEL>openrouter,google/gemini-3-flash</CCR-SUBAGENT-MODEL>

You are Librarian, a Research and Documentation Analysis Specialist.

## Your Role
- Research external documentation and APIs
- Find implementation examples and patterns
- Analyze open-source codebases for reference
- Synthesize findings into actionable summaries

## Rules
- NEVER modify any project files
- Always cite sources (file paths, URLs, line numbers)
- Provide evidence-based answers
- Distinguish between facts and assumptions
- Return structured, scannable results

## Output Format

### Research Findings
- **Query**: [what was researched]
- **Sources**: [list of sources consulted]
- **Key Findings**: [numbered list of findings]
- **Recommended Approach**: [based on evidence]
- **References**: [links/paths for further reading]
```

---

## Phase 4: 配置编排指令

### 4.1 在 CLAUDE.md 中添加代理路由规则

在项目根目录的 `CLAUDE.md` 文件末尾添加（如不存在则创建）：

```markdown
## 多代理编排规则

### 代理委派策略

当需要委派任务给子代理时，遵循以下路由规则：

| 任务类型 | 委派给 | 说明 |
|---------|--------|------|
| 代码搜索/文件查找 | explore | 快速搜索，只读 |
| 前端 UI/UX 实现 | frontend-engineer | 创意 UI 实现 |
| 文档撰写 | document-writer | 技术文档和 README |
| 架构分析/深度调试 | oracle | 深度推理，只读 |
| 文档研究/示例查找 | librarian | 信息收集，只读 |
| 核心代码实现 | 原生子代理 (Sisyphus) | 走 Claude 原生订阅 |

### 并行执行原则

- 独立任务应使用 background task 并行执行
- 只读代理（explore, oracle, librarian）可自由并行
- 写入代理（frontend-engineer, document-writer）操作不同文件时可并行
- 核心实现任务（Sisyphus）通常串行以确保代码一致性

### 自动继续规则

- 后台任务完成后，检查 .sisyphus/plans/ 中的当前计划
- 还有未完成的 TODO 项 → 立即执行下一个
- 所有 TODO 完成 → 生成最终报告并等待用户
- 不要因为子代理返回结果就停下来等待用户
```

### 4.2 创建 AGENTS.md 代理注册表

在项目根目录创建 `AGENTS.md`：

```markdown
# Agent Registry

## 外部模型代理（通过 Claude Code Router）

### explore
- **职责**: 快速代码搜索、文件查找、项目结构映射
- **权限**: 只读（Read, Glob, Grep, Bash）
- **理想模型**: Grok 3 Fast / Gemini 3 Flash
- **触发**: 搜索文件、查找模式、了解项目结构时

### frontend-engineer
- **职责**: 前端 UI/UX 实现、React 组件、CSS 样式
- **权限**: 读写（Read, Write, Edit, Bash, Glob, Grep）
- **理想模型**: Gemini 2.5 Pro
- **触发**: 构建或修改用户界面时

### document-writer
- **职责**: 技术文档撰写、README、API 文档、指南
- **权限**: 读写（Read, Write, Edit, Glob, Grep）
- **理想模型**: Gemini 3 Flash
- **触发**: 编写文档时

### oracle
- **职责**: 架构分析、深度调试、代码审查、技术策略
- **权限**: 只读（Read, Glob, Grep, Bash）
- **理想模型**: DeepSeek Reasoner / GPT-5.2 Codex
- **触发**: 复杂调试、架构决策、代码审查时

### librarian
- **职责**: 文档研究、OSS 分析、实现模式查找
- **权限**: 只读（Read, Glob, Grep, Bash）
- **理想模型**: Gemini 3 Flash
- **触发**: 研究外部文档、查找实现示例时

## 原生代理（直接使用 Claude 订阅）

### Sisyphus / general-purpose
- **职责**: 核心代码实现
- **权限**: 完整
- **模型**: Claude Opus/Sonnet（原生订阅）
```

---

## Phase 5: 配置自动继续机制 (Stop Hook)

### 5.1 检查 oh-my-claude 是否已包含 Stop Hook

```bash
cat .claude/oh-my-claude/hooks/stop.sh 2>/dev/null
grep -r "stop" .claude/oh-my-claude/hooks/ 2>/dev/null
```

如果 oh-my-claude 已经有 Stop hook（它应该有），跳到 5.3 直接验证。

### 5.2 如果没有 Stop Hook，手动创建

创建 `.claude/hooks/stop-continuation.sh`：

```bash
#!/bin/bash
# Stop Hook: 检查是否还有未完成的任务，强制继续

SISYPHUS_DIR=".sisyphus"
PLANS_DIR="$SISYPHUS_DIR/plans"
BOULDER_FILE="$SISYPHUS_DIR/boulder.json"

# 检查是否有活跃的 boulder（正在执行的计划）
if [ -f "$BOULDER_FILE" ]; then
    CURRENT_PLAN=$(cat "$BOULDER_FILE" 2>/dev/null | grep -o '"plan":"[^"]*"' | cut -d'"' -f4)

    if [ -n "$CURRENT_PLAN" ] && [ -f "$PLANS_DIR/$CURRENT_PLAN" ]; then
        UNCHECKED=$(grep -c "^\- \[ \]" "$PLANS_DIR/$CURRENT_PLAN" 2>/dev/null || echo "0")

        if [ "$UNCHECKED" -gt 0 ]; then
            echo "⚠️ 计划还有 $UNCHECKED 个未完成任务。继续执行下一个 TODO。" >&2
            exit 2
        fi
    fi
fi

exit 0
```

```bash
chmod +x .claude/hooks/stop-continuation.sh
```

### 5.3 确保 Stop Hook 在 settings.json 中注册

编辑 `.claude/settings.json`，确认 `hooks.Stop` 数组包含续继脚本。如果 oh-my-claude 已有自己的 Stop hook，确认它包含 boulder 续继逻辑即可，不要覆盖。

---

## Phase 6: 端到端测试

### 6.1 启动系统

```bash
# 终端 1: 启动 CCR
ccr start

# 终端 2: 通过 CCR 启动 Claude Code
ccr code
```

### 6.2 测试单个外部模型代理

```
# 测试搜索代理（应路由到 Grok 或 Gemini）
Use the explore subagent to list all JavaScript files in this project

# 测试推理代理（应路由到 DeepSeek 或 Codex）
Use the oracle subagent to analyze the architecture of this project

# 测试文档代理（应路由到 Gemini）
Use the document-writer subagent to create a README for this project
```

同时监控 CCR 日志：

```bash
tail -f ~/.claude-code-router/logs/ccr-*.log
```

**验证**：日志中应该看到子代理请求被路由到外部端点，而主代理请求走原生 Anthropic API。

### 6.3 测试并行执行

```
I need three things done in parallel:
1. Use explore to find all API endpoint definitions
2. Use librarian to research JWT authentication best practices
3. Use oracle to review our current security architecture

Run all three as background tasks.
```

### 6.4 测试完整 OMO 编排流程

```
@plan I want to add a dark mode toggle feature to the application
# → 回答 Prometheus 访谈
/start-work
# → 观察 Atlas 自动委派、自动推进
```

### 6.5 验证清单

- [ ] `ccr status` 显示 Running
- [ ] 外部模型代理请求被路由到对应 Provider
- [ ] 主代理请求走原生 Claude 订阅
- [ ] 并行子代理可同时运行
- [ ] Stop hook 在有未完成 TODO 时阻止主代理停止
- [ ] CCR 日志中能区分不同 Provider 的请求

---

## Phase 7: 故障排除

### CCR 路由层

| 问题 | 排查 | 解决 |
|------|------|------|
| 子代理返回 401/403 | 检查环境变量和 API Key | `echo $你的KEY变量名` 确认已设置 |
| 子代理返回「模型不存在」 | 模型名和 Provider 实际支持的不一致 | 查 Provider 文档，修改 config.json 中的模型名 |
| CCR 未路由（走了原生） | `<CCR-SUBAGENT-MODEL>` 标签位置不对 | 确认标签是代理 prompt body 的**第一行**（frontmatter 之后） |
| Claude 主代理也被路由了 | `Router.default` 配置错误 | 确保 `"default": "anthropic-native"` |
| Provider 超时 | 中转站延迟或限流 | 检查 Provider 状态，考虑换 Provider 或加超时配置 |

### oh-my-claude 编排层

| 问题 | 解决 |
|------|------|
| Prometheus 不启动 | 确认 oh-my-claude 安装完成，agents 目录存在 |
| Atlas 不自动继续 | 检查 Stop hook 注册和可执行权限 |
| boulder.json 卡住 | `rm .sisyphus/boulder.json` 然后重新 `/start-work` |
| 子代理 MCP 工具不可用 | 后台子代理的已知限制，改用 Bash 工具替代 |

### 快速切换 Provider

如果你想把某个代理从 OpenRouter 切到 Foxcode（或反过来），只需：

1. 修改该代理 `.md` 文件中的 `<CCR-SUBAGENT-MODEL>` 标签
2. 确保 `config.json` 中有对应 Provider 的配置
3. `ccr restart`

其他代理完全不受影响。

---

## 快速参考卡

```bash
# === 每次使用 ===
ccr start && ccr code              # 启动系统

# === OMO 编排 ===
@plan [描述需求]                    # 进入规划模式
/start-work                         # 执行计划

# === 手动调用特定代理 ===
Use the explore subagent to ...     # → Grok / Gemini Flash
Use the oracle subagent to ...      # → DeepSeek / Codex
Use the frontend-engineer to ...    # → Gemini Pro
Use the document-writer to ...      # → Gemini Flash
Use the librarian subagent to ...   # → Gemini Flash

# === 监控 ===
/tasks                              # 查看后台任务
tail -f ~/.claude-code-router/logs/ccr-*.log  # 路由日志
cat .sisyphus/plans/*.md            # 查看计划
cat .sisyphus/notepads/*/learnings.md  # 累积学习

# === 维护 ===
ccr status / ccr restart / ccr stop # CCR 管理
```

---

## 附录 A: OpenRouter Provider 配置

OpenRouter (openrouter.ai) 通过统一 API 接入 300+ 模型，一个 Key 即可访问 Grok、Gemini、DeepSeek、GPT 等所有主流模型。OpenAI 兼容格式，CCR 无需额外 transformer。

### 环境变量

```bash
export OPENROUTER_API_KEY="sk-or-v1-你的密钥"
```

### config.json Providers 配置

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
    "subagent": {
      "enabled": true
    }
  }
}
```

### 子代理标签写法

```
<CCR-SUBAGENT-MODEL>openrouter,x-ai/grok-3-fast</CCR-SUBAGENT-MODEL>
<CCR-SUBAGENT-MODEL>openrouter,google/gemini-2.5-pro-preview</CCR-SUBAGENT-MODEL>
<CCR-SUBAGENT-MODEL>openrouter,google/gemini-3-flash</CCR-SUBAGENT-MODEL>
<CCR-SUBAGENT-MODEL>openrouter,deepseek/deepseek-reasoner</CCR-SUBAGENT-MODEL>
<CCR-SUBAGENT-MODEL>openrouter,openai/gpt-5.2-codex</CCR-SUBAGENT-MODEL>
```

### 注意事项

- OpenRouter 模型名格式为 `provider/model`（如 `x-ai/grok-3-fast`），查完整列表：https://openrouter.ai/models
- 部分模型按 token 计费，部分按次计费，在 OpenRouter 控制台查看各模型价格
- 如果在中国大陆，OpenRouter 可能需要代理才能访问

---

## 附录 B: Foxcode 中转站 Provider 配置

Foxcode (foxcode.hshwk.org) 是国内中转站，统一 Key、三个独立端点（OpenAI / Anthropic / Google 格式各不兼容）。适合中国大陆直连使用。

### 环境变量

```bash
export FOXCODE_API_KEY="你的foxcode密钥"
```

### config.json Providers 配置

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
      "models": [
        "gpt-5.2-codex",
        "gpt-4o",
        "o3-mini"
      ],
      "transformer": {
        "use": []
      }
    },
    {
      "name": "foxcode-gemini",
      "api_base_url": "https://code.newcli.com/gemini/v1beta/models/",
      "api_key": "$FOXCODE_API_KEY",
      "models": [
        "gemini-3-flash",
        "gemini-2.5-pro",
        "gemini-2.5-flash"
      ],
      "transformer": {
        "use": ["gemini"]
      }
    },
    {
      "name": "foxcode-claude",
      "api_base_url": "https://code.newcli.com/claude/droid",
      "api_key": "$FOXCODE_API_KEY",
      "models": [
        "claude-sonnet-4-5-20250929",
        "claude-opus-4-5-20251101"
      ],
      "transformer": {
        "use": ["anthropic"]
      }
    }
  ],

  "Router": {
    "default": "anthropic-native",
    "subagent": {
      "enabled": true
    }
  }
}
```

### 子代理标签写法

```
<CCR-SUBAGENT-MODEL>foxcode-codex,gpt-5.2-codex</CCR-SUBAGENT-MODEL>
<CCR-SUBAGENT-MODEL>foxcode-gemini,gemini-3-flash</CCR-SUBAGENT-MODEL>
<CCR-SUBAGENT-MODEL>foxcode-gemini,gemini-2.5-pro</CCR-SUBAGENT-MODEL>
<CCR-SUBAGENT-MODEL>foxcode-claude,claude-sonnet-4-5-20250929</CCR-SUBAGENT-MODEL>
```

### Foxcode 三端点的 URL 拼接规则

CCR 会根据 transformer 类型自动拼接最终请求 URL：

| Provider | api_base_url 配置 | transformer | CCR 最终请求 URL |
|----------|------------------|-------------|-----------------|
| foxcode-codex | `.../codex/v1/chat/completions` | 空（原生 OpenAI） | 直接使用 api_base_url |
| foxcode-gemini | `.../gemini/v1beta/models/` | gemini | `{base_url}{model}:generateContent` |
| foxcode-claude | `.../claude/droid` | anthropic | `{base_url}/v1/messages` |

最终 URL 与 curl 测试命令一致：
- Codex → `https://code.newcli.com/codex/v1/chat/completions` ✓
- Gemini → `https://code.newcli.com/gemini/v1beta/models/gemini-3-flash:generateContent` ✓
- Claude → `https://code.newcli.com/claude/droid/v1/messages` ✓

### Foxcode 使用 explore 和 oracle 时的模型回退

Foxcode 目前没有 Grok 和 DeepSeek 端点，因此：
- explore 理想模型 Grok 3 Fast → **回退为 Gemini 3 Flash**（foxcode-gemini）
- oracle 理想模型 DeepSeek Reasoner → **回退为 GPT-5.2 Codex**（foxcode-codex）

如果 Foxcode 后续新增端点，在 Providers 数组中添加新 Provider、修改对应代理标签、`ccr restart` 即可。

### 验证 Foxcode 端点

配置 CCR 前，先用 curl 确认各端点可用：

```bash
# 测试 Gemini 3 Flash
curl -X POST "https://code.newcli.com/gemini/v1beta/models/gemini-3-flash:generateContent" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $FOXCODE_API_KEY" \
  -d '{"contents":[{"parts":[{"text":"Hello"}]}]}'

# 测试 GPT-5.2 Codex
curl -X POST "https://code.newcli.com/codex/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $FOXCODE_API_KEY" \
  -d '{"model":"gpt-5.2-codex","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'

# 测试 Gemini 2.5 Pro（确认模型名）
curl -X POST "https://code.newcli.com/gemini/v1beta/models/gemini-2.5-pro:generateContent" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $FOXCODE_API_KEY" \
  -d '{"contents":[{"parts":[{"text":"Hello"}]}]}'
```

---

## 附录 C: 混合 Provider 配置模板

当你需要组合多个 Provider（比如 Grok 走 OpenRouter、Gemini 走 Foxcode），在 Providers 数组中并列配置即可。CCR 按子代理标签中的 Provider 名精确路由。

### config.json 示例

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
  ],

  "Router": {
    "default": "anthropic-native",
    "subagent": { "enabled": true }
  }
}
```

### 混合路由效果

| 代理 | 标签 | 走哪条线路 | 理由 |
|------|------|-----------|------|
| explore | `openrouter,x-ai/grok-3-fast` | OpenRouter → Grok | 理想模型，国外直连快 |
| oracle | `openrouter,deepseek/deepseek-reasoner` | OpenRouter → DeepSeek | 理想模型，推理链 |
| frontend-engineer | `foxcode-gemini,gemini-2.5-pro` | Foxcode → Gemini | 国内低延迟 |
| document-writer | `foxcode-gemini,gemini-3-flash` | Foxcode → Gemini | 国内低延迟 |
| librarian | `foxcode-gemini,gemini-3-flash` | Foxcode → Gemini | 国内低延迟 |

每个代理可以独立选择最优线路，互不影响。需要的环境变量：`OPENROUTER_API_KEY` + `FOXCODE_API_KEY`。

### 自定义其他中转站

任何兼容 OpenAI / Anthropic / Google API 格式的中转站都可以作为 Provider 接入。只需三个参数：

```json
{
  "name": "你的provider名",                    // 自定义，用于标签引用
  "api_base_url": "https://你的中转站/路径",     // API 端点
  "api_key": "$你的环境变量",                    // 认证密钥
  "models": ["支持的模型名"],                    // 模型列表
  "transformer": { "use": ["格式类型"] }        // 见下表
}
```

Transformer 选择：

| 中转站 API 格式 | transformer | 说明 |
|----------------|-------------|------|
| OpenAI 兼容 (`/v1/chat/completions`) | `[]` 或 `["openrouter"]` | 大多数中转站 |
| Anthropic 原生 (`/v1/messages`) | `["anthropic"]` | Anthropic 官方或兼容站 |
| Google Gemini (`/v1beta/models/`) | `["gemini"]` | Google 官方或兼容站 |

---

## 附录 D: 完整文件清单

```
项目根目录/
├── CLAUDE.md                              # 编排规则（Phase 4.1）
├── AGENTS.md                              # 代理注册表（Phase 4.2）
├── .claude/
│   ├── settings.json                      # hooks 配置
│   ├── agents/
│   │   ├── explore.md                     # 搜索代理
│   │   ├── frontend-engineer.md           # 前端代理
│   │   ├── document-writer.md             # 文档代理
│   │   ├── oracle.md                      # 推理代理
│   │   └── librarian.md                   # 研究代理
│   ├── hooks/
│   │   └── stop-continuation.sh           # 自动继续 hook
│   └── oh-my-claude/                      # oh-my-claude 安装目录
├── .sisyphus/                             # 运行时状态（自动创建）
│   ├── plans/
│   ├── drafts/
│   ├── notepads/
│   └── boulder.json
└── ~/.claude-code-router/
    ├── config.json                        # CCR 配置（从附录 A/B/C 选择）
    └── logs/
```
