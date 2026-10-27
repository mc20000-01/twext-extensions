#!/usr/bin/env bash
set -euo pipefail

EXTENSIONS_REPO="https://github.com/mc20000-01/extensions.git"
BACKUP_REPO="/home/sandisk/Projects/tbu/twext-extensions"
SOURCE_DIR="/tmp/extensions-source"
TIMEOUT_FILE="/home/sandisk/Projects/tbu/.twext-backup-timeout"

MINUTES_INTERVAL=240

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

main() {
  cd "$BACKUP_REPO"

  # Check interval based on timeout file
  local should_run=1

  if [ -f "$TIMEOUT_FILE" ]; then
    local last_run
    last_run=$(cat "$TIMEOUT_FILE")
    local now
    now=$(date +%s)
    local elapsed=$((now - last_run))
    local elapsed_minutes=$((elapsed / 60))

    if [ "$elapsed_minutes" -lt "$MINUTES_INTERVAL" ] && [ "$elapsed_minutes" -gt 0 ]; then
      log "Last run was $elapsed_minutes minutes ago (need $MINUTES_INTERVAL minutes interval)"
      should_run=0
    fi
  fi

  if [ "$should_run" -eq 1 ]; then
    # Update timeout
    date +%s > "$TIMEOUT_FILE"

    log "Running backup cycle..."

    # Clone or update the source extensions repo
    if [ -d "$SOURCE_DIR" ]; then
      git -C "$SOURCE_DIR" fetch origin 2>/dev/null || true
      git -C "$SOURCE_DIR" checkout main 2>/dev/null || true
      git -C "$SOURCE_DIR" pull --depth 1 2>/dev/null || true
    fi

    if [ ! -d "$SOURCE_DIR" ]; then
      git clone --depth 1 "$EXTENSIONS_REPO" "$SOURCE_DIR" 2>/dev/null || {
        log "Failed to clone extensions repo"
        return 1
      }
    fi

    # Prepare backup repo staging area
    mkdir -p "$BACKUP_REPO/tmp_backup"

    # Copy all extension folders (directories with twext.yml) from source
    local copied=0
    for ext_dir in "$SOURCE_DIR"/*/; do
      [ -d "$ext_dir" ] || continue
      local ext_name
      ext_name=$(basename "$ext_dir")

      # Check if this folder has a twext.yml (valid twext extension)
      if [ -f "$ext_dir/twext.yml" ]; then
        # Copy all files from this extension folder
        cp -r "$ext_dir"/* "$BACKUP_REPO/tmp_backup/" 2>/dev/null || true
        copied=$((copied + 1))
      fi
    done

    log "Copied $copied extension folders"

    # If we have content, commit and push to backup repo
    if [ -d "$BACKUP_REPO/tmp_backup" ] && [ "$(ls -A "$BACKUP_REPO/tmp_backup" 2>/dev/null | wc -l)" -gt 0 ]; then
      # Move staged content to a permanent extensions dir
      rm -rf "$BACKUP_REPO/extensions"
      mv "$BACKUP_REPO/tmp_backup" "$BACKUP_REPO/extensions"

      cd "$BACKUP_REPO"

      # Check if there are actual changes
      if git diff --quiet 2>/dev/null; then
        log "No changes detected in extensions after copy"
        # Still keep the extensions dir, just reset timeout
        return 0
      fi

      git add -A
      if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "Backup Twext extensions - $(date '+%Y-%m-%d %H:%M:%S')"
        git push origin main 2>/dev/null || git push origin master 2>/dev/null || log "Push attempted"
        log "Backup committed and pushed ($copied extensions)"
      else
        log "No staged changes after git add"
      fi
    else
      log "No extension data to backup"
    fi
  else
    log "Skipping backup run (interval not reached)"
  fi
}

main "$@"