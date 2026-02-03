#!/bin/bash
# 子代理完成追踪
set -euo pipefail

# 读取输入（用 read -t 防止 stdin 无数据时阻塞）
INPUT=""
while IFS= read -r -t 5 line; do
  INPUT="${INPUT}${line}"
done
: "${INPUT:='{}'}"
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // "unknown"' 2>/dev/null || echo "unknown")
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "unknown"' 2>/dev/null || echo "unknown")

mkdir -p .orchestrator/results
echo "{\"agent_id\":\"$AGENT_ID\",\"agent_type\":\"$AGENT_TYPE\",\"completed_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
  >> .orchestrator/results/completions.jsonl

exit 0
