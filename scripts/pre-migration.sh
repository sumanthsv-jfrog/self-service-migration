#!/usr/bin/env bash
# Pipeline A, end to end for one repo: download the tracking file,
# exit early if already migrated, check connectivity + source
# existence, fetch size/count, append a row, create the repo in target
# if needed, flip config_status, upload once at the end.
#
# Renamed from track_repo.sh, with repo_manager.sh's connectivity/repo
# check/create logic folded in — this is now the single script Pipeline
# A runs, rather than two.
#
# Usage:
#   pre-migration.sh <repo-name> --server <tracking-server-id> \
#       --source-server <server-id> --target-server <server-id>
#
#   pre-migration.sh <repo-name> --server <tracking-server-id> \
#       --update field=value [field=value ...]
#       patch specific fields on an existing row without touching
#       source/target at all. Recognized field names: config (or
#       config_status), migration (or migration_status), fedmember (or
#       fedmember_added).
#
# --server is always required (hosts the tracking repo).
# --source-server / --target-server are required in fetch mode only.
#
# Exit codes:
#   0 - proceeded normally (row appended/resumed, or fields updated)
#   2 - fetch mode only: repo already migrated (migration_status=completed
#       or fedmember_added=true) — Pipeline A should stop here
#   1 - error
#
# CONCURRENCY WARNING: every mode here does download -> modify -> upload,
# a read-modify-write race if two calls execute close together. Put a
# `concurrency:` group on whichever workflow step(s) call this script.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

require_cmd jf
require_cmd jq

REPO_NAME="${1:?usage: pre-migration.sh <repo-name> --server <server-id> [...]}"
shift

TRACKING_SERVER_ID=""
SOURCE_SERVER_ID=""
TARGET_SERVER_ID=""
UPDATE_MODE=false
UPDATE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server)         TRACKING_SERVER_ID="${2:?--server requires a value}"; shift 2 ;;
    --source-server)  SOURCE_SERVER_ID="${2:?--source-server requires a value}"; shift 2 ;;
    --target-server)  TARGET_SERVER_ID="${2:?--target-server requires a value}"; shift 2 ;;
    --update)
      shift
      UPDATE_MODE=true
      UPDATE_ARGS=("$@")
      break
      ;;
    *) die "unknown argument '$1'" ;;
  esac
done

[[ -n "$TRACKING_SERVER_ID" ]] || die "--server <server-id> is required"

LOCAL_TRACKING_FILE="repo_status.csv"
REPO_CONFIG_FILE="/tmp/${REPO_NAME}.json"

# --- tracking file I/O -------------------------------------------------

downloadTrackingFile() {
  # Check tracking-server connectivity BEFORE attempting download. This
  # matters beyond just failing fast: without this check, a download
  # failure caused by the tracking server being unreachable looks
  # identical to "file doesn't exist yet" — which would silently start
  # a fresh header-only file, and the later upload would then WIPE OUT
  # every previously tracked repo. Distinguishing "genuinely missing"
  # from "can't reach it" here prevents that.
  jf rt ping --server-id="$TRACKING_SERVER_ID" >/dev/null \
    || die "cannot reach tracking server '${TRACKING_SERVER_ID}' — aborting rather than risk starting a fresh tracking file and overwriting existing data on upload"

  jf rt download "${TRACKING_REPO}/${TRACKING_FILE_PATH}" "$LOCAL_TRACKING_FILE" \
    --server-id="$TRACKING_SERVER_ID" --flat=true >/dev/null 2>&1 || true

  # Check the file actually landed, rather than trusting jf's exit code
  # alone — first-time case (nothing uploaded yet) is the common reason
  # it won't be there, but this also catches jf reporting success
  # without actually writing the file. Connectivity is already
  # confirmed above, so a missing file here means genuinely no file yet.
  if [[ -f "$LOCAL_TRACKING_FILE" ]]; then
    log "downloaded existing tracking file"
  else
    log "no tracking file found on disk after download — starting a new one"
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
# explicitly rather than assuming downloadTrackingFile always ran first.
existingRow() {
  [[ -f "$LOCAL_TRACKING_FILE" ]] || return 0
  awk -F',' -v repo="$REPO_NAME" 'NR>1 && $1==repo' "$LOCAL_TRACKING_FILE"
}

isAlreadyMigrated() {
  local row="$1"
  [[ -z "$row" ]] && return 1
  local migration_status fedmember_added
  migration_status=$(echo "$row" | awk -F',' '{print $5}')
  fedmember_added=$(echo "$row" | awk -F',' '{print $6}')
  [[ "$migration_status" == "completed" || "$fedmember_added" == "true" ]]
}

configStatusOf() {
  echo "$1" | awk -F',' '{print $4}'
}

# --- source data ---------------------------------------------------------

# Fetches size (GB), file count, and human-readable size for REPO_NAME
# from source via the storageinfo API, which — unlike repo-get —
# actually reports usage. usedSpaceInBytes is the raw figure; usedSpace
# is a human string (e.g. "1.23 MB") kept as-is for the actual_size
# column since 2-decimal GB rounds small/medium repos to 0.00.
fetchRepoDetails() {
  local storageinfo
  storageinfo=$(jf rt curl -s -XGET api/storageinfo --server-id="$SOURCE_SERVER_ID") \
    || die "failed to fetch storageinfo from source"

  local entry
  entry=$(echo "$storageinfo" | jq -c --arg repo "$REPO_NAME" \
    '.repositoriesSummaryList[] | select(.repoKey == $repo)')

  [[ -n "$entry" ]] || die "repo '${REPO_NAME}' not found in source storageinfo"

  local used_space_bytes
  used_space_bytes=$(echo "$entry" | jq -r '.usedSpaceInBytes // 0')
  REPO_SIZE_GB=$(awk -v b="$used_space_bytes" 'BEGIN { printf "%.2f", b / 1024 / 1024 / 1024 }')
  REPO_FILE_COUNT=$(echo "$entry" | jq -r '.filesCount // 0')
  REPO_ACTUAL_SIZE=$(echo "$entry" | jq -r '.usedSpace // "N/A"')
}

appendRow() {
  local requested_time
  requested_time=$(date -u +%FT%TZ)
  echo "${REPO_NAME},${REPO_SIZE_GB},${REPO_FILE_COUNT},pending,pending,false,${REPO_ACTUAL_SIZE},${requested_time}" >> "$LOCAL_TRACKING_FILE"
  log "appended row for '${REPO_NAME}' (size=${REPO_SIZE_GB}GB [${REPO_ACTUAL_SIZE}], count=${REPO_FILE_COUNT}, requested=${requested_time})"
}

# --- connectivity + repo existence/creation (merged from repo_manager.sh) --

checkConnectivity() {
  jf rt ping --server-id="$SOURCE_SERVER_ID" >/dev/null || die "cannot reach ${SOURCE_SERVER_ID}"
  jf rt ping --server-id="$TARGET_SERVER_ID" >/dev/null || die "cannot reach ${TARGET_SERVER_ID}"
  log "source (${SOURCE_SERVER_ID}) and target (${TARGET_SERVER_ID}) reachable"
}

checkIfRepoExistInSource() {
  jf rt curl -s -XGET api/repositories --server-id="$SOURCE_SERVER_ID" \
    | jq -r '.[] | .key' | grep -qw "$REPO_NAME"
}

checkIfRepoExistInTarget() {
  echo "REPO_NAME $REPO_NAME"
  jf rt curl -s -XGET api/repositories --server-id="$TARGET_SERVER_ID" \
    | jq -r '.[] | .key' | grep -w "$REPO_NAME"
}

createRepoInTarget() {
  log "repo '${REPO_NAME}' not found in target — fetching source config"
  jf rt curl -s -XGET "api/repositories/${REPO_NAME}" --server-id="$SOURCE_SERVER_ID" > "$REPO_CONFIG_FILE"

  log "creating '${REPO_NAME}' in target from source config"
  jf rt curl -s -XPUT "api/repositories/${REPO_NAME}" \
    -H "Content-Type: application/json" \
    -T "$REPO_CONFIG_FILE" \
    --server-id="$TARGET_SERVER_ID" >/dev/null \
    || die "failed to create repo '${REPO_NAME}' in target"

  # The create API can return success before api/repositories' listing
  # reflects it (seen in practice: creation succeeds, but an immediate
  # re-check of the list doesn't show it yet). Retry with a short
  # backoff instead of failing on the first miss.
  local attempt
  for attempt in 1 2 3 4 5; do
    if checkIfRepoExistInTarget; then
      log "repo '${REPO_NAME}' created in target"
      rm -f "$REPO_CONFIG_FILE"
      return 0
    fi
    log "repo '${REPO_NAME}' not visible in target listing yet (attempt ${attempt}/5) — retrying in 5s"
    sleep 5
  done

  die "repo '${REPO_NAME}' still not found in target after create (checked 5 times over 25s)"
}

ensureTargetRepoAndFlipConfigStatus() {
  if checkIfRepoExistInTarget; then
    log "repo '${REPO_NAME}' already exists in target"
  else
    createRepoInTarget
  fi
  updateField 4 "completed"
}

# --- field updates (shared by --update mode and the config_status flip) --

fieldToColumn() {
  case "$1" in
    config|config_status)         echo 4 ;;
    migration|migration_status)   echo 5 ;;
    fedmember|fedmember_added)    echo 6 ;;
    *) die "unknown field '$1' — expected config, migration, or fedmember" ;;
  esac
}

updateField() {
  local column="$1" value="$2"
  local tmp
  tmp=$(mktemp)
  awk -F',' -v OFS=',' -v repo="$REPO_NAME" -v col="$column" -v val="$value" \
    'NR==1 { print; next } $1==repo { $col=val } { print }' \
    "$LOCAL_TRACKING_FILE" > "$tmp"
  mv "$tmp" "$LOCAL_TRACKING_FILE"
}

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

# --- main fetch/prepare mode --------------------------------------------

runFetchAndPrepare() {
  [[ -n "$SOURCE_SERVER_ID" ]] || die "--source-server <server-id> is required"
  [[ -n "$TARGET_SERVER_ID" ]] || die "--target-server <server-id> is required"

  downloadTrackingFile

  local row
  row=$(existingRow)

  if isAlreadyMigrated "$row"; then
    log "'${REPO_NAME}' already migrated (migration_status=completed or fedmember_added=true) — exiting"
    exit 2
  fi

  if [[ -n "$row" ]]; then
    if [[ "$(configStatusOf "$row")" == "completed" ]]; then
      log "'${REPO_NAME}' already has config_status=completed — nothing to do"
      exit 0
    fi
    log "'${REPO_NAME}' has a pending row from a previous run — resuming at repo creation, not re-fetching size/count"
  else
    checkConnectivity
    checkIfRepoExistInSource || die "repo '${REPO_NAME}' not found in source"
    fetchRepoDetails
    appendRow
  fi

  ensureTargetRepoAndFlipConfigStatus
  uploadTrackingFile
}

main() {
  if [[ "$UPDATE_MODE" == true ]]; then
    [[ ${#UPDATE_ARGS[@]} -gt 0 ]] || die "usage: pre-migration.sh <repo-name> --server <server-id> --update field=value [field=value ...]"
    runUpdate "${UPDATE_ARGS[@]}"
  else
    runFetchAndPrepare
  fi
}

main