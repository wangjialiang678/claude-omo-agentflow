#!/bin/bash
# Verify agentflow migration completeness
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$PROJECT_ROOT"

ERRORS=0
WARNINGS=0

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; ERRORS=$((ERRORS + 1)); }
warn_msg() { echo "  WARN: $*"; WARNINGS=$((WARNINGS + 1)); }

echo "=== Agentflow Migration Verification ==="
echo ""

# 1. Directory structure check
echo "[1] Directory structure"
for dir in workflows state results learnings scripts tasks plans; do
  if [ -d ".claude/agentflow/$dir" ]; then
    pass ".claude/agentflow/$dir/ exists"
  else
    fail ".claude/agentflow/$dir/ missing"
  fi
done
echo ""

# 2. Key files check
echo "[2] Key files"
KEY_FILES=(
  ".claude/agentflow/state/mode.txt"
  ".claude/agentflow/state/workflow-state.json"
  ".claude/agentflow/agents.md"
  ".claude/agentflow/scripts/path-resolver.sh"
  ".claude/agentflow/scripts/migrate.sh"
  ".claude/agentflow/scripts/verify-migration.sh"
)
for f in "${KEY_FILES[@]}"; do
  if [ -f "$f" ]; then
    pass "$f exists"
  else
    fail "$f missing"
  fi
done
echo ""

# 3. Workflow files check
echo "[3] Workflow files"
for yaml in debug.yaml implement.yaml research.yaml review.yaml; do
  f=".claude/agentflow/workflows/$yaml"
  if [ -f "$f" ]; then
    # Check no old path references remain
    if grep -q '\.orchestrator/' "$f" 2>/dev/null; then
      fail "$f still references .orchestrator/"
    else
      pass "$f migrated (no old references)"
    fi
  else
    fail "$f missing"
  fi
done
echo ""

# 4. Task pool scripts check
echo "[4] Task pool scripts"
for script in claim-task.sh complete-task.sh create-pool.sh pool-status.sh release-timeout.sh; do
  f=".claude/agentflow/scripts/$script"
  if [ -f "$f" ]; then
    pass "$f exists"
  else
    fail "$f missing"
  fi
done
echo ""

# 5. Old path reference scan in scripts
echo "[5] Old path references in hook scripts"
HOOK_FILES=(
  ".claude/hooks/stop.sh"
  ".claude/hooks/subagent-stop.sh"
  ".claude/hooks/pre-compact.sh"
  ".claude/hooks/lib/state-manager.sh"
  ".claude/hooks/lib/loop-guard.sh"
)
for f in "${HOOK_FILES[@]}"; do
  if [ -f "$f" ]; then
    # Check for hardcoded .orchestrator/ (but allow path-resolver references)
    OLD_REFS=$(grep -c '\.orchestrator/' "$f" 2>/dev/null || echo "0")
    RESOLVER_REFS=$(grep -c 'path-resolver\|resolve_path\|resolve_file' "$f" 2>/dev/null || echo "0")
    if [ "$OLD_REFS" -gt 0 ] && [ "$RESOLVER_REFS" -eq 0 ]; then
      fail "$f has $OLD_REFS hardcoded .orchestrator/ references without path-resolver"
    elif [ "$OLD_REFS" -gt 0 ]; then
      warn_msg "$f has $OLD_REFS .orchestrator/ refs but uses path-resolver (likely comments)"
    else
      pass "$f clean"
    fi
  fi
done
echo ""

# 6. Script syntax check
echo "[6] Script syntax (bash -n)"
for f in .claude/agentflow/scripts/*.sh .claude/hooks/*.sh .claude/hooks/lib/*.sh; do
  if [ -f "$f" ]; then
    if bash -n "$f" 2>/dev/null; then
      pass "$f syntax OK"
    else
      fail "$f syntax error"
    fi
  fi
done
echo ""

# 7. Summary
echo "=== Summary ==="
echo "  Errors:   $ERRORS"
echo "  Warnings: $WARNINGS"
if [ "$ERRORS" -eq 0 ]; then
  echo "  Result:   PASSED"
  exit 0
else
  echo "  Result:   FAILED"
  exit 1
fi
