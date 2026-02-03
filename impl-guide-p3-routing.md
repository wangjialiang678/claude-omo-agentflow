# 实施指南 P3: 模型路由

> **阶段**: P3
> **前置依赖**: P2 (代理定义已创建)
> **关联**: plan-and-spec.md Section 五, claude-omo-agentflow-v2.md Section 4.2

---

## 概述

本阶段安装和配置 Claude Code Router (CCR)，实现异构模型路由。

核心目标：
- 后端代码/审核 → Codex（次选 Opus，**禁用 Sonnet**）
- 前端代码 → Gemini Pro
- 调研/搜索/文档 → Gemini Flash
- 规划/编排 → Claude Opus 原生（不经过 CCR）

---

## Step 1: 安装 CCR

```bash
npm install -g @musistudio/claude-code-router
```

验证安装：

```bash
ccr --version
```

## Step 2: 设置 API Key

```bash
# 方案 A: OpenRouter（推荐，一个 Key 接入所有模型）
export OPENROUTER_API_KEY="sk-or-v1-你的密钥"

# 方案 B: Foxcode 中转站（国内直连）
export FOXCODE_API_KEY="你的foxcode密钥"

# 写入 shell profile 持久化
echo 'export OPENROUTER_API_KEY="sk-or-v1-你的密钥"' >> ~/.zshrc
```

## Step 3: 创建 CCR 配置

### 方案 A: OpenRouter（推荐）

```bash
mkdir -p ~/.claude-code-router
```

写入 `~/.claude-code-router/config.json`：

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
    "subagent": {
      "enabled": true
    }
  }
}
```

### 方案 B: Foxcode 中转站

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

### 方案 C: 混合（Codex 走 OpenRouter，Gemini 走 Foxcode）

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
  ],
  "Router": {
    "default": "anthropic-native",
    "subagent": { "enabled": true }
  }
}
```

## Step 4: 更新代理 CCR 标签

确认每个代理文件中的 CCR 标签与 config.json 中的 Provider 名和模型名一致。

**OpenRouter 方案标签**：

| 代理文件 | 标签内容 |
|---------|---------|
| backend-coder.md | `<CCR-SUBAGENT-MODEL>openrouter,openai/gpt-5.2-codex</CCR-SUBAGENT-MODEL>` |
| frontend-coder.md | `<CCR-SUBAGENT-MODEL>openrouter,google/gemini-2.5-pro-preview</CCR-SUBAGENT-MODEL>` |
| reviewer.md | `<CCR-SUBAGENT-MODEL>openrouter,openai/gpt-5.2-codex</CCR-SUBAGENT-MODEL>` |
| researcher.md | `<CCR-SUBAGENT-MODEL>openrouter,google/gemini-3-flash</CCR-SUBAGENT-MODEL>` |
| explorer.md | `<CCR-SUBAGENT-MODEL>openrouter,google/gemini-3-flash</CCR-SUBAGENT-MODEL>` |
| doc-writer.md | `<CCR-SUBAGENT-MODEL>openrouter,google/gemini-3-flash</CCR-SUBAGENT-MODEL>` |
| planner.md | **无标签** |

**Foxcode 方案标签**：

| 代理文件 | 标签内容 |
|---------|---------|
| backend-coder.md | `<CCR-SUBAGENT-MODEL>foxcode-codex,gpt-5.2-codex</CCR-SUBAGENT-MODEL>` |
| frontend-coder.md | `<CCR-SUBAGENT-MODEL>foxcode-gemini,gemini-2.5-pro</CCR-SUBAGENT-MODEL>` |
| reviewer.md | `<CCR-SUBAGENT-MODEL>foxcode-codex,gpt-5.2-codex</CCR-SUBAGENT-MODEL>` |
| researcher.md | `<CCR-SUBAGENT-MODEL>foxcode-gemini,gemini-3-flash</CCR-SUBAGENT-MODEL>` |
| explorer.md | `<CCR-SUBAGENT-MODEL>foxcode-gemini,gemini-3-flash</CCR-SUBAGENT-MODEL>` |
| doc-writer.md | `<CCR-SUBAGENT-MODEL>foxcode-gemini,gemini-3-flash</CCR-SUBAGENT-MODEL>` |

> **重要**: CCR 标签必须在代理 .md 文件的 **Markdown 正文第一行**（frontmatter `---` 之后的第一行）。

## Step 5: 启动和验证

```bash
# 启动 CCR
ccr start

# 检查状态
ccr status
# 应显示 Running

# 查看日志目录
ls ~/.claude-code-router/logs/

# 使用 CCR 启动 Claude Code
ccr code
# 或
eval $(ccr activate) && claude
```

## Step 6: 路由测试

在 Claude Code 中依次执行以下测试：

```
# 测试 1: explorer 路由到 Gemini Flash
> Use the explorer subagent to list all JavaScript files in this project

# 检查 CCR 日志
tail -f ~/.claude-code-router/logs/ccr-*.log
# 应看到请求被路由到 google/gemini-3-flash

# 测试 2: backend-coder 路由到 Codex
> Use the backend-coder subagent to review the main entry point

# 测试 3: planner 走原生（无 CCR 日志）
> Use the planner subagent to analyze the project structure

# 测试 4: 主代理走原生
> What is 2 + 2?
# CCR 日志中不应有此请求
```

## Step 7: 回退方案

如果 CCR 不稳定，可回退到 OpenRouter 直连（失去 subagent 级路由，但更稳定）：

```bash
# 停止 CCR
ccr stop

# 直连 OpenRouter（所有请求走同一模型）
export ANTHROPIC_BASE_URL=https://openrouter.ai/api
export ANTHROPIC_API_KEY=$OPENROUTER_API_KEY
```

## 验收标准

```bash
echo "=== P3 Tests ==="

# CCR 已安装
which ccr && echo "PASS: ccr installed" || echo "FAIL: ccr not found"

# 配置文件存在
test -f ~/.claude-code-router/config.json && echo "PASS: config exists" || echo "FAIL: config missing"

# Router default 正确
jq -r '.Router.default' ~/.claude-code-router/config.json | grep -q "anthropic-native" \
  && echo "PASS: default is anthropic-native" || echo "FAIL: default wrong"

# Subagent routing enabled
jq -r '.Router.subagent.enabled' ~/.claude-code-router/config.json | grep -q "true" \
  && echo "PASS: subagent routing enabled" || echo "FAIL: subagent routing disabled"

# 所有需要路由的代理有 CCR 标签
for agent in backend-coder frontend-coder reviewer researcher explorer doc-writer; do
  grep -q "CCR-SUBAGENT-MODEL" ".claude/agents/$agent.md" \
    && echo "PASS: $agent has CCR tag" || echo "FAIL: $agent missing tag"
done

# planner 无 CCR 标签
grep -q "CCR-SUBAGENT-MODEL" ".claude/agents/planner.md" \
  && echo "FAIL: planner should not be routed" || echo "PASS: planner not routed"

echo "=== Done ==="
```
