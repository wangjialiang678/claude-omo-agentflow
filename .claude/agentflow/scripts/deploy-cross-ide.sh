#!/bin/bash
# deploy-cross-ide.sh - 跨 IDE 部署掌天瓶 Skills/Agents/Hooks
# 用法: bash .claude/agentflow/scripts/deploy-cross-ide.sh <ide>
# 支持: cursor, antigravity, trae, opencode

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }

usage() {
    cat <<'EOF'
掌天瓶跨 IDE 部署脚本

用法:
  bash .claude/agentflow/scripts/deploy-cross-ide.sh <ide>

支持的 IDE:
  cursor       - 部署 Skills + Agents + Hooks（95% 兼容）
  antigravity  - 仅部署 Skills（40% 兼容）
  trae         - 仅部署 Skills（40% 兼容）
  opencode     - 仅部署 Skills（50% 兼容）

选项:
  --help       - 显示帮助
  --dry-run    - 仅显示操作，不执行
  --force      - 覆盖已存在的文件

示例:
  bash .claude/agentflow/scripts/deploy-cross-ide.sh cursor
  bash .claude/agentflow/scripts/deploy-cross-ide.sh --dry-run antigravity
EOF
}

# 检查源文件是否存在
check_source() {
    if [ ! -d "$PROJECT_ROOT/.claude/skills" ]; then
        error "源目录 .claude/skills/ 不存在，请先完成 Claude Code 部署"
        exit 1
    fi
}

# 复制 Skills
deploy_skills() {
    local target_dir="$1"
    local full_path="$PROJECT_ROOT/$target_dir"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] mkdir -p $full_path"
        echo "  [DRY-RUN] cp -r .claude/skills/* $target_dir/"
        return
    fi

    mkdir -p "$full_path"

    if [ -d "$PROJECT_ROOT/.claude/skills" ]; then
        cp -r "$PROJECT_ROOT/.claude/skills/"* "$full_path/" 2>/dev/null || true
        info "Skills 已部署到 $target_dir/"
    else
        warn "无 Skills 可部署"
    fi
}

# 复制 Agents
deploy_agents() {
    local target_dir="$1"
    local full_path="$PROJECT_ROOT/$target_dir"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] mkdir -p $full_path"
        echo "  [DRY-RUN] cp -r .claude/agents/* $target_dir/"
        return
    fi

    mkdir -p "$full_path"

    if [ -d "$PROJECT_ROOT/.claude/agents" ]; then
        cp -r "$PROJECT_ROOT/.claude/agents/"* "$full_path/" 2>/dev/null || true
        info "Agents 已部署到 $target_dir/"
    else
        warn "无 Agents 可部署"
    fi
}

# 转换 Hooks: Claude Code settings.json → Cursor hooks.json
convert_hooks_to_cursor() {
    local target_file="$PROJECT_ROOT/.cursor/hooks.json"
    local source_file="$PROJECT_ROOT/.claude/settings.json"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] 转换 .claude/settings.json hooks → .cursor/hooks.json"
        return
    fi

    if [ ! -f "$source_file" ]; then
        warn "未找到 .claude/settings.json，跳过 hooks 转换"
        return
    fi

    # 检查 jq
    if ! command -v jq &>/dev/null; then
        warn "未安装 jq，无法自动转换 hooks。请手动创建 .cursor/hooks.json"
        return
    fi

    # 检查是否有 hooks 配置
    local has_hooks
    has_hooks=$(jq -r 'has("hooks")' "$source_file" 2>/dev/null || echo "false")

    if [ "$has_hooks" != "true" ]; then
        warn "settings.json 中无 hooks 配置，跳过"
        return
    fi

    # 提取 hook commands 并转换格式
    # Claude Code: { "hooks": { "PreToolUse": [{ "hooks": [{ "command": "..." }] }] } }
    # Cursor:      { "version": 1, "hooks": { "beforeShellExecution": [{ "command": "..." }] } }

    local cursor_hooks='{"version":1,"hooks":{}}'

    # 提取所有 hook commands
    local stop_hooks
    stop_hooks=$(jq -r '.hooks.Stop // [] | .[] | .hooks // [] | .[] | .command // empty' "$source_file" 2>/dev/null)

    local pre_tool_hooks
    pre_tool_hooks=$(jq -r '.hooks.PreToolUse // [] | .[] | .hooks // [] | .[] | .command // empty' "$source_file" 2>/dev/null)

    local post_tool_hooks
    post_tool_hooks=$(jq -r '.hooks.PostToolUse // [] | .[] | .hooks // [] | .[] | .command // empty' "$source_file" 2>/dev/null)

    # 构建 Cursor hooks.json
    local result='{"version":1,"hooks":{}}'

    if [ -n "$stop_hooks" ]; then
        while IFS= read -r cmd; do
            result=$(echo "$result" | jq --arg cmd "$cmd" '.hooks.onSessionEnd += [{"command": $cmd}]')
        done <<< "$stop_hooks"
    fi

    if [ -n "$pre_tool_hooks" ]; then
        while IFS= read -r cmd; do
            result=$(echo "$result" | jq --arg cmd "$cmd" '.hooks.beforeShellExecution += [{"command": $cmd}]')
        done <<< "$pre_tool_hooks"
    fi

    if [ -n "$post_tool_hooks" ]; then
        while IFS= read -r cmd; do
            result=$(echo "$result" | jq --arg cmd "$cmd" '.hooks.afterShellExecution += [{"command": $cmd}]')
        done <<< "$post_tool_hooks"
    fi

    mkdir -p "$PROJECT_ROOT/.cursor"
    echo "$result" | jq '.' > "$target_file"
    info "Hooks 已转换到 .cursor/hooks.json"
    warn "请手动验证事件映射是否正确（Claude Code 和 Cursor 的事件模型不完全相同）"
}

# 部署到 Cursor
deploy_cursor() {
    echo ""
    echo "=== 部署到 Cursor (95% 兼容) ==="
    echo ""

    deploy_skills ".cursor/skills"
    deploy_agents ".cursor/agents"
    convert_hooks_to_cursor

    echo ""
    info "Cursor 部署完成"
    warn "掌天瓶 Pipeline/Swarm 模式需要在 Cursor 中手动适配"
    echo ""
    echo "验证命令："
    echo "  ls .cursor/skills/*/SKILL.md"
    echo "  ls .cursor/agents/*.md"
    echo "  cat .cursor/hooks.json"
}

# 部署到 Antigravity（仅 Skills）
deploy_antigravity() {
    echo ""
    echo "=== 部署到 Antigravity (仅 Skills, 40% 兼容) ==="
    echo ""

    deploy_skills ".agent/skills"

    echo ""
    info "Antigravity Skills 部署完成"
    warn "Hooks 和 Sub-agents 不可用（Antigravity 不支持）"
    warn "掌天瓶编排功能不可用，降级为单代理模式"
    echo ""
    echo "验证命令："
    echo "  ls .agent/skills/*/SKILL.md"
}

# 部署到 Trae（仅 Skills）
deploy_trae() {
    echo ""
    echo "=== 部署到 Trae (仅 Skills, 40% 兼容) ==="
    echo ""

    deploy_skills ".trae/skills"

    echo ""
    info "Trae Skills 部署完成"
    warn "Hooks 不可用（Trae 使用 .rules 替代）"
    warn "Sub-agents 需通过 Trae UI 手动配置"
    warn "掌天瓶编排功能不可用，降级为单代理模式"
    echo ""
    echo "验证命令："
    echo "  ls .trae/skills/*/SKILL.md"
}

# 部署到 OpenCode（仅 Skills）
deploy_opencode() {
    echo ""
    echo "=== 部署到 OpenCode (仅 Skills, 50% 兼容) ==="
    echo ""

    deploy_skills ".opencode/skills"

    echo ""
    info "OpenCode Skills 部署完成"
    warn "OpenCode 已于 2025-09-18 归档，建议迁移到 Claude Code"
    warn "Hooks 仅实验性支持，Sub-agents 需 JSON 格式"
    echo ""
    echo "验证命令："
    echo "  ls .opencode/skills/*/SKILL.md"
}

# 主逻辑
DRY_RUN=false
FORCE=false
TARGET_IDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            usage
            exit 0
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        cursor|antigravity|trae|opencode)
            TARGET_IDE="$1"
            shift
            ;;
        *)
            error "未知参数: $1"
            usage
            exit 1
            ;;
    esac
done

if [ -z "$TARGET_IDE" ]; then
    error "请指定目标 IDE"
    usage
    exit 1
fi

check_source

case "$TARGET_IDE" in
    cursor)
        deploy_cursor
        ;;
    antigravity)
        deploy_antigravity
        ;;
    trae)
        deploy_trae
        ;;
    opencode)
        deploy_opencode
        ;;
esac
