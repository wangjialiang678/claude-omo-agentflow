# 实施指南 P2: 代理定义

> **阶段**: P2
> **前置依赖**: P0 (目录结构已创建)
> **关联**: plan-and-spec.md Section 四, claude-omo-agentflow-v2.md Section 五

---

## 概述

本阶段创建 7 个代理 `.md` 文件 + AGENTS.md 注册表 + 更新 CLAUDE.md 编排规则。

代理 prompt 设计借鉴：
- **OMO Metis**: 间隙检测、QA 可执行性
- **OMO Prometheus**: 访谈模式、计划生成
- **OMO 全局**: 防 AI-slop 约束、工具限制

---

## Step 1: 创建 7 个代理文件

以下每个文件创建到 `.claude/agents/` 目录。

完整内容见设计文档 `claude-omo-agentflow-v2.md` 第五章。

### 代理清单

| 文件 | CCR 路由 | 权限 |
|------|---------|------|
| `planner.md` | 无（原生 Opus） | Read-only + AskUserQuestion |
| `backend-coder.md` | Codex | Full write (非前端) |
| `frontend-coder.md` | Gemini Pro | Full write (非后端) |
| `reviewer.md` | Codex | Read-only + 测试执行 |
| `researcher.md` | Gemini Flash | Read-only + Web |
| `explorer.md` | Gemini Flash | Read-only |
| `doc-writer.md` | Gemini Flash | 仅写 .md |

### 代理 Prompt 设计原则

1. **角色清晰**: 每个代理有明确的身份和边界
2. **权限最小化**: 只读代理不能写文件，后端代理不能改前端
3. **输出规范**: 所有代理输出结构化结果到 `.orchestrator/results/`
4. **QA 可执行**: 验收标准必须是命令可验证的（借鉴 OMO Metis）
5. **防 AI-slop**: 不做超出任务范围的事（借鉴 OMO）

---

## Step 2: 创建 AGENTS.md

在项目根目录创建 `AGENTS.md`：

```markdown
# Agent Registry

## Overview

This project uses a heterogeneous multi-agent orchestration system.
Each agent has a specific role, model route, and permission scope.

## Agents

| Agent | Role | Model | Tools | Scope |
|-------|------|-------|-------|-------|
| planner | 需求分析与实施规划 | Claude Opus (native) | Read, Glob, Grep, AskUserQuestion | Read-only |
| backend-coder | 后端代码实现 | Codex (via CCR) | Read, Write, Edit, Bash, Glob, Grep | Server-side files only |
| frontend-coder | 前端 UI/UX 实现 | Gemini Pro (via CCR) | Read, Write, Edit, Bash, Glob, Grep | Client-side files only |
| reviewer | 代码审核与质量保证 | Codex (via CCR) | Read, Glob, Grep, Bash | Read-only + test run |
| researcher | 技术调研与最佳实践 | Gemini Flash (via CCR) | Read, Glob, Grep, WebSearch, WebFetch | Read-only |
| explorer | 快速代码搜索 | Gemini Flash (via CCR) | Read, Glob, Grep | Read-only |
| doc-writer | 文档撰写 | Gemini Flash (via CCR) | Read, Write, Glob, Grep | .md files only |

## Delegation Rules

- **Backend code changes** → backend-coder
- **Frontend/UI changes** → frontend-coder
- **Code review requests** → reviewer
- **Technical research** → researcher
- **Quick file search** → explorer
- **Documentation** → doc-writer
- **Planning/requirements** → planner
- **Core orchestration** → main agent (no delegation)

## Output Convention

All agents write results to `.orchestrator/results/{task-id}.json` or `.md`.
Task status updates go to `.orchestrator/tasks/task-pool.json`.
```

---

## Step 3: 更新 CLAUDE.md

在项目 CLAUDE.md 中添加以下编排规则：

```markdown
## 多代理编排规则

### 代理委派策略

当需要执行以下类型的任务时，使用对应的子代理：

| 任务类型 | 委派给 | 说明 |
|---------|--------|------|
| 后端代码实现 | backend-coder | Codex 模型，严格后端权限 |
| 前端 UI/UX 实现 | frontend-coder | Gemini Pro，创意 UI |
| 代码审核/Review | reviewer | Codex 模型，只读+测试 |
| 技术调研 | researcher | Gemini Flash，大上下文 |
| 代码搜索/文件查找 | explorer | Gemini Flash，极速只读 |
| 文档撰写 | doc-writer | Gemini Flash |
| 需求规划 | planner | Claude Opus 原生 |
| 核心代码（不路由） | 自行处理 | Claude Opus 原生订阅 |

### 自动继续规则

- 当有活跃的工作流（pipeline/autopilot/swarm）时，Stop Hook 会阻止主代理停止
- 当任务池中有未完成的任务时，继续处理
- 当计划文档中有未勾选的 TODO 时，继续执行
- 紧急退出：创建 `/tmp/FORCE_STOP` 文件

### 结果输出规范

所有子代理的输出写入 `.orchestrator/results/` 目录：
- 代码相关: `{task-id}.json` (含 verdict, issues, tests_passed)
- 调研相关: `{task-id}.md` (Markdown 报告)
- 搜索相关: `{task-id}.json` (文件列表和代码片段)
```

---

## Step 4: 验收测试

```bash
echo "=== P2 Tests ==="

# 所有代理文件存在
for agent in planner backend-coder frontend-coder reviewer researcher explorer doc-writer; do
  test -f ".claude/agents/$agent.md" && echo "PASS: $agent.md exists" || echo "FAIL: $agent.md missing"
done

# YAML frontmatter 格式正确
for agent in .claude/agents/*.md; do
  head -1 "$agent" | grep -q "^---$" && echo "PASS: $(basename $agent) frontmatter" || echo "FAIL: $(basename $agent) frontmatter"
done

# CCR 标签存在（排除 planner）
for agent in backend-coder frontend-coder reviewer researcher explorer doc-writer; do
  grep -q "CCR-SUBAGENT-MODEL" ".claude/agents/$agent.md" && echo "PASS: $agent has CCR tag" || echo "FAIL: $agent missing CCR tag"
done

# planner 无 CCR 标签
grep -q "CCR-SUBAGENT-MODEL" ".claude/agents/planner.md" && echo "FAIL: planner should not have CCR tag" || echo "PASS: planner has no CCR tag"

# AGENTS.md 存在
test -f AGENTS.md && echo "PASS: AGENTS.md exists" || echo "FAIL: AGENTS.md missing"

# CLAUDE.md 包含编排规则
grep -q "代理委派策略" CLAUDE.md && echo "PASS: delegation rules in CLAUDE.md" || echo "FAIL: missing delegation rules"

echo "=== Done ==="
```
