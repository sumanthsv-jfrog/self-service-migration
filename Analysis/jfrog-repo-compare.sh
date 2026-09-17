#!/usr/bin/env bash
#
# jfrog-repo-compare.sh
# Compare repository configs from two JFrog Artifactory instances (as pulled
# from support bundles) and report which repo KEYS exist in both instances
# (duplicates), and which are unique to one side.
#
# A "duplicate" here means: the same repo key exists in both instances,
# regardless of type (local/remote/federated/virtual) or package type. Each
# duplicate row also shows the type/package on each side and flags it if
# they differ, since that's worth knowing even though it doesn't change
# whether something counts as a duplicate.
#
# No API calls, no credentials — reads both config files directly.
#
# Requires: jq   (macOS bash 3.2 compatible)
#
# Usage:
#   ./jfrog-repo-compare.sh instance1.json instance2.json \
#       [--label1 "Prod"] [--label2 "DR"] [--output FILE.csv]
#
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 instance1.json instance2.json [--label1 NAME] [--label2 NAME] [--output FILE.csv]" >&2
  exit 1
fi

FILE1="$1"; shift
FILE2="$1"; shift
LABEL1="instance1"
LABEL2="instance2"
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label1)  LABEL1="${2:-}"; shift 2 ;;
    --label2)  LABEL2="${2:-}"; shift 2 ;;
    --output|-o) OUTPUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
[[ -f "$FILE1" ]] || { echo "File not found: $FILE1" >&2; exit 1; }
[[ -f "$FILE2" ]] || { echo "File not found: $FILE2" >&2; exit 1; }
[[ -z "$OUTPUT" ]] && OUTPUT="jfrog-repo-comparison-$(date +%F).csv"

for f in "$FILE1" "$FILE2"; do
  jq -e . "$f" >/dev/null 2>&1 || { echo "Error: $f is not valid JSON." >&2; exit 1; }
done

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------- normalize each instance's four config arrays into a flat repo list ----------
# Always via --slurpfile (a file path) rather than --argjson (a command-line
# argument) — large support bundles can exceed the OS argument-length limit.
normalize() {
  local SRC="$1" OUT="$2"
  jq --slurpfile bundle "$SRC" -n '
    ( ($bundle[0].localRepoConfigs     // [])
    + ($bundle[0].remoteRepoConfigs    // [])
    + ($bundle[0].federatedRepoConfigs // [])
    + ($bundle[0].virtualRepoConfigs   // []) )
    | map({ key: .key, type: (.type | ascii_upcase), packageType: (.packageType // "") })
  ' > "$OUT"
}
normalize "$FILE1" "$WORKDIR/repos1.json"
normalize "$FILE2" "$WORKDIR/repos2.json"

N1=$(jq 'length' "$WORKDIR/repos1.json")
N2=$(jq 'length' "$WORKDIR/repos2.json")
echo "Loaded ${N1} repos from ${LABEL1} (${FILE1})" >&2
echo "Loaded ${N2} repos from ${LABEL2} (${FILE2})" >&2

# ---------- compare: full outer join on repo key ----------
COMPARE_FILE="$WORKDIR/compare.json"
jq -n --slurpfile r1 "$WORKDIR/repos1.json" --slurpfile r2 "$WORKDIR/repos2.json" \
      --arg l1 "$LABEL1" --arg l2 "$LABEL2" '
  ($r1[0] | INDEX(.key)) as $m1
  | ($r2[0] | INDEX(.key)) as $m2
  | ( ($r1[0] | map(.key)) + ($r2[0] | map(.key)) | unique ) as $allKeys
  | [ $allKeys[] as $k
      | { key: $k,
          in1: ($m1[$k] != null),
          in2: ($m2[$k] != null),
          type1: ($m1[$k].type // ""),
          type2: ($m2[$k].type // ""),
          pkg1:  ($m1[$k].packageType // ""),
          pkg2:  ($m2[$k].packageType // "") }
      | . + { status: (if .in1 and .in2 then "both"
                        elif .in1 then ("only_" + $l1)
                        else ("only_" + $l2) end),
              type_mismatch: (.in1 and .in2 and (.type1 != .type2)) } ]
' > "$COMPARE_FILE"

# ---------- write CSV ----------
jq -r --arg l1 "$LABEL1" --arg l2 "$LABEL2" '
  (["key","status","\($l1)_type","\($l2)_type","type_mismatch","\($l1)_package_type","\($l2)_package_type"]),
  ( sort_by(.key)[]
    | [ .key, .status, .type1, .type2, .type_mismatch, .pkg1, .pkg2 ] )
  | @csv
' "$COMPARE_FILE" > "$OUTPUT"

# ---------- console summary ----------
BOTH=$(jq '[.[] | select(.status=="both")] | length' "$COMPARE_FILE")
ONLY1=$(jq --arg s "only_${LABEL1}" '[.[] | select(.status==$s)] | length' "$COMPARE_FILE")
ONLY2=$(jq --arg s "only_${LABEL2}" '[.[] | select(.status==$s)] | length' "$COMPARE_FILE")
MISMATCH=$(jq '[.[] | select(.type_mismatch==true)] | length' "$COMPARE_FILE")

echo >&2
echo "=========== Repository Comparison: ${LABEL1} vs ${LABEL2} ===========" >&2
echo " ${LABEL1} total repos     : ${N1}" >&2
echo " ${LABEL2} total repos     : ${N2}" >&2
echo " Duplicate keys (in both) : ${BOTH}" >&2
echo "   of which type mismatch: ${MISMATCH}" >&2
echo " Only in ${LABEL1}        : ${ONLY1}" >&2
echo " Only in ${LABEL2}        : ${ONLY2}" >&2

if [[ "$BOTH" -gt 0 ]]; then
  echo >&2
  echo "Duplicate repo keys (exist in both instances):" >&2
  if [[ "$BOTH" -gt 50 ]]; then
    jq -r '.[] | select(.status=="both") | .key' "$COMPARE_FILE" | sort | head -50 | sed 's/^/   - /' >&2
    echo "   ... and $((BOTH - 50)) more (see ${OUTPUT})" >&2
  else
    jq -r '.[] | select(.status=="both") | .key' "$COMPARE_FILE" | sort | sed 's/^/   - /' >&2
  fi
fi

if [[ "$MISMATCH" -gt 0 ]]; then
  echo >&2
  echo "!! Duplicates with a DIFFERENT type on each side:" >&2
  if [[ "$MISMATCH" -gt 50 ]]; then
    jq -r --arg l1 "$LABEL1" --arg l2 "$LABEL2" '
      .[] | select(.type_mismatch==true)
      | "   - \(.key): \($l1)=\(.type1)  \($l2)=\(.type2)"
    ' "$COMPARE_FILE" | head -50 >&2
    echo "   ... and $((MISMATCH - 50)) more (see ${OUTPUT})" >&2
  else
    jq -r --arg l1 "$LABEL1" --arg l2 "$LABEL2" '
      .[] | select(.type_mismatch==true)
      | "   - \(.key): \($l1)=\(.type1)  \($l2)=\(.type2)"
    ' "$COMPARE_FILE" >&2
  fi
fi

echo >&2; echo "CSV written to ${OUTPUT}" >&2
