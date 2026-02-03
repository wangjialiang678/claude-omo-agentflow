# 经验教训

## 2026-02-04: 代码审查反馈

### 发现的问题

1. **planner 代理权限不足**
   - 问题: planner 需要输出计划到文件，但没有 Write 权限
   - 解决: 添加 Write 到 tools 列表

2. **调试困难**
   - 问题: 大量 `2>/dev/null` 吞掉错误，出问题时无法定位
   - 解决: 添加 ORCHESTRATE_DEBUG 环境变量，启用后输出详细日志

3. **缺少测试**
   - 问题: 没有自动化测试，无法验证核心逻辑
   - 解决: 添加 tests/ 目录，包含 loop-guard 和 claim-task 测试

### 最佳实践

- 使用 `ORCHESTRATE_DEBUG=true` 启用调试模式
- 运行 `./tests/run-all.sh` 验证核心功能
- 使用 `shellcheck` 检查 Shell 脚本质量
