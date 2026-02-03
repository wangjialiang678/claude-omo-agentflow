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

# 带超时的锁（共享函数）
lock_acquire() {
  local waited=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    if [ "$waited" -gt 300 ]; then
      echo "Lock timeout, breaking stale lock" >&2
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR" 2>/dev/null || true
      return
    fi
  done
}
lock_release() {
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

lock_acquire
trap lock_release EXIT

CURRENT_TIME=$(date +%s)

# 先收集所有超时任务 ID，避免管道内修改文件的覆盖问题
TIMEOUT_IDS=""
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
      TIMEOUT_IDS="$TIMEOUT_IDS $id"
      echo "Released timeout task: $id (${ELAPSED}s > ${TIMEOUT}s)"
    fi
  fi
done < <(jq -r '.tasks[] | select(.status == "claimed") | "\(.id) \(.claimed_at)"' "$POOL_FILE")

# 逐个释放超时任务（每次从最新文件读取）
for id in $TIMEOUT_IDS; do
  jq --arg id "$id" \
    '.tasks |= map(
      if .id == $id
      then .status = "pending" | .claimed_by = null | .claimed_at = null
      else . end
    )' "$POOL_FILE" > "$POOL_FILE.tmp"
  mv "$POOL_FILE.tmp" "$POOL_FILE"
done
