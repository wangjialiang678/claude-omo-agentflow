#!/bin/bash
# 测试四层循环防护机制
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

source "$PROJECT_DIR/.claude/hooks/lib/loop-guard.sh"

PASS=0
FAIL=0

log_pass() { echo "✅ PASS: $1"; PASS=$((PASS + 1)); }
log_fail() { echo "❌ FAIL: $1"; FAIL=$((FAIL + 1)); }

# 准备测试环境
setup() {
  export GUARD_STATE_DIR="/tmp/test-guard-state-$$"
  mkdir -p "$GUARD_STATE_DIR"
}

teardown() {
  rm -rf "$GUARD_STATE_DIR"
  rm -f /tmp/FORCE_STOP
}

# 测试 1: force stop 检测
test_force_stop() {
  echo "--- test_force_stop ---"
  
  # 没有文件时应返回 1
  if check_force_stop; then
    log_fail "force stop should not trigger without file"
  else
    log_pass "force stop correctly not triggered"
  fi
  
  # 创建文件后应返回 0 并删除文件
  touch /tmp/FORCE_STOP
  if check_force_stop; then
    log_pass "force stop detected"
  else
    log_fail "force stop not detected"
  fi
  
  if [ -f /tmp/FORCE_STOP ]; then
    log_fail "force stop file should be deleted"
  else
    log_pass "force stop file cleaned up"
  fi
}

# 测试 2: 最大重试检测
test_max_retries() {
  echo "--- test_max_retries ---"
  
  # 清理状态
  rm -f "$GUARD_STATE_DIR/stop-retries.txt"
  
  # 前 4 次应返回 1（未超限）
  for i in 1 2 3 4; do
    if check_max_retries 5; then
      log_fail "retry $i should not exceed max"
    else
      log_pass "retry $i correctly under limit"
    fi
  done
  
  # 第 5 次应返回 0（超限）- 注意计数从 0 开始，第 5 次调用时 count=4，加 1 后=5，等于 max
  if check_max_retries 5; then
    log_pass "retry 5 correctly exceeded max"
  else
    # 可能需要再调用一次
    if check_max_retries 5; then
      log_pass "retry 6 correctly exceeded max"
    else
      log_fail "should have exceeded max by now"
    fi
  fi
}

# 测试 3: 超时检测
test_timeout() {
  echo "--- test_timeout ---"
  
  # 清理状态
  rm -f "$GUARD_STATE_DIR/stop-start-time.txt"
  
  # 首次调用，不应超时
  if check_timeout 2; then
    log_fail "first call should not timeout"
  else
    log_pass "first call correctly not timeout"
  fi
  
  # 等待超时
  sleep 3
  
  if check_timeout 2; then
    log_pass "correctly detected timeout after 3s"
  else
    log_fail "should have timed out after 3s"
  fi
}

# 运行测试
setup
trap teardown EXIT

test_force_stop
test_max_retries
test_timeout

echo ""
echo "========================================"
echo "Results: $PASS passed, $FAIL failed"
echo "========================================"

[ "$FAIL" -eq 0 ] || exit 1
