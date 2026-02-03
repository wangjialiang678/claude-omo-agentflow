# 设计决策记录

## 2026-02-04: 调试模式设计

### 背景
代码中大量使用 `2>/dev/null` 来避免错误输出干扰 JSON 解析，但这导致调试困难。

### 决策
添加 `ORCHESTRATE_DEBUG` 环境变量：
- `false`（默认）: 保持现有行为，不输出调试信息
- `true`: 将 stderr 重定向到日志文件，并启用 `set -x`

### 理由
- 不影响正常使用
- 需要调试时可以快速启用
- 日志持久化便于事后分析

### 使用方式
```bash
ORCHESTRATE_DEBUG=true claude
```

日志位置: `.orchestrator/debug.log`
