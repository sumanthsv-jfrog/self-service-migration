#!/usr/bin/env bash
# Common helpers sourced by every script. Keep this dependency-free
# (bash + jq + jf CLI only) since it runs inside a GitHub Actions runner.

set -euo pipefail

log()  { echo "[$(date -u +%H:%M:%S)] $*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"
}

# Where the tracking file (repo, size, count, config_status,
# migration_status, Fedmember_added, actual_size, requested_time)
# lives. The server id is passed in as a script argument (--server)
# rather than fixed here, since which instance hosts it may vary by
# caller. TRACKING_REPO/TRACKING_FILE_PATH are the single source of
# truth — do not redefine these in any script that sources this file.
TRACKING_REPO="cba-self-service"
TRACKING_FILE_PATH="repo-tracking.csv"
TRACKING_CSV_HEADER="repo,size,count,config_status,migration_status,Fedmember_added,actual_size,requested_time"
