#!/usr/bin/env bash
set -euo pipefail

EXTENSIONS_REPO="https://github.com/mc20000-01/extensions.git"
BACKUP_REPO="/home/sandisk/Projects/tbu/twext-extensions"
TWEETS_API="https://twexts.sdisk.us/api/v2"
LOCK_FILE="/home/sandisk/Projects/tbu/.twext-backup.lock"
TIMEOUT_FILE="/home/sandisk/Projects/tbu/.twext-backup-timeout"

MINUTES_INTERVAL=240

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

is_repo_changed() {
  local last_commit
  last_commit=$(git -C "$BACKUP_REPO/logs" show -s --format=%H 2>/dev/null || echo "")
  local current_head
  current_head=$(git rev-parse HEAD 2>/dev/null || echo "")

  if [ -z "$last_commit" ] || [ "$last_commit" != "$current_head" ]; then
    echo "changed"
    return 0
  fi
  echo "unchanged"
  return 1
}

fetch_extensions() {
  log "Fetching latest extensions from twexts hub..."

  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap "rm -rf $tmp_dir" EXIT

  # Fetch the list of extensions from the twexts API
  local api_data
  api_data=$(python3 -c "
import urllib.request, json, sys
try:
    req = urllib.request.Request('$TWEETS_API', headers={'User-Agent': 'Mozilla/5.0'})
    r = urllib.request.urlopen(req, timeout=30)
    print(r.read().decode('utf-8'))
except Exception as e:
    print('error:' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null || echo "error:api_failed")

  if echo "$api_data" | grep -q "^error:"; then
    log "WARNING: Failed to fetch twexts API, using cached data"
    return 1
  fi

  # Parse extensions from the API response
  # The API returns HTML with badge info, extract extension names
  local extensions=()

  # Extract extension names from badge URLs
  while IFS= read -r line; do
    if echo "$line" | grep -q '@[a-zA-Z0-9_-]*/'; then
      local name
      name=$(echo "$line" | grep -oP '@\K[a-zA-Z0-9_.-]+' | head -1)
      if [ -n "$name" ]; then
        extensions+=("$name")
      fi
    fi
  done <<< "$api_data"

  if [ ${#extensions[@]} -eq 0 ]; then
    log "No extensions found in API response"
    return 1
  fi

  log "Found ${#extensions[@]} extensions to backup"

  # For each extension, get the latest version and backup
  for ext_fullname in "${extensions[@]}"; do
    log "Processing extension: $ext_fullname"

    # Get the badge data for this extension
    local badge_data
    badge_data=$(python3 -c "
import urllib.request, sys
try:
    req = urllib.request.Request('$TWEETS_API/badge/$ext_fullname', headers={'User-Agent': 'Mozilla/5.0'})
    r = urllib.request.urlopen(req, timeout=30)
    print(r.read().decode('utf-8'))
except Exception as e:
    print('error:' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null || echo "error:badge_failed")

    if echo "$badge_data" | grep -q "^error:"; then
      log "WARNING: Failed to get badge for $ext_fullname"
      continue
    fi

    # Extract version and download URL from badge HTML
    # The badge format contains version info we need
    local version_url version_name
    version_url=$(echo "$badge_data" | grep -oP 'href="[^"]*"' | head -1 || true)
    version_name=$(echo "$badge_data" | grep -oP '[a-zA-Z0-9_.-]+' | head -3 || true)

    if [ -z "$version_url" ]; then
      log "  No URL found for $ext_fullname, skipping"
      continue
    fi

    # Create extension directory structure
    local ext_dir="$tmp_dir/$(echo "$ext_fullname" | tr '/' '-')"
    mkdir -p "$ext_dir"

    # Copy the relevant extension files based on what we can determine
    # From the extensions repo structure, we know the layout
    log "  Extension $ext_fullname: version=$version_url"
  done

  # Now copy the actual extension folders from the source repo if available
  log "Copying extension definitions from source repo..."

  # Check if we have the source extensions repo locally or clone it
  local source_repo="/tmp/extensions-source"
  if [ ! -d "$source_repo" ]; then
    git clone --depth 1 "$EXTENSIONS_REPO" "$source_repo" 2>/dev/null || {
      log "WARNING: Could not clone extensions repo, using available data"
      return 1
    }
  fi

  # Copy all extension folders to backup
  cp -r "$source_repo"/*/ "$tmp_dir"/ 2>/dev/null || true

  # Remove any hidden files or unwanted files
  find "$tmp_dir" -name "*.git" -type d -exec rm -rf {} + 2>/dev/null || true
  find "$tmp_dir" -name ".gitignore" -type f -delete 2>/dev/null || true

  # Move to backup repo staging area
  mkdir -p "$BACKUP_REPO/new_extensions"
  mv "$tmp_dir"/*/ "$BACKUP_REPO/new_extensions"/ 2>/dev/null || true

  # Clean up empty dirs
  find "$BACKUP_REPO/new_extensions" -type d -empty -delete 2>/dev/null || true

  log "Extensions staged in new_extensions directory"
  return 0
}

commit_backup() {
  local message="$1"
  cd "$BACKUP_REPO"

  # Only commit if there are changes
  if git diff --cached --quiet 2>/dev/null; then
    log "No changes to commit"
    return 0
  fi

  git add -A
  if git diff --cached --quiet; then
    log "No changes after add"
    return 0
  fi

  git commit -m "$message"
  git push origin main 2>/dev/null || git push origin master 2>/dev/null || log "Push attempted"
  log "Backup committed: $message"
}

main() {
  cd "$BACKUP_REPO"

  # Check if we should run based on interval or repo change
  local should_run=1

  # Check timeout file
  if [ -f "$TIMEOUT_FILE" ]; then
    local last_run
    last_run=$(cat "$TIMEOUT_FILE")
    local now
    now=$(date +%s)
    local elapsed=$((now - last_run))
    local elapsed_minutes=$((elapsed / 60))

    if [ "$elapsed_minutes" -lt "$MINUTES_INTERVAL" ]; then
      log "Last run was $elapsed_minutes minutes ago (need $MINUTES_INTERVAL minutes)"
      should_run=0
    fi
  fi

  # Check if repo changed
  local repo_status
  if [ "$should_run" -eq 1 ]; then
    if is_repo_changed; then
      log "Extensions repo has changed, forcing backup"
    else
      log "Extensions repo unchanged, skipping"
      should_run=0
    fi
  fi

  if [ "$should_run" -eq 1 ]; then
    # Update timeout
    date +%s > "$TIMEOUT_FILE"

    # Fetch and backup extensions
    if fetch_extensions; then
      commit_backup "Backup Twext extensions - $(date '+%Y-%m-%d %H:%M:%S')"
    else
      log "Extension backup completed with no new changes"
    fi
  else
    log "Skipping backup run"
  fi
}

main "$@"