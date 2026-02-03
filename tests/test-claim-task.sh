#!/bin/bash
# 测试任务池原子认领机制
# 注意: 使用临时目录，不会影响真实的任务池数据
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 使用临时目录而不是真实的项目目录，避免数据丢失
TEST_DIR="/tmp/claude-omo-agentflow-test-$$"

PASS=0
FAIL=0

log_pass() { echo "✅ PASS: $1"; PASS=$((PASS + 1)); }
log_fail() { echo "❌ FAIL: $1"; FAIL=$((FAIL + 1)); }

# 准备测试环境 - 使用临时目录
setup() {
  mkdir -p "$TEST_DIR/.orchestrator/tasks"
  mkdir -p "$TEST_DIR/.orchestrator/scripts"
  
  # 复制脚本到临时目录
  cp "$PROJECT_DIR/.orchestrator/scripts/claim-task.sh" "$TEST_DIR/.orchestrator/scripts/"
  
  # 创建测试数据
  cat > "$TEST_DIR/.orchestrator/tasks/task-pool.json" << 'POOL'
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
  rm -rf "$TEST_DIR"
}

# 测试 1: 基本认领
test_basic_claim() {
  echo "--- test_basic_claim ---"
  
  cd "$TEST_DIR"
  result=$("$TEST_DIR/.orchestrator/scripts/claim-task.sh" worker-1 2>/dev/null) || true
  
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
  
  cd "$TEST_DIR"
  result=$("$TEST_DIR/.orchestrator/scripts/claim-task.sh" worker-2 frontend-coder 2>/dev/null) || true
  
  if echo "$result" | grep -q '"agent".*:.*"frontend-coder"'; then
    log_pass "correct agent task claimed"
  else
    log_fail "wrong agent task claimed: $result"
  fi
}

# 测试 3: 无任务时返回错误
test_no_tasks() {
  echo "--- test_no_tasks ---"
  
  cd "$TEST_DIR"
  # 认领剩余任务
  "$TEST_DIR/.orchestrator/scripts/claim-task.sh" worker-3 2>/dev/null || true
  
  # 尝试认领不存在的代理类型
  if "$TEST_DIR/.orchestrator/scripts/claim-task.sh" worker-4 nonexistent-agent 2>/dev/null; then
    log_fail "should fail with no matching tasks"
  else
    log_pass "correctly failed with no matching tasks"
  fi
}

# 运行测试
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
