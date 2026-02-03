#!/bin/bash
# 运行所有测试
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================"
echo "  claude-omo-agentflow Test Suite"
echo "========================================"
echo ""

TOTAL_PASS=0
TOTAL_FAIL=0

for test_script in "$SCRIPT_DIR"/test-*.sh; do
  if [ -f "$test_script" ]; then
    echo "Running: $(basename "$test_script")"
    echo "----------------------------------------"
    if "$test_script"; then
      echo ""
    else
      TOTAL_FAIL=$((TOTAL_FAIL + 1))
      echo ""
    fi
  fi
done

echo "========================================"
if [ "$TOTAL_FAIL" -eq 0 ]; then
  echo "All tests passed! ✅"
  exit 0
else
  echo "Some tests failed! ❌"
  exit 1
fi
