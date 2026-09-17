#!/usr/bin/env bash
# Ensures REPO_NAME exists in target, creating it from source config if
# missing. Uses `jf rt curl` against the repositories REST API directly
# (server-ids are fixed: source-server / target-server, added manually
# on the runner via `jf c add` — see docs/design.md).

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

require_cmd jf
require_cmd jq

REPO_NAME="${1:?usage: repo_manager.sh <repo-name>}"
CONFIG_FILE="/tmp/${REPO_NAME}.json"

checkConnectivity() {
  jf rt ping --server-id=source-server >/dev/null || die "cannot reach source-server"
  jf rt ping --server-id=target-server >/dev/null || die "cannot reach target-server"
  log "source-server and target-server reachable"
}

checkIfRepoExistInSource() {
  local repo="$1"
  jf rt curl -XGET api/repositories --server-id=source-server \
    | jq -r '.[] | .key' | grep -qw "$repo"
}

checkIfRepoExistInTarget() {
  local repo="$1"
  jf rt curl -XGET api/repositories --server-id=target-server \
    | jq -r '.[] | .key' | grep -qw "$repo"
}

createRepo() {
  local repo="$1"
  log "repo '${repo}' not found in target — fetching source config"
  jf rt curl -XGET "api/repositories/${repo}" --server-id=source-server > "$CONFIG_FILE"

  log "creating '${repo}' in target from source config"
  jf rt curl -XPUT "api/repositories/${repo}" \
    -H "Content-Type: application/json" \
    -T "$CONFIG_FILE" \
    --server-id=target-server \
    || die "failed to create repo '${repo}' in target"
}

checkConnectivity

checkIfRepoExistInSource "$REPO_NAME" || die "repo '${REPO_NAME}' not found in source"

if checkIfRepoExistInTarget "$REPO_NAME"; then
  log "repo '${REPO_NAME}' already exists in target"
else
  createRepo "$REPO_NAME"
  checkIfRepoExistInTarget "$REPO_NAME" || die "repo '${REPO_NAME}' still not found in target after create"
  log "repo '${REPO_NAME}' created in target"
fi

rm -f "$CONFIG_FILE"