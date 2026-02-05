#!/bin/bash
# Path resolver for agentflow directory migration
# Provides backward-compatible path resolution: new path preferred, old path fallback.

# Find project root (where .claude/ lives)
_find_project_root() {
  local dir="${AGENTFLOW_PROJECT_ROOT:-}"
  if [ -n "$dir" ]; then
    echo "$dir"
    return
  fi
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  echo "$dir"
}

AGENTFLOW_ROOT="$(_find_project_root)"

# resolve_path <resource>
#   resource: one of state, results, tasks, plans, workflows, learnings, scripts
#   Returns the absolute path to the resource directory.
#   Prefers .claude/agentflow/<resource>, falls back to .orchestrator/<resource>.
resolve_path() {
  local resource="$1"
  local new_path="$AGENTFLOW_ROOT/.claude/agentflow/$resource"
  local old_path="$AGENTFLOW_ROOT/.orchestrator/$resource"

  if [ -d "$new_path" ]; then
    echo "$new_path"
  elif [ -d "$old_path" ]; then
    echo "$old_path"
  else
    echo "$new_path"
  fi
}

# resolve_file <relative-path>
#   e.g. resolve_file "state/mode.txt"
#   Returns the absolute path to the file.
#   Prefers .claude/agentflow/<path>, falls back to .orchestrator/<path>.
resolve_file() {
  local relpath="$1"
  local new_path="$AGENTFLOW_ROOT/.claude/agentflow/$relpath"
  local old_path="$AGENTFLOW_ROOT/.orchestrator/$relpath"

  if [ -f "$new_path" ]; then
    echo "$new_path"
  elif [ -f "$old_path" ]; then
    echo "$old_path"
  else
    echo "$new_path"
  fi
}

# resolve_agents_file
#   Returns path to agents registry (agents.md or AGENTS.md)
resolve_agents_file() {
  local new_path="$AGENTFLOW_ROOT/.claude/agentflow/agents.md"
  local old_path="$AGENTFLOW_ROOT/AGENTS.md"

  if [ -f "$new_path" ]; then
    echo "$new_path"
  elif [ -f "$old_path" ]; then
    echo "$old_path"
  else
    echo "$new_path"
  fi
}
