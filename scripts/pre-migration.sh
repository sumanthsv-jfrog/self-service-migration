#!/usr/bin/env bash
# Fetches artifact size + count for a repo from source and adds its row
# to the shared tracking file, OR updates specific fields on an
# existing row. Tracking file lives as a plain file in a JFrog generic
# repo (see TRACKING_* in scripts/lib/common.sh).
#
# Usage:
#   track_repo.sh <repo-name> --server <server-id> --source-server <server-id>
#       fetch size/count from source, append a new row as
#       "<repo>,<size_gb>,<count>,pending,pending,false"
#
#   track_repo.sh <repo-name> --server <server-id> --update field=value [field=value ...]
#       patch specific fields on an existing row (source not touched,
#       so --source-server isn't needed here). Recognized field names:
#       config (or config_status), migration (or migration_status),
#       fedmember (or fedmember_added).
#       e.g. track_repo.sh libs-release --server target-server --update config=completed
#            track_repo.sh libs-release --server target-server --update migration=inprogress
#            track_repo.sh libs-release --server target-server --update migration=completed fedmember=true
#
# --server names the server-id (as already configured via `jf c add`)
# that hosts the tracking repo. Required — there is no default.
# --source-server names the server-id to fetch repo size/count from.
# Required in fetch mode only.
#
# Exit codes (the workflow branches on these):
#   0 - proceeded normally (row appended, or fields updated)
#   2 - fetch mode only: repo already migrated (migration_status=completed
#       or fedmember_added=true) — Pipeline A should stop here
#   1 - error
#
# CONCURRENCY WARNING: every mode here does download -> modify -> upload,
# which is a read-modify-write race if two calls (for the same or
# different repos) execute close together — the second upload can
# silently overwrite the first one's change. Put a `concurrency:` group
# on whichever workflow step(s) call this script so tracking-file
# updates serialize. This script does not attempt to solve that itself.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

require_cmd jf
require_cmd jq

REPO_NAME="${1:?usage: track_repo.sh <repo-name> --server <server-id> [--update field=value ...]}"
TRACKING_REPO="cba-self-service"
TRACKING_FILE_PATH="repo-tracking.csv"
shift

TRACKING_SERVER_ID=""
SOURCE_SERVER_ID=""
UPDATE_MODE=false
UPDATE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tracking-server)
      TRACKING_SERVER_ID="${2:?--server requires a value}"
      shift 2
      ;;
    --source-server)
      SOURCE_SERVER_ID="${2:?--source-server requires a value}"
      shift 2
      ;;
    --update)
      shift
      UPDATE_MODE=true
      UPDATE_ARGS=("$@")
      break
      ;;
    *)
      die "unknown argument '$1'"
      ;;
  esac
done

[[ -n "$TRACKING_SERVER_ID" ]] || die "--server <server-id> is required"

LOCAL_TRACKING_FILE="repo_status.csv"

downloadTrackingFile() {
  if jf rt download "${TRACKING_REPO}/${TRACKING_FILE_PATH}" "$LOCAL_TRACKING_FILE" \
       --server-id="$TRACKING_SERVER_ID" --flat=true >/dev/null 2>&1; then
    log "downloaded existing tracking file"
  else
    log "no tracking file found yet — starting a new one"
    echo "$TRACKING_CSV_HEADER" > "$LOCAL_TRACKING_FILE"
  fi
}

uploadTrackingFile() {
  jf rt upload "$LOCAL_TRACKING_FILE" "${TRACKING_REPO}/${TRACKING_FILE_PATH}" \
    --server-id="$TRACKING_SERVER_ID" --flat=true >/dev/null \
    || die "failed to upload tracking file back to ${TRACKING_REPO}"
  log "uploaded tracking file"
}

# Prints the existing row for REPO_NAME, or nothing if the file doesn't
# exist yet (first-time case) or the repo has no row. Guarded
# explicitly rather than assuming downloadTrackingFile always ran first
# — awk on a missing file exits non-zero, which under `set -e` would
# otherwise kill the script silently instead of just returning "no row".
existingRow() {
  [[ -f "$LOCAL_TRACKING_FILE" ]] || return 0
  awk -F',' -v repo="$REPO_NAME" 'NR>1 && $1==repo' "$LOCAL_TRACKING_FILE"
}

# True (exit 0) if the existing row already means "done": completed
# migration, or already a federation member.
isAlreadyMigrated() {
  local row="$1"
  [[ -z "$row" ]] && return 1
  local migration_status fedmember_added
  migration_status=$(echo "$row" | awk -F',' '{print $5}')
  fedmember_added=$(echo "$row" | awk -F',' '{print $6}')
  [[ "$migration_status" == "completed" || "$fedmember_added" == "true" ]]
}

# Fetches size (converted to GB) and file count for REPO_NAME from
# source via the storageinfo API, which — unlike repo-get — actually
# reports usage.
fetchRepoDetails() {
  [[ -n "$SOURCE_SERVER_ID" ]] || die "--source-server <server-id> is required for fetch mode"

  local storageinfo
  storageinfo=$(jf rt curl -XGET api/storageinfo --server-id="$SOURCE_SERVER_ID") \
    || die "failed to fetch storageinfo from source"

  local entry
  entry=$(echo "$storageinfo" | jq -c --arg repo "$REPO_NAME" \
    '.repositoriesSummaryList[] | select(.repoKey == $repo)')

  [[ -n "$entry" ]] || die "repo '${REPO_NAME}' not found in source storageinfo"

  # NOTE: verify against your Artifactory version — storageinfo has
  # reported usedSpace as a human string ("1.2 GB") on some versions
  # and as raw bytes on others. This assumes raw bytes and converts to
  # GB below; if your instance returns a human string instead, parse
  # that directly rather than dividing it as a number.
  local used_space_bytes
  used_space_bytes=$(echo "$entry" | jq -r '.usedSpace // "0"')
  REPO_SIZE_GB=$(awk -v b="$used_space_bytes" 'BEGIN { printf "%.2f", b / 1024 / 1024 / 1024 }')
  REPO_FILE_COUNT=$(echo "$entry" | jq -r '.filesCount // 0')
}

appendRow() {
  echo "${REPO_NAME},${REPO_SIZE_GB},${REPO_FILE_COUNT},pending,pending,false" >> "$LOCAL_TRACKING_FILE"
  log "appended row for '${REPO_NAME}' (size=${REPO_SIZE_GB}GB, count=${REPO_FILE_COUNT})"
}

# Maps a field name (accepting both the short and full spellings) to
# its 1-based CSV column: repo,size,count,config_status,migration_status,fedmember_added
fieldToColumn() {
  case "$1" in
    config|config_status)         echo 4 ;;
    migration|migration_status)   echo 5 ;;
    fedmember|fedmember_added)    echo 6 ;;
    *) die "unknown field '$1' — expected config, migration, or fedmember" ;;
  esac
}

# Sets one column's value for REPO_NAME's row, in place, in the local file.
updateField() {
  local column="$1" value="$2"
  local tmp
  tmp=$(mktemp)
  awk -F',' -v OFS=',' -v repo="$REPO_NAME" -v col="$column" -v val="$value" \
    'NR==1 { print; next } $1==repo { $col=val } { print }' \
    "$LOCAL_TRACKING_FILE" > "$tmp"
  mv "$tmp" "$LOCAL_TRACKING_FILE"
}

# --update field=value [field=value ...]
runUpdate() {
  downloadTrackingFile

  local row
  row=$(existingRow)
  [[ -n "$row" ]] || die "no existing row for '${REPO_NAME}' — run without --update first to create it"

  for pair in "$@"; do
    [[ "$pair" == *=* ]] || die "expected field=value, got '${pair}'"
    local field="${pair%%=*}" value="${pair#*=}"
    local column
    column=$(fieldToColumn "$field")
    updateField "$column" "$value"
    log "set ${field} (column ${column}) = ${value} for '${REPO_NAME}'"
  done

  uploadTrackingFile
}

# Default mode: fetch + append (or skip if already present/migrated)
runFetchAndAppend() {
  downloadTrackingFile

  local row
  row=$(existingRow)

  if isAlreadyMigrated "$row"; then
    log "'${REPO_NAME}' already migrated (migration_status=completed or fedmember_added=true) — exiting"
    exit 2
  fi

  if [[ -n "$row" ]]; then
    log "'${REPO_NAME}' already has a pending row — nothing to append, leaving as-is"
    exit 0
  fi

  fetchRepoDetails
  appendRow
  uploadTrackingFile
}

main() {
  if [[ "$UPDATE_MODE" == true ]]; then
    [[ ${#UPDATE_ARGS[@]} -gt 0 ]] || die "usage: track_repo.sh <repo-name> --server <server-id> --update field=value [field=value ...]"
    runUpdate "${UPDATE_ARGS[@]}"
  else
    runFetchAndAppend
  fi
}

main