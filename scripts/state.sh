#!/usr/bin/env bash
# Writes per-job state to state/<job_id>.json and commits it back to the
# repo. Called at each lifecycle transition and periodically during
# transfer. Every call is its own commit — expect a state file's commit
# history to double as its own audit trail; squash/rebase later if that's
# too noisy for your taste.
#
# Usage:
#   state.sh init   <job_id> <repo_name> <source_env> <target_env>
#   state.sh update <job_id> <field=value> [<field=value> ...]
#     - dotted fields address nested keys, e.g. progress.bytes_done=1000
#   state.sh read   <job_id>

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

require_cmd jq

STATE_DIR="${REPO_ROOT}/state"
mkdir -p "$STATE_DIR"

state_path() { echo "${STATE_DIR}/${1}.json"; }

commit_state() {
  local job_id="$1" message="$2"
  cd "$REPO_ROOT"
  git add "$(state_path "$job_id")"
  # Nothing changed (e.g. re-running the same update) — don't fail the job.
  git diff --cached --quiet && return 0
  git -c user.name="migration-bot" -c user.email="migration-bot@users.noreply.github.com" \
    commit -q -m "$message"
  git push -q
}

cmd_init() {
  local job_id="$1" repo_name="$2" source_env="$3" target_env="$4"
  jq -n \
    --arg job_id "$job_id" \
    --arg repo_name "$repo_name" \
    --arg source_env "$source_env" \
    --arg target_env "$target_env" \
    --arg now "$(date -u +%FT%TZ)" \
    '{
      job_id: $job_id,
      repo_name: $repo_name,
      source_env: $source_env,
      target_env: $target_env,
      status: "queued",
      created_at: $now,
      updated_at: $now,
      progress: {bytes_total: 0, bytes_done: 0, files_total: 0, files_done: 0},
      diff_notes: {source_file_count: null, target_file_count: null, source_size_bytes: null, target_size_bytes: null},
      error: null
    }' > "$(state_path "$job_id")"
  commit_state "$job_id" "state: init job ${job_id} (${repo_name})"
}

cmd_update() {
  local job_id="$1"; shift
  local path
  path="$(state_path "$job_id")"
  [[ -f "$path" ]] || die "no state file for job ${job_id} — run 'state.sh init' first"

  local tmp
  tmp=$(mktemp)
  cp "$path" "$tmp"

  for kv in "$@"; do
    local key="${kv%%=*}"
    local value="${kv#*=}"
    # key may be dotted (progress.bytes_done) — that's valid jq path syntax as-is.
    # Numeric values stay numbers, everything else becomes a string.
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      jq ".${key} = ${value} | .updated_at = \"$(date -u +%FT%TZ)\"" "$tmp" > "${tmp}.new"
    else
      jq --arg v "$value" ".${key} = \$v | .updated_at = \"$(date -u +%FT%TZ)\"" "$tmp" > "${tmp}.new"
    fi
    mv "${tmp}.new" "$tmp"
  done

  mv "$tmp" "$path"
  local summary="$*"
  commit_state "$job_id" "state: update job ${job_id} (${summary})"
}

cmd_read() {
  local job_id="$1"
  cat "$(state_path "$job_id")"
}

case "${1:-}" in
  init)   shift; cmd_init "$@" ;;
  update) shift; cmd_update "$@" ;;
  read)   shift; cmd_read "$@" ;;
  *) die "usage: state.sh {init|update|read} ..." ;;
esac
