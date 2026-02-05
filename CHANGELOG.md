# Changelog

All notable changes to this project will be documented in this file.

## [v1.0.3] - 2026-02-05

### Added
- **跨 IDE 兼容性矩阵** — 深入调研 5 个 AI IDE（Claude Code、Cursor、Antigravity、Trae、OpenCode）的 Skills/Hooks/Sub-agents 支持情况
  - 调研报告：`.claude/agentflow/results/`（4 份深度报告）
  - 汇总矩阵：`.orchestrator/results/ai-ide-compatibility-matrix-corrected.md`
- **跨 IDE 部署脚本** — `.claude/agentflow/scripts/deploy-cross-ide.sh`，一键部署到 Cursor/Antigravity/Trae/OpenCode
  - Cursor：自动转换 Hooks（settings.json → hooks.json）
  - 其他 IDE：仅部署 Skills（功能降级）
  - 支持 `--dry-run` 和 `--force` 参数
- **AI-DEPLOY.md v1.2.0** — 完全自包含的 AI 自动部署文档
  - 新增 `git clone` 步骤，AI 可从零开始部署
  - 明确区分 `$SOURCE_REPO`（源码）和 `$TARGET_PROJECT`（目标项目）
  - 新增跨 IDE 兼容性速查表
  - 新增 AI 行为指令（主动询问用户是否部署）
  - 新增 Cursor hooks 事件映射表和功能降级说明
- **README.md** — 新增"AI 自动部署"章节

### Removed
- 从兼容性矩阵中移除 GitHub Copilot 和 Crush（不在目标范围内）

---

## [v1.0.2] - 2026-02-05

### Fixed (based on code review)
- **create-pool.sh**: skip empty lines, comment lines, and malformed lines (no colon separator or empty agent/description)
- **Lock mechanism**: extracted shared lock library (`lib/file-lock.sh`) with PID verification — stale locks now check if the holding process is alive before breaking
- **stop.sh**: improved warning visibility when lib files are missing (guards disabled)

### Added
- `.githooks/pre-commit`: blocks accidental commits of sensitive runtime paths (`.claude/memory-bank/`, `.orchestrator/state/`, etc.)
- `.orchestrator/scripts/lib/file-lock.sh`: shared file lock library with PID-based stale lock detection

### Changed
- `claim-task.sh`, `complete-task.sh`, `release-timeout.sh`: replaced inline lock functions with shared `lib/file-lock.sh`

---

## [v1.0.1] - 2026-02-04

### Changed
- 迁移掌天瓶文件结构到 `.claude/agentflow/`
  - `AGENTS.md` → `.claude/agentflow/agents.md`
  - `.orchestrator/` → `.claude/agentflow/`
  - 新路径优先级更高，支持双路径共存（完全向后兼容）

- 更新所有文档引用：
  - CLAUDE.md：掌天瓶配置指向新路径
  - .claude/skills/orchestrate/SKILL.md：所有路径已更新
  - 7 个代理定义文件：输出路径指向新位置
  - README.md：文件结构图、快速开始、执行模式说明已更新
  - INSTALL.md：所有目录创建命令、文件清单、验收测试已更新

### Migration
向后兼容支持：通过路径解析器自动回退到旧路径（过渡期），无需立即迁移。

运行迁移脚本：
```bash
bash .claude/agentflow/scripts/migrate.sh
```

回滚（如需）：
```bash
bash .claude/agentflow/scripts/migrate.sh --rollback
```

### Rationale
- 避免项目根目录污染（`.orchestrator/` 和 `AGENTS.md` 占据顶级命名空间）
- 符合 `.claude/` 统一配置目录规范
- 支持跨项目部署，每个项目独立命名空间
- 完全向后兼容，旧路径仍可正常使用（预计 2-4 周后可选择性清理）

---

## [v1.0.0] - Initial Release

### Added
- **3 执行模式**：Pipeline（流水线）、Swarm（并行）、Autopilot（自主）
- **7 专业代理**：planner、backend-coder、frontend-coder、reviewer、researcher、explorer、doc-writer
- **自动继续机制**：Stop Hook 检测未完成工作，自动阻止停止
- **四层安全防护**：stop_hook_active 标志 → 强制停止文件 → 重试计数 → 超时退出
- **异构模型路由**：通过 CCR 支持 Codex、Gemini、Claude 混用
- **轻量级部署**：仅依赖 jq，无 Node.js/Plugin 依赖
