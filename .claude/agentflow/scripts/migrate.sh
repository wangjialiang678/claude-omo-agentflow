#!/bin/bash
# Agentflow directory migration script
# Migrates .orchestrator/ -> .claude/agentflow/ and AGENTS.md -> .claude/agentflow/agents.md
# Usage: migrate.sh [--dry-run] [--rollback]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$PROJECT_ROOT"

DRY_RUN=false
ROLLBACK=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --rollback) ROLLBACK=true ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

log() { echo "[migrate] $*"; }
warn() { echo "[migrate] WARNING: $*" >&2; }
die() { echo "[migrate] ERROR: $*" >&2; exit 1; }

# --- Rollback mode ---
if [ "$ROLLBACK" = true ]; then
  # Find most recent backup
  LATEST_BACKUP=$(ls -dt .orchestrator-migration-backup-* 2>/dev/null | head -n 1 || true)
  if [ -z "$LATEST_BACKUP" ]; then
    die "No backup found for rollback"
  fi

  log "Rolling back from backup: $LATEST_BACKUP"

  if [ "$DRY_RUN" = true ]; then
    log "[DRY RUN] Would restore .orchestrator/ from $LATEST_BACKUP/.orchestrator/"
    log "[DRY RUN] Would restore AGENTS.md from $LATEST_BACKUP/AGENTS.md"
    log "[DRY RUN] Would remove .claude/agentflow/"
    exit 0
  fi

  if [ -d "$LATEST_BACKUP/.orchestrator" ]; then
    rm -rf .orchestrator
    cp -r "$LATEST_BACKUP/.orchestrator" .orchestrator
    log "Restored .orchestrator/"
  fi

  if [ -f "$LATEST_BACKUP/AGENTS.md" ]; then
    cp "$LATEST_BACKUP/AGENTS.md" AGENTS.md
    log "Restored AGENTS.md"
  fi

  log "Rollback complete. New .claude/agentflow/ left in place for safety."
  log "Remove manually if desired: rm -rf .claude/agentflow"
  exit 0
fi

# --- Pre-flight checks ---
log "Running pre-flight checks..."

# Check orchestrator is not actively running a workflow
if [ -f ".orchestrator/state/workflow-state.json" ]; then
  ACTIVE=$(jq -r '.active // false' ".orchestrator/state/workflow-state.json" 2>/dev/null || echo "false")
  if [ "$ACTIVE" = "true" ]; then
    die "Workflow is currently active. Complete or stop it before migrating."
  fi
fi

# Check for running task pool
if [ -f ".orchestrator/tasks/task-pool.json" ]; then
  CLAIMED=$(jq '[.tasks[] | select(.status == "claimed")] | length' ".orchestrator/tasks/task-pool.json" 2>/dev/null || echo "0")
  if [ "$CLAIMED" -gt 0 ]; then
    die "There are $CLAIMED claimed tasks. Complete them before migrating."
  fi
fi

# Check source exists
if [ ! -d ".orchestrator" ]; then
  die ".orchestrator/ directory not found. Nothing to migrate."
fi

log "Pre-flight checks passed."

# --- Dry run mode ---
if [ "$DRY_RUN" = true ]; then
  log "[DRY RUN] Would create backup at .orchestrator-migration-backup-TIMESTAMP/"
  log "[DRY RUN] Would create .claude/agentflow/ directory structure"
  for subdir in workflows state results learnings scripts tasks plans; do
    if [ -d ".orchestrator/$subdir" ]; then
      count=$(find ".orchestrator/$subdir" -type f 2>/dev/null | wc -l | tr -d ' ')
      log "[DRY RUN] Would copy .orchestrator/$subdir/ ($count files)"
    fi
  done
  if [ -f "AGENTS.md" ]; then
    log "[DRY RUN] Would copy AGENTS.md -> .claude/agentflow/agents.md"
  fi
  log "[DRY RUN] Would update workflow YAML path references"
  exit 0
fi

# --- Create backup ---
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=".orchestrator-migration-backup-$TIMESTAMP"
log "Creating backup at $BACKUP_DIR/"

mkdir -p "$BACKUP_DIR"
cp -r .orchestrator "$BACKUP_DIR/.orchestrator"
if [ -f "AGENTS.md" ]; then
  cp AGENTS.md "$BACKUP_DIR/AGENTS.md"
fi
log "Backup created."

# --- Create target directory structure ---
log "Creating .claude/agentflow/ structure..."
mkdir -p .claude/agentflow/{workflows,state,results,learnings,scripts,tasks,plans}

# --- Migrate files (copy, don't delete originals yet) ---

# 1. Static config (low risk)
if [ -d ".orchestrator/workflows" ]; then
  cp -r .orchestrator/workflows/* .claude/agentflow/workflows/ 2>/dev/null || true
  log "Copied workflows/"
fi

if [ -d ".orchestrator/learnings" ]; then
  cp -r .orchestrator/learnings/* .claude/agentflow/learnings/ 2>/dev/null || true
  log "Copied learnings/"
fi

# 2. Scripts (merge with new scripts already in place)
if [ -d ".orchestrator/scripts" ]; then
  for f in .orchestrator/scripts/*; do
    fname=$(basename "$f")
    if [ ! -f ".claude/agentflow/scripts/$fname" ]; then
      cp "$f" .claude/agentflow/scripts/
    fi
  done
  log "Copied scripts/ (merged, preserving new files)"
fi

# 3. Runtime data
if [ -d ".orchestrator/state" ]; then
  # Copy files but not directories that already exist
  find .orchestrator/state -maxdepth 1 -type f -exec cp {} .claude/agentflow/state/ \;
  # Copy snapshots subdirectory
  if [ -d ".orchestrator/state/snapshots" ]; then
    mkdir -p .claude/agentflow/state/snapshots
    cp -r .orchestrator/state/snapshots/* .claude/agentflow/state/snapshots/ 2>/dev/null || true
  fi
  log "Copied state/"
fi

if [ -d ".orchestrator/results" ]; then
  cp -r .orchestrator/results/* .claude/agentflow/results/ 2>/dev/null || true
  log "Copied results/"
fi

if [ -d ".orchestrator/tasks" ] && [ "$(ls -A .orchestrator/tasks 2>/dev/null)" ]; then
  cp -r .orchestrator/tasks/* .claude/agentflow/tasks/ 2>/dev/null || true
  log "Copied tasks/"
fi

if [ -d ".orchestrator/plans" ] && [ "$(ls -A .orchestrator/plans 2>/dev/null)" ]; then
  cp -r .orchestrator/plans/* .claude/agentflow/plans/ 2>/dev/null || true
  log "Copied plans/"
fi

# 4. Agent registry
if [ -f "AGENTS.md" ]; then
  cp AGENTS.md .claude/agentflow/agents.md
  log "Copied AGENTS.md -> agents.md"
fi

# --- Update workflow YAML path references ---
log "Updating workflow YAML path references..."
for yamlfile in .claude/agentflow/workflows/*.yaml; do
  if [ -f "$yamlfile" ]; then
    # macOS sed requires '' after -i
    sed -i.bak 's|\.orchestrator/|.claude/agentflow/|g' "$yamlfile"
    rm -f "$yamlfile.bak"
  fi
done
log "Workflow YAML references updated."

# --- Summary ---
NEW_COUNT=$(find .claude/agentflow -type f 2>/dev/null | wc -l | tr -d ' ')
log "Migration complete. $NEW_COUNT files in .claude/agentflow/"
log "Old .orchestrator/ preserved (backward compatibility)."
log "Backup at: $BACKUP_DIR/"
log ""
log "Next steps:"
log "  1. Run: bash .claude/agentflow/scripts/verify-migration.sh"
log "  2. Test orchestrator functionality"
log "  3. When ready, remove old structure: rm -rf .orchestrator AGENTS.md"
