#!/usr/bin/env bash
#
# jfrog-repo-config-audit-offline.sh
# Parse a support-bundle "artifactory.repository.config.json" file and produce
# a repo report: local / remote / federated / virtual counts, virtual members,
# nested virtuals (a virtual containing other virtuals), and circular
# references ("circle back") among virtuals.
#
# No API calls, no credentials needed — everything comes from the file.
#
# Requires: jq   (macOS bash 3.2 compatible)
#
# Usage:
#   ./jfrog-repo-config-audit-offline.sh /path/to/artifactory.repository.config.json [--output FILE.csv]
#
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /path/to/artifactory.repository.config.json [--output FILE.csv]" >&2
  exit 1
fi

CONFIG_FILE="$1"; shift
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help)   sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { echo "File not found: $CONFIG_FILE" >&2; exit 1; }
[[ -z "$OUTPUT" ]] && OUTPUT="jfrog-repo-config-$(date +%F).csv"

# validate JSON up front with a clear error (stream from file, never inline it)
jq -e . "$CONFIG_FILE" >/dev/null 2>&1 || {
  echo "Error: $CONFIG_FILE is not valid JSON." >&2
  exit 1
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------- normalize the four config arrays into one flat repo list ----------
# NOTE: large support bundles can have thousands of repos, so the config is
# always passed to jq via --slurpfile (a file path) rather than --argjson
# (a command-line argument) to avoid "Argument list too long" (ARG_MAX).
jq --slurpfile bundle "$CONFIG_FILE" -n '
  ( ($bundle[0].localRepoConfigs     // [])
  + ($bundle[0].remoteRepoConfigs    // [])
  + ($bundle[0].federatedRepoConfigs // [])
  + ($bundle[0].virtualRepoConfigs   // []) )
  | map({ key: .key, type: (.type | ascii_upcase), packageType: (.packageType // "") })
' > "$WORKDIR/repos.json"

# ---------- virtual members: repoTypeConfig.repositoryRefs ----------
jq --slurpfile bundle "$CONFIG_FILE" -n '
  ($bundle[0].virtualRepoConfigs // [])
  | map({ key: .key, members: (.repoTypeConfig.repositoryRefs // []) })
' > "$WORKDIR/virtuals.json"

# ---------- analysis program (categorize + nested + cycles) ----------
read -r -d '' ANALYZE <<'JQ' || true
($repos | map(select(.type=="VIRTUAL") | .key)) as $vkeys
| ($vkeys | INDEX(.)) as $visvirtual
| ($virtuals | INDEX(.key) | map_values(.members)) as $members
| ( $members | to_entries
    | map({ key: .key, value: (.value | map(select($visvirtual[.] != null))) })
    | from_entries ) as $g
| ( $g | to_entries | map(select((.value|length) > 0) | .key) ) as $nested
| def walk($node; $stack; $g):
    ($stack | index($node)) as $i
    | if $i != null then [ $stack[$i:] + [$node] ]
      else ( ($g[$node] // []) | map( walk(.; $stack + [$node]; $g) ) | add // [] )
      end;
  ( [ $g | keys[] as $s | walk($s; []; $g) ] | add // [] ) as $raw_cycles
| ( $raw_cycles
    | map( .[0:-1] as $c | ($c | index(min)) as $mi | $c[$mi:] + $c[:$mi] )
    | unique ) as $cycles
| ( [ $cycles[] | .[] ] | unique ) as $cycle_nodes
| ( reduce ($members | to_entries[]) as $e
      ( {}
      ; reduce $e.value[] as $m
          ( .
          ; .[$m] = ((.[$m] // []) + [$e.key]) ) ) ) as $parent_of
# ---- naming convention checks (add more rules to this list over time) ----
| def maxKeyLength($t):
    if $t == "REMOTE" then 58 else 64 end;
def namingIssues($k; $t):
    [ if ($k | contains("_")) then "underscore" else empty end,
      if ($k | contains(".")) then "dot" else empty end,
      if ($k | length) > maxKeyLength($t) then "too_long" else empty end
      # e.g. add: , if ($k | test("[A-Z]")) then "uppercase" else empty end
    ];
{
    summary: {
      local:     ($repos | map(select(.type=="LOCAL"))     | length),
      remote:    ($repos | map(select(.type=="REMOTE"))    | length),
      federated: ($repos | map(select(.type=="FEDERATED")) | length),
      virtual:   ($vkeys | length),
      nested_virtuals: ($nested | length),
      cycles:    ($cycles | length),
      naming_issues: ( [ $repos[] | select((namingIssues(.key; .type) | length) > 0) ] | length )
    },
    repos: ( $repos
             | map( .key as $rk
                    | { key:$rk, type:.type, packageType:(.packageType // ""),
                        members: ($members[$rk] // []),
                        member_count: (($members[$rk] // []) | length),
                        virtual_members: ($g[$rk] // []),
                        virtual_member_count: (($g[$rk] // []) | length),
                        nested_virtual: (($g[$rk] // []) | length > 0),
                        in_cycle: (($cycle_nodes | index($rk)) != null),
                        part_of_virtuals: ($parent_of[$rk] // []),
                        part_of_virtual_count: (($parent_of[$rk] // []) | length),
                        naming_issues: namingIssues($rk; .type),
                        has_naming_issue: ((namingIssues($rk; .type) | length) > 0) } ) ),
    nested_virtuals: $nested,
    cycles: $cycles
  }
JQ

ANALYSIS_FILE="$WORKDIR/analysis.json"
jq -n --slurpfile repos "$WORKDIR/repos.json" --slurpfile virtuals "$WORKDIR/virtuals.json" \
   '($repos[0]) as $repos | ($virtuals[0]) as $virtuals | '"$ANALYZE" > "$ANALYSIS_FILE"

# ---------- write CSV ----------
jq -r '
  (["key","type","package_type","member_count","nested_virtual","in_cycle","virtual_member_count","virtual_members","part_of_virtual_count","part_of_virtuals","has_naming_issue","naming_issues","members"]),
  (.repos[] | [ .key, .type, .packageType, .member_count, .nested_virtual, .in_cycle,
                .virtual_member_count, (.virtual_members | join(";")),
                .part_of_virtual_count, (.part_of_virtuals | join(";")),
                .has_naming_issue, (.naming_issues | join(";")),
                (.members | join(";")) ])
  | @csv' "$ANALYSIS_FILE" > "$OUTPUT"

# ---------- console summary ----------
echo >&2
echo "=========== Repository Config Audit (offline) ===========" >&2
jq -r '.summary
  | " Local repos      : \(.local)",
    " Remote repos     : \(.remote)",
    " Federated repos  : \(.federated)",
    " Virtual repos    : \(.virtual)",
    "   of which nested: \(.nested_virtuals)",
    " Circular refs    : \(.cycles)",
    " Naming issues    : \(.naming_issues)"' "$ANALYSIS_FILE" >&2

NESTED="$(jq -r '.nested_virtuals[]?' "$ANALYSIS_FILE")"
if [[ -n "$NESTED" ]]; then
  echo >&2; echo "Nested virtuals (contain other virtuals):" >&2
  printf '   - %s\n' $NESTED >&2
fi

CYCLES="$(jq -r '.cycles[] | (. + [.[0]]) | join(" -> ")' "$ANALYSIS_FILE")"
if [[ -n "$CYCLES" ]]; then
  echo >&2; echo "!! CIRCULAR references detected (circle back):" >&2
  printf '%s\n' "$CYCLES" | sed 's/^/   /' >&2
fi

NAMING_COUNT=$(jq '.summary.naming_issues' "$ANALYSIS_FILE")
if [[ "$NAMING_COUNT" -gt 0 ]]; then
  echo >&2; echo "Naming convention issues (avoid underscores; use hyphens):" >&2
  if [[ "$NAMING_COUNT" -gt 50 ]]; then
    jq -r '.repos[] | select(.has_naming_issue) | "\(.key) [\(.type)]"' "$ANALYSIS_FILE" | sort | head -50 | sed 's/^/   - /' >&2
    echo "   ... and $((NAMING_COUNT - 50)) more (see ${OUTPUT})" >&2
  else
    jq -r '.repos[] | select(.has_naming_issue) | "\(.key) [\(.type)]"' "$ANALYSIS_FILE" | sort | sed 's/^/   - /' >&2
  fi
fi

echo >&2; echo "CSV written to ${OUTPUT}" >&2