#!/bin/bash
# 共享文件锁库 - 带 PID 验证的 mkdir 锁
# 用法: source lib/file-lock.sh
#       LOCK_DIR="/path/to/lock.d"
#       lock_acquire && trap lock_release EXIT

lock_acquire() {
  local waited=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
    if [ "$waited" -gt 300 ]; then
      # 检查持有锁的进程是否仍然存活
      local lock_pid_file="$LOCK_DIR/pid"
      if [ -f "$lock_pid_file" ]; then
        local lock_pid
        lock_pid=$(cat "$lock_pid_file" 2>/dev/null || echo "")
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
          echo "Lock held by active process $lock_pid, waiting..." >&2
          waited=250  # 再等 5 秒
          continue
        fi
        echo "Lock held by dead process $lock_pid, breaking stale lock" >&2
      else
        echo "Lock timeout with no PID file, breaking stale lock" >&2
      fi
      rm -rf "$LOCK_DIR"
      if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "Failed to acquire lock after breaking stale lock" >&2
        return 1
      fi
      break
    fi
  done
  # 写入当前进程 PID
  echo $$ > "$LOCK_DIR/pid" 2>/dev/null || true
}

lock_release() {
  rm -rf "$LOCK_DIR" 2>/dev/null || true
}
