#!/usr/bin/env bash
# Orchestrates one repo migration. Called by the workflow after
# repo_manager.sh has already succeeded (connectivity + repo exists).
#
# Completion is determined by jf rt transfer-files' own exit status.
# File count/size comparison is logged into diff_notes as a diagnostic
# only — it never fails an otherwise-successful job (legitimate drift is
# expected: metadata, in-flight files, trash/cache artifacts). See
# docs/design.md.

set -uo pipefail  # not -e: we need transfer-files' exit code, not an early abort
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

require_cmd jf
require_cmd jq

REPO_NAME="${1:?usage: migrate.sh <repo-name> <job_id>}"
JOB_ID="${2:?usage: migrate.sh <repo-name> <job_id>}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-30}"
WAIT_CHECK_SECONDS="${WAIT_CHECK_SECONDS:-30}"

STATE="${REPO_ROOT}/scripts/state.sh"
TRANSFER_LOG=""

# GitHub's concurrency group already queues workflow runs one-at-a-time
# per environment, but this is a belt-and-braces check at the script
# level in case transfer-files ever gets invoked outside that workflow
# path (e.g. run manually on the box). We only know how to run one
# transfer-files at a time for now — if that ever needs to change,
# revisit here rather than assuming jf supports concurrent transfers.
isMigrationRunning() {
  pgrep -f "jf rt transfer-files" >/dev/null 2>&1
}

preMigration() {
  if isMigrationRunning; then
    log "another transfer-files is already running — waiting for it to finish"
  fi
  while isMigrationRunning; do
    sleep "$WAIT_CHECK_SECONDS"
  done
  log "no migration in progress, proceeding"
}

runMigration() {
  "$STATE" update "$JOB_ID" status=transferring

  TRANSFER_LOG=$(mktemp)
  jf rt transfer-files source-server target-server "$REPO_NAME" \
    > "$TRANSFER_LOG" 2>&1 &
  local transfer_pid=$!

  log "transfer-files started (pid ${transfer_pid}), polling every ${POLL_INTERVAL_SECONDS}s"

  while kill -0 "$transfer_pid" 2>/dev/null; do
    sleep "$POLL_INTERVAL_SECONDS"
    pollProgress
  done

  wait "$transfer_pid"
  return $?
}

pollProgress() {
  # jf rt transfer-files prints periodic JSON progress lines to stdout;
  # grab the latest one if present. Verify this against your installed
  # jf CLI version's actual output format and adjust the pattern if it
  # doesn't match.
  local latest_progress
  latest_progress=$(grep -o '{.*"filesTransferred".*}' "$TRANSFER_LOG" | tail -1 || true)
  [[ -n "$latest_progress" ]] || return 0

  local files_done bytes_done
  files_done=$(echo "$latest_progress" | jq -r '.filesTransferred // 0')
  bytes_done=$(echo "$latest_progress" | jq -r '.bytesTransferred // 0')
  "$STATE" update "$JOB_ID" \
    "progress.files_done=${files_done}" \
    "progress.bytes_done=${bytes_done}"
}

handleFailure() {
  local exit_code="$1"
  local error_tail
  error_tail=$(tail -c 2000 "$TRANSFER_LOG" | tr '\n' ' ')
  "$STATE" update "$JOB_ID" status=failed "error=${error_tail}"
  log "transfer-files failed (exit ${exit_code})"
  cat "$TRANSFER_LOG" >&2
}

logDiffNotes() {
  # Diagnostic-only file count/size comparison — logged, never blocks
  # completion. Uses jf rt curl against the repositories API, same
  # pattern as repo_manager.sh.
  # NOTE: api/repositories/<repo> returns config, not usage stats; swap
  # in the real repository summary/storage-info endpoint once picked.
  local source_info target_info
  source_info=$(jf rt curl -XGET "api/repositories/${REPO_NAME}" --server-id=source-server 2>/dev/null || echo '{}')
  target_info=$(jf rt curl -XGET "api/repositories/${REPO_NAME}" --server-id=target-server 2>/dev/null || echo '{}')

  local src_files tgt_files src_size tgt_size
  src_files=$(echo "$source_info" | jq -r '.filesCount // "null"')
  tgt_files=$(echo "$target_info" | jq -r '.filesCount // "null"')
  src_size=$(echo "$source_info" | jq -r '.usedSpaceBytes // "null"')
  tgt_size=$(echo "$target_info" | jq -r '.usedSpaceBytes // "null"')

  if [[ "$src_files" != "$tgt_files" || "$src_size" != "$tgt_size" ]]; then
    log "NOTE: file count/size differ between source and target (source: ${src_files} files / ${src_size} bytes, target: ${tgt_files} files / ${tgt_size} bytes) — logged only, not treated as failure"
  fi

  "$STATE" update "$JOB_ID" \
    "diff_notes.source_file_count=${src_files}" \
    "diff_notes.target_file_count=${tgt_files}" \
    "diff_notes.source_size_bytes=${src_size}" \
    "diff_notes.target_size_bytes=${tgt_size}"
}

main() {
  preMigration
  runMigration
  local exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    handleFailure "$exit_code"
    rm -f "$TRANSFER_LOG"
    exit "$exit_code"
  fi

  log "transfer-files completed successfully"
  logDiffNotes
  "$STATE" update "$JOB_ID" status=completed
  rm -f "$TRANSFER_LOG"
}

main