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
