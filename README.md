# claude-omo-agentflow

> **O**rchestration with **M**ulti-model **O**ptimization for Claude Code **Agent** work**flow**s

中文名：**掌天瓶**

轻量级、文件驱动的 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 多代理编排系统。无框架、无依赖——只用 Shell 脚本、Markdown 和 YAML。

### 为什么叫掌天瓶？

《凡人修仙传》里，资质平平的韩立捡到一个不起眼的小绿瓶——掌天瓶。往里倒点月光，它就能催熟灵药、加速成长，让一个没背景没天赋的凡人一路肝到仙界道祖。

这个项目干的事差不多：你往 Claude Code 里倒点配置（Shell 脚本 + YAML），它就能催熟你的开发流程——把一个普通的单代理 CLI 变成自动编排的多代理流水线。资质不够，外挂来凑。

## 为什么需要它

Vibe coding 的瓶颈不是写代码，而是**工作流**。你说一句"帮我加个用户认证"，Claude Code 能写出代码——但一个真实功能涉及规划、前端、后端、审查、文档，你得一步步盯着、一次次点 approve。

| | 不用工作流 | 用 claude-omo-agentflow |
|---|---|---|
| 你说 | "帮我实现用户认证" | "@plan 实现用户认证" |
| 然后 | Claude 写了一坨代码，你人工检查、手动让它继续、发现前端没改、再催一次… | planner 拆分任务 → backend-coder 写逻辑 → frontend-coder 改页面 → reviewer 审查 → 全程自动推进 |
| 你做的事 | 反复打字"继续"，手动分配任务 | 喝杯咖啡，回来看结果 |

这个项目会自动拆解你的任务，然后把任务要求通过 md 文件传递给子智能体执行。它还支持把不同任务交给不同的大模型。例如让 Codex 写后端代码，让 Gemini 写前端代码，让 Opus 与人交互和做计划写文档，让 Gemini Flash 做调研（都是可配置的），可以显著提升 vibe coding 效率，降低错误率，也能让大模型各取所长。

## 要解决什么问题

Claude Code 通过 `Task` 工具支持子代理，但在复杂项目中有三个痛点：

1. **没有结构化的编排机制。** 没有内置的流水线、并行任务池、规划与执行分离。想做多步骤自动化，全靠人工管理。

2. **子代理做完了，主代理不动。** Claude Code 是回合制的。后台子代理完成后，主代理只会等着你输入，你得手动打字"继续"才能推进。）

3. **子代理只能用 Claude。** `model` 字段只接受 Claude 系列模型。但代码审查不需要和快速文件搜索用同一个模型——你可能想让后端代码走 Codex、前端 UI 走 Gemini、调研走 Gemini Flash。

## 这个项目做了什么

**claude-omo-agentflow** 在 Claude Code 原生子代理系统之上加了一层编排：

- **3 种执行模式** — Pipeline（链式流水线）、Swarm（并行任务池）、Autopilot（规划后自动委派）。用 YAML 定义工作流，用自然语言触发。

- **7 个专业代理** — planner、backend-coder、frontend-coder、reviewer、researcher、explorer、doc-writer。每个代理有独立的权限范围和指定模型。

- **自动继续** — Stop Hook 检测未完成工作（待处理的流水线阶段、未认领的任务、未勾选的 TODO），阻止主代理过早停止，自动拾取子代理结果并推进。

- **异构模型路由** — 通过 [Claude Code Router (CCR)](https://github.com/musistudio/claude-code-router)，不同代理可以使用不同的大模型。可选功能——不配置 CCR 也能正常工作。

- **四层安全防护** — `stop_hook_active` 标志 → 强制停止文件 → 最大重试计数 → 超时退出。不会死循环。

### 和其他开源项目相比

本项目在调研 10+ 个开源方案后构建，取长补短：

| 对比维度 | oh-my-claudecode | claude-flow | oh-my-claude (stefandevo) | **本项目** |
|---------|-----------------|-------------|--------------------------|-----------|
| 安装方式 | Plugin SDK（有 [exit 2 bug](https://github.com/anthropics/claude-code/issues/10412)） | npm 包（250k+ 行） | Shell 脚本 | Shell 脚本，**一句话部署** |
| 代理数量 | 32 个（过重） | 可配置 | 7 个 | 7 个（按需扩展） |
| 执行模式 | 5 种 | Pipeline + DAG | Pipeline | Pipeline + Swarm + Autopilot |
| 模型路由 | Haiku/Sonnet/Opus | 无 | 无 | **异构路由**（Codex/Gemini/Flash via CCR） |
| 循环防护 | 无 | 有 | 有 bug（JSON schema 错误） | **四层防护** |
| 依赖 | Claude Code Plugin SDK | Node.js + 多个 npm 包 | Shell + MCP Server | **仅 jq** |

## 代理列表

| 代理 | 职责 | 默认模型 |
|------|------|---------|
| planner | 需求分析与规划 | Claude Opus |
| backend-coder | 后端代码实现 | Codex via CCR |
| frontend-coder | 前端 UI/UX 实现 | Gemini Pro via CCR |
| reviewer | 代码审查与质量保证 | Codex via CCR |
| researcher | 技术调研 | Gemini Flash via CCR |
| explorer | 快速代码搜索 | Gemini Flash via CCR |
| doc-writer | 文档撰写 | Gemini Flash via CCR |

不配置 CCR 时，所有代理回退到 Claude 原生模型（Opus/Sonnet/Haiku）。

## 执行模式

### Pipeline（流水线）

链式多阶段工作流，定义在 `.orchestrator/workflows/`：

| 工作流 | 阶段 |
|--------|------|
| `review` | explore → review → fix → verify |
| `implement` | plan → implement → review |
| `research` | explore → research → summarize |
| `debug` | explore → analyze → fix |

触发方式：*"按 review 流水线审查 src/auth/"*

### Swarm（蜂群并行）

从共享任务池并行执行。多个子代理通过 `mkdir` 原子锁认领任务（不需要 `flock`，macOS 兼容）。

触发方式：*"并行修复所有 lint errors"*

### Autopilot（自主模式）

planner 代理生成 TODO 计划，然后每一项自动委派给对应代理。

触发方式：*"@plan 实现用户认证功能"*

## 快速开始

**前置依赖：** `jq`（`brew install jq`）

1. 克隆本仓库：
   ```bash
   git clone https://github.com/wangjialiang678/claude-omo-agentflow.git ~/projects/claude-omo-agentflow
   ```

2. 在任意项目中打开 Claude Code，说：
   ```
   启用掌天瓶
   ```
   （或 "orchestrate on"）

3. 全局 `switch-orchestrate` skill 会自动检测到当前项目未部署，从本仓库复制所有必要文件并启用系统。一句话搞定。

手动安装或高级配置（CCR 模型路由、Provider 选择）请参考 [INSTALL.md](INSTALL.md)。

## 文件结构

```
.claude/
  agents/              # 7 个代理定义文件 (.md)
  hooks/               # Stop、SubagentStop、PreCompact hooks
    lib/               # json-utils、loop-guard、state-manager
  skills/
    orchestrate/       # 编排主 skill (SKILL.md)
  settings.json        # Hook 注册配置

.orchestrator/
  workflows/           # 流水线定义 (YAML)
  scripts/             # 任务池管理：create、claim、complete、release、status
  tasks/               # 运行时任务池（gitignored）
  state/               # 运行时状态（gitignored）
  results/             # 代理输出（gitignored）
  learnings/           # 决策与经验日志
  plans/               # 执行计划

AGENTS.md              # 代理注册表（角色、模型、工具、权限）
```

## 安全机制

自动继续机制有四层防护，防止死循环：

1. **`stop_hook_active` 标志** — Stop 事件输入中若包含此标志，Hook 直接放行
2. **强制停止文件** — `touch /tmp/FORCE_STOP` 绕过所有检查
3. **最大重试计数** — 连续阻止 5 次后，Hook 自动放行
4. **超时机制** — 阻止超过 300 秒后，Hook 自动放行

系统**默认关闭**，不会干扰任何操作，直到你明确启用。

## 设计文档

- [设计文档 v2](claude-omo-agentflow-v2.md) — 完整架构、调研发现、勘误
- [计划与规格](plan-and-spec.md) — 分阶段实施计划（P0–P6）
- 实施指南：[P0-P1](impl-guide-p0-p1-skeleton-and-hooks.md) · [P2](impl-guide-p2-agents.md) · [P3](impl-guide-p3-routing.md) · [P4-P6](impl-guide-p4-p5-p6-taskpool-workflow-learning.md)

## License

MIT

## 调试模式

遇到问题时，启用调试模式获取详细日志：

```bash
ORCHESTRATE_DEBUG=true claude
```

日志输出到 `.orchestrator/debug.log`。

## 测试

运行测试套件验证核心功能：

```bash
./tests/run-all.sh
```

包含的测试：
- `test-loop-guard.sh` — 四层循环防护机制
- `test-claim-task.sh` — 任务池原子认领
