#!/bin/bash
# 测试任务池原子认领机制
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0

log_pass() { echo "✅ PASS: $1"; PASS=$((PASS + 1)); }
log_fail() { echo "❌ FAIL: $1"; FAIL=$((FAIL + 1)); }

# 准备测试环境
setup() {
  mkdir -p "$PROJECT_DIR/.orchestrator/tasks"
  rm -rf "$PROJECT_DIR/.orchestrator/tasks/task-pool.lock.d"
  cat > "$PROJECT_DIR/.orchestrator/tasks/task-pool.json" << 'POOL'
{
  "tasks": [
    {"id": "t1", "status": "pending", "agent": "backend-coder", "description": "Test task 1"},
    {"id": "t2", "status": "pending", "agent": "frontend-coder", "description": "Test task 2"},
    {"id": "t3", "status": "pending", "agent": "backend-coder", "description": "Test task 3"}
  ]
}
POOL
}

teardown() {
  rm -rf "$PROJECT_DIR/.orchestrator/tasks"
}

# 测试 1: 基本认领
test_basic_claim() {
  echo "--- test_basic_claim ---"
  
  result=$("$PROJECT_DIR/.orchestrator/scripts/claim-task.sh" worker-1 2>/dev/null) || true
  
  # jq 输出可能有空格，用 grep -q 检查
  if echo "$result" | grep -q '"status".*:.*"claimed"'; then
    log_pass "task claimed successfully"
  else
    log_fail "task not claimed: $result"
    return
  fi
  
  if echo "$result" | grep -q '"claimed_by".*:.*"worker-1"'; then
    log_pass "worker id recorded"
  else
    log_fail "worker id not recorded"
  fi
}

# 测试 2: 按代理过滤认领
test_agent_filter() {
  echo "--- test_agent_filter ---"
  
  result=$("$PROJECT_DIR/.orchestrator/scripts/claim-task.sh" worker-2 frontend-coder 2>/dev/null) || true
  
  if echo "$result" | grep -q '"agent".*:.*"frontend-coder"'; then
    log_pass "correct agent task claimed"
  else
    log_fail "wrong agent task claimed: $result"
  fi
}

# 测试 3: 无任务时返回错误
test_no_tasks() {
  echo "--- test_no_tasks ---"
  
  # 认领剩余任务
  "$PROJECT_DIR/.orchestrator/scripts/claim-task.sh" worker-3 2>/dev/null || true
  
  # 尝试认领不存在的代理类型
  if "$PROJECT_DIR/.orchestrator/scripts/claim-task.sh" worker-4 nonexistent-agent 2>/dev/null; then
    log_fail "should fail with no matching tasks"
  else
    log_pass "correctly failed with no matching tasks"
  fi
}

# 运行测试
cd "$PROJECT_DIR"
setup
trap teardown EXIT

test_basic_claim
test_agent_filter
test_no_tasks

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

[ "$FAIL" -eq 0 ] || exit 1
