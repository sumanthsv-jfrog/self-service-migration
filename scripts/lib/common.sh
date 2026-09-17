#!/usr/bin/env bash
# Common helpers sourced by every script. Keep this dependency-free
# (bash + jq + jf CLI only) since it runs inside a GitHub Actions runner.

set -euo pipefail

log()  { echo "[$(date -u +%H:%M:%S)] $*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"
}

# Loads one named environment pair from config/environments.yaml into
# exported SOURCE_SERVER_ID / SOURCE_URL / TARGET_SERVER_ID / TARGET_URL /
# SMALL_REPO_SIZE_MB / SMALL_REPO_FILES vars.
load_environment() {
  local env_name="$1"
  local config_file="${REPO_ROOT}/config/environments.yaml"

  [[ -f "$config_file" ]] || die "config/environments.yaml not found (copy from environments.example.yaml)"

  require_cmd yq

  local base=".environments.${env_name}"
  yq -e "${base}" "$config_file" >/dev/null 2>&1 \
    || die "environment '${env_name}' not defined in ${config_file}"

  SOURCE_SERVER_ID=$(yq -r "${base}.source_server_id" "$config_file")
  SOURCE_URL=$(yq -r "${base}.source_url" "$config_file")
  TARGET_SERVER_ID=$(yq -r "${base}.target_server_id" "$config_file")
  TARGET_URL=$(yq -r "${base}.target_url" "$config_file")
  SMALL_REPO_SIZE_MB=$(yq -r "${base}.small_repo_size_threshold_mb // 500" "$config_file")
  SMALL_REPO_FILES=$(yq -r "${base}.small_repo_file_threshold // 5000" "$config_file")

  export SOURCE_SERVER_ID SOURCE_URL TARGET_SERVER_ID TARGET_URL SMALL_REPO_SIZE_MB SMALL_REPO_FILES
}
