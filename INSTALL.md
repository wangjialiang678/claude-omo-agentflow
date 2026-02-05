# 掌天瓶 (Orchestrate) — 安装指南

> **本文档面向 AI 阅读**。部署时由 Claude Code 或其他 AI 按此文档逐步执行。

---

## ⚠️ 重要：环境兼容性提醒

**在开始部署前，必须向用户确认运行环境：**

### Claude Code（推荐）
- ✅ **按本文档直接操作**
- 所有路径和文件名无需调整
- `.claude/` 目录结构为标准配置

### Cursor 或其他 AI IDE
- ⚠️ **可能需要调整路径和文件名**
- Cursor 使用 `.cursorrules` 而非 `.claude/`
- 需要根据具体 IDE 的配置目录结构调整：
  - `.claude/hooks/` → 对应的 hooks 目录
  - `.claude/agents/` → 对应的 agents 目录
  - `.claude/skills/` → 对应的 skills/commands 目录
- 建议用户查阅其 IDE 文档确认正确的配置路径

**如果用户使用的是 Claude Code**，告知用户："您使用的是 Claude Code，可以按标准流程部署，无需调整。"

**如果用户使用的是 Cursor 或其他 IDE**，告知用户："您使用的不是 Claude Code。在部署过程中，我会根据您的 IDE 配置目录结构自动调整路径。请确认您的 IDE 配置目录位置（如 .cursorrules 或其他）。"

---

## 一、前置依赖

在开始前确认以下工具已安装：

```bash
# 必需
jq --version    # JSON 处理，brew install jq

# 可选（仅模型路由需要）
node --version  # Node.js 18+，用于 CCR
```

---

## 二、部署模式选择

**在部署前，必须向用户确认使用哪种模式：**

| 模式 | 主代理 | 子代理 | 需要 |
|------|--------|--------|------|
| A: 纯订阅 | Claude 订阅 | Claude 订阅 | 无额外配置 |
| B: 纯 API | Anthropic API | Anthropic API | ANTHROPIC_API_KEY |
| C: 订阅 + 第三方路由 | Claude 订阅 | Codex/Gemini via OpenRouter | OPENROUTER_API_KEY + CCR |

- 模式 A/B：跳过 CCR 相关步骤，代理文件中的 CCR 标签会被忽略
- 模式 C：需要完成第七节 CCR 配置

---

## 三、文件清单

### 3.1 需要创建的目录

```
.claude/hooks/lib/
.claude/agents/
.claude/skills/orchestrate/
.claude/skills/switch-orchestrate/
.claude/agentflow/plans/
.claude/agentflow/tasks/
.claude/agentflow/results/
.claude/agentflow/state/
.claude/agentflow/state/snapshots/
.claude/agentflow/workflows/
.claude/agentflow/learnings/
.claude/agentflow/scripts/
.claude/agentflow/scripts/lib/
```

### 3.2 需要创建的文件

| 文件 | 来源 | 说明 |
|------|------|------|
| `.claude/hooks/stop.sh` | 本项目 | 自动继续 + 模式开关 |
| `.claude/hooks/subagent-stop.sh` | 本项目 | 子代理完成追踪 |
| `.claude/hooks/pre-compact.sh` | 本项目 | 上下文压缩前状态保存 |
| `.claude/hooks/lib/json-utils.sh` | 本项目 | JSON 工具库 |
| `.claude/hooks/lib/loop-guard.sh` | 本项目 | 四层循环防护 |
| `.claude/hooks/lib/state-manager.sh` | 本项目 | 状态管理 |
| `.claude/agents/planner.md` | 本项目 | 规划代理 |
| `.claude/agents/backend-coder.md` | 本项目 | 后端代码代理 |
| `.claude/agents/frontend-coder.md` | 本项目 | 前端代码代理 |
| `.claude/agents/reviewer.md` | 本项目 | 代码审核代理 |
| `.claude/agents/researcher.md` | 本项目 | 调研代理 |
| `.claude/agents/explorer.md` | 本项目 | 搜索代理 |
| `.claude/agents/doc-writer.md` | 本项目 | 文档代理 |
| `.claude/skills/orchestrate/SKILL.md` | 本项目 | 掌天瓶 Skill |
| `.claude/skills/switch-orchestrate/SKILL.md` | 本项目 | 模式切换 Skill |
| `.claude/agentflow/scripts/create-pool.sh` | 本项目 | 创建任务池 |
| `.claude/agentflow/scripts/claim-task.sh` | 本项目 | 原子认领 |
| `.claude/agentflow/scripts/complete-task.sh` | 本项目 | 标记完成 |
| `.claude/agentflow/scripts/release-timeout.sh` | 本项目 | 超时释放 |
| `.claude/agentflow/scripts/lib/file-lock.sh` | 本项目 | 共享文件锁（PID 验证） |
| `.claude/agentflow/scripts/pool-status.sh` | 本项目 | 任务池状态 |
| `.claude/agentflow/workflows/review.yaml` | 本项目 | 审查流水线 |
| `.claude/agentflow/workflows/implement.yaml` | 本项目 | 实现流水线 |
| `.claude/agentflow/workflows/research.yaml` | 本项目 | 调研流水线 |
| `.claude/agentflow/workflows/debug.yaml` | 本项目 | 修复流水线 |
| `.claude/agentflow/learnings/decisions.md` | 本项目 | 决策日志模板 |
| `.claude/agentflow/learnings/learnings.md` | 本项目 | 经验日志模板 |
| `.claude/agentflow/agents.md` | 本项目 | 代理注册表 |

### 3.3 需要初始化的状态文件

```bash
echo '{"active":false}' > .claude/agentflow/state/workflow-state.json
echo '{"pool_id":"empty","tasks":[]}' > .claude/agentflow/tasks/task-pool.json
echo "off" > .claude/agentflow/state/mode.txt
```

---

## 四、settings.json 合并规则

**⚠️ 不要覆盖目标项目的 settings.json。使用 jq 深度合并。**

### 需要添加的 hooks 配置

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

### 合并方法

如果目标项目**没有** `.claude/settings.json`：
- 直接创建上述 JSON 文件

如果目标项目**已有** `.claude/settings.json`：
- 使用 jq 深度合并：
  ```bash
  # 备份
  cp .claude/settings.json .claude/settings.json.backup

  # 合并（保留已有 hooks，追加新的）
  jq -s '.[0] * .[1]' .claude/settings.json new-hooks.json > .claude/settings.json.tmp
  mv .claude/settings.json.tmp .claude/settings.json
  ```
- 如果已有同名 hook（如 Stop），需要手动检查是否冲突

---

## 五、CLAUDE.md 处理

**⚠️ 修改 CLAUDE.md 前必须向用户展示 diff 并等待确认。**

在目标项目的 CLAUDE.md 末尾追加以下内容（约 10 行）：

```markdown
## 掌天瓶 (Orchestrate)

本项目支持异构多代理掌天瓶。代理注册表见 `.claude/agentflow/agents.md`。
- 启用掌天瓶：说"启用掌天瓶"或"orchestrate on"
- 关闭掌天瓶：说"关闭掌天瓶"或"orchestrate off"
- 紧急退出：`touch /tmp/FORCE_STOP`
- 当前状态：`.claude/agentflow/state/mode.txt`（on/off）
```

**如果用户拒绝修改 CLAUDE.md**，掌天瓶仍可通过 Skill 触发使用，只是不会在 CLAUDE.md 中有提示。

---

## 六、文件权限

```bash
chmod +x .claude/hooks/stop.sh
chmod +x .claude/hooks/subagent-stop.sh
chmod +x .claude/hooks/pre-compact.sh
chmod +x .claude/hooks/lib/*.sh
chmod +x .claude/agentflow/scripts/*.sh
chmod +x .claude/agentflow/scripts/lib/*.sh
```

---

## 七、CCR 配置（仅模式 C）

### 7.1 安装 CCR

```bash
npm install -g @musistudio/claude-code-router
```

### 7.2 向用户询问 Provider

| Provider | 说明 | 需要的 Key |
|----------|------|-----------|
| OpenRouter | 一个 Key 接入所有模型（推荐） | OPENROUTER_API_KEY |
| Foxcode | 国内直连 | FOXCODE_API_KEY |
| 混合 | Codex 走 OpenRouter，Gemini 走 Foxcode | 两个 Key |

### 7.3 创建配置文件

路径：`~/.claude-code-router/config.json`

**OpenRouter 模板**：
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
        "google/gemini-3-flash"
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

### 7.4 设置环境变量

```bash
export OPENROUTER_API_KEY="sk-or-v1-用户的密钥"
# 写入 shell profile 持久化
echo 'export OPENROUTER_API_KEY="sk-or-v1-用户的密钥"' >> ~/.zshrc
```

### 7.5 启动和验证

```bash
ccr start
ccr status  # 应显示 Running
ccr code    # 用 CCR 启动 Claude Code
```

---

## 八、验收测试

部署完成后运行以下测试：

```bash
echo "=== 目录结构 ==="
for d in .claude/hooks/lib .claude/agents .claude/skills/orchestrate .claude/agentflow/scripts .claude/agentflow/workflows .claude/agentflow/state; do
  test -d "$d" && echo "  ✓ $d" || echo "  ✗ $d"
done

echo "=== Hooks ==="
for f in stop.sh subagent-stop.sh pre-compact.sh; do
  test -x ".claude/hooks/$f" && echo "  ✓ $f" || echo "  ✗ $f"
done

echo "=== Agents ==="
for a in planner backend-coder frontend-coder reviewer researcher explorer doc-writer; do
  test -f ".claude/agents/$a.md" && echo "  ✓ $a.md" || echo "  ✗ $a.md"
done

echo "=== Skills ==="
test -f .claude/skills/orchestrate/SKILL.md && echo "  ✓ orchestrate" || echo "  ✗ orchestrate"
test -f .claude/skills/switch-orchestrate/SKILL.md && echo "  ✓ switch-orchestrate" || echo "  ✗ switch-orchestrate"

echo "=== 模式切换 ==="
# 默认 off → stop.sh 直接放行
echo '{"stop_hook_active":false}' | .claude/hooks/stop.sh > /dev/null 2>&1
echo "  off 模式 exit: $? (expect 0)"

# 切换到 on
echo "on" > .claude/agentflow/state/mode.txt
echo "- [ ] task 1" > .claude/agentflow/plans/current-plan.md
RESULT=$(echo '{"stop_hook_active":false}' | .claude/hooks/stop.sh 2>/dev/null)
echo "$RESULT" | jq -r '.decision' 2>/dev/null | grep -q "block" \
  && echo "  ✓ on 模式阻止停止" || echo "  ✗ on 模式应阻止"

# 清理
echo "off" > .claude/agentflow/state/mode.txt
rm -f .claude/agentflow/plans/current-plan.md
rm -f .claude/agentflow/state/stop-retries.txt .claude/agentflow/state/stop-start-time.txt
echo "  ✓ 清理完成"
```

---

## 九、（可选）启用 Git Pre-commit 保护

防止敏感运行时文件被意外提交：

```bash
git config core.hooksPath .githooks
```

这会激活 `.githooks/pre-commit`，阻止以下路径进入 git：
- `.claude/memory-bank/`
- `.orchestrator/state/`、`.orchestrator/results/`、`.orchestrator/tasks/`
- `.claude/settings.local.json`

---

## 十、注意事项

1. **Hook 必须直接安装到 `.claude/hooks/`**，不要用 Plugin 安装（存在 exit code 2 bug）
2. **默认模式为 off**，不会干扰非编码任务（调研、写作等）
3. **CCR 标签在无 CCR 时无害**，代理仍可通过 Claude 原生模型工作
4. **macOS 兼容**：任务池脚本使用 `mkdir` 锁（带 PID 验证），不依赖 `flock`
5. **紧急退出**：任何时候 `touch /tmp/FORCE_STOP` 都能让 Stop Hook 放行
