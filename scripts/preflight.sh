#!/usr/bin/env bash
# Pre-flight: jf rt ping against source and target, run from the runner
# executing the workflow. Data Transfer plugin install on the source VM
# is a manual, one-time admin step and is intentionally NOT checked here
# (this workflow runner has no way to reach into the source VM's plugin
# state) — see docs/design.md.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh"

require_cmd jf

check_connectivity() {
  local server_id="$1"
  log "pinging ${server_id}..."
  if ! jf rt ping --server-id "$server_id"; then
    die "cannot reach '${server_id}' (network, auth, or wrong server-id)"
  fi
  log "${server_id} reachable"
}

check_connectivity "$SOURCE_SERVER_ID"
check_connectivity "$TARGET_SERVER_ID"
