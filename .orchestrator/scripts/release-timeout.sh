#!/bin/bash
# 释放超时任务
# 用法: ./release-timeout.sh [timeout-seconds]

set -euo pipefail

POOL_FILE=".orchestrator/tasks/task-pool.json"
LOCK_DIR=".orchestrator/tasks/task-pool.lock.d"
TIMEOUT="${1:-300}"

if [ ! -f "$POOL_FILE" ]; then
  exit 0
fi

lock_acquire() {
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do sleep 0.1; done
}
lock_release() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

lock_acquire
trap lock_release EXIT

CURRENT_TIME=$(date +%s)

# 读取所有 claimed 任务
jq -r '.tasks[] | select(.status == "claimed") | "\(.id) \(.claimed_at)"' "$POOL_FILE" | \
while read -r id claimed_at; do
  if [ -n "$claimed_at" ] && [ "$claimed_at" != "null" ]; then
    # macOS 兼容: 使用 date -j
    if command -v gdate &>/dev/null; then
      CLAIMED_EPOCH=$(gdate -d "$claimed_at" +%s 2>/dev/null || echo "0")
    else
      CLAIMED_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$claimed_at" +%s 2>/dev/null || echo "0")
    fi
    ELAPSED=$((CURRENT_TIME - CLAIMED_EPOCH))
    if [ "$ELAPSED" -gt "$TIMEOUT" ]; then
      jq --arg id "$id" \
        '.tasks |= map(
          if .id == $id
          then .status = "pending" | .claimed_by = null | .claimed_at = null
          else . end
        )' "$POOL_FILE" > "$POOL_FILE.tmp"
      mv "$POOL_FILE.tmp" "$POOL_FILE"
      echo "Released timeout task: $id (${ELAPSED}s > ${TIMEOUT}s)"
    fi
  fi
done
