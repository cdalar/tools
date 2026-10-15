#!/usr/bin/env bash
#
# List Azure DevOps service connections ordered by last usage date.
# Uses only the Azure CLI (with the azure-devops extension) and your
# existing `az login` session.
#
# Usage:
#   ./list-service-connections-by-last-usage.sh -o <org> [-p <project>] [-a] [-c out.csv]
#
#   -o  Organization name (the part after dev.azure.com/)       [required]
#   -p  Project name. Omit to scan every project in the org.
#   -a  Ascending: oldest / never-used first (good for cleanup)
#   -c  Also write the results to this CSV file
#
# Examples:
#   ./list-service-connections-by-last-usage.sh -o contoso -p Web
#   ./list-service-connections-by-last-usage.sh -o contoso -a -c stale.csv

set -euo pipefail

ORG="" PROJECT="" ASC=0 CSV=""
while getopts "o:p:ac:h" opt; do
  case $opt in
    o) ORG=$OPTARG ;;
    p) PROJECT=$OPTARG ;;
    a) ASC=1 ;;
    c) CSV=$OPTARG ;;
    *) sed -n '2,18p' "$0"; exit 1 ;;
  esac
done
[[ -z $ORG ]] && { echo "Error: -o <organization> is required" >&2; exit 1; }

ORG_URL="https://dev.azure.com/$ORG"
ADO_RESOURCE="499b84ac-1321-427f-aa17-267ca6975798"   # fixed Azure DevOps app ID
SEP=$'\x1f'                                           # field separator safe for empty fields

# Make sure the azure-devops extension is present
az extension show --name azure-devops >/dev/null 2>&1 \
  || az extension add --name azure-devops --only-show-errors

# Days between an ISO-8601 timestamp and now (GNU date, then BSD/macOS date)
days_since() {
  local ts=${1%%.*} epoch
  ts=${ts%Z}
  epoch=$(date -u -d "$ts" +%s 2>/dev/null \
       || date -u -j -f "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null) || { echo ""; return; }
  echo $(( ( $(date -u +%s) - epoch ) / 86400 ))
}

urlencode() {
  local s=$1 out="" c i
  for (( i=0; i<${#s}; i++ )); do
    c=${s:i:1}
    case $c in [a-zA-Z0-9.~_-]) out+=$c ;; *) out+=$(printf '%%%02X' "'$c") ;; esac
  done
  echo "$out"
}

# Projects to scan
if [[ -n $PROJECT ]]; then
  projects=("$PROJECT")
else
  projects=()   # read loop instead of mapfile, which macOS bash 3.2 lacks
  while IFS= read -r p; do
    [[ -n $p ]] && projects+=("$p")
  done < <(az devops project list --org "$ORG_URL" --query "value[].name" -o tsv)
  (( ${#projects[@]} )) || { echo "Error: no projects found in $ORG_URL" >&2; exit 1; }
fi

rows=$(mktemp)
trap 'rm -f "$rows"' EXIT

for proj in "${projects[@]}"; do
  echo "Scanning project: $proj" >&2
  proj_enc=$(urlencode "$proj")

  while IFS="$SEP" read -r id name type; do
    [[ -z $id ]] && continue

    # Most recent execution of this connection (history is newest first).
    # There is no dedicated az devops command for this, so az rest is used.
    hist=$(az rest --method get --resource "$ADO_RESOURCE" \
      --url "$ORG_URL/$proj_enc/_apis/serviceendpoint/$id/executionhistory?\$top=1&api-version=7.1-preview.1" \
      --query "value[0].data.[finishTime || startTime, definition.name, result]" \
      -o tsv 2>/dev/null | tr '\t' "$SEP") || hist=""

    IFS="$SEP" read -r last pipeline result <<< "$hist" || true
    [[ $last == "None" ]] && last=""
    days=""; [[ -n $last ]] && days=$(days_since "$last")

    printf '%s\n' "${last:0:19}$SEP$days$SEP$proj$SEP$name$SEP$type$SEP${pipeline}$SEP${result}" >> "$rows"
  done < <(az devops service-endpoint list --org "$ORG_URL" --project "$proj" \
             --query "[].[id, name, type]" -o tsv | tr '\t' "$SEP")
done

# Sort by the ISO date. Never-used rows (empty date) land at the stale end.
if (( ASC )); then
  sorted=$(sort -t "$SEP" -k1,1 "$rows")
else
  sorted=$(sort -t "$SEP" -k1,1r "$rows")
fi

# Pretty table
{
  echo "LAST_USED${SEP}DAYS${SEP}PROJECT${SEP}NAME${SEP}TYPE${SEP}LAST_PIPELINE${SEP}RESULT"
  if [[ -n $sorted ]]; then sed "s/^$SEP/never$SEP/" <<< "$sorted"; fi
} | awk -F "$SEP" -v OFS=$'\t' '{ $1=$1; for (i=1;i<=NF;i++) if ($i=="") $i="-"; print }' \
  | if command -v column >/dev/null; then column -t -s $'\t'; else cat; fi

# Optional CSV
if [[ -n $CSV ]]; then
  {
    echo "LastUsed,DaysSinceUse,Project,Name,Type,LastPipeline,LastResult"
    if [[ -n $sorted ]]; then awk -F "$SEP" -v OFS=',' '{ for (i=1;i<=NF;i++) { gsub(/"/,"\"\"",$i); $i="\"" $i "\"" } print }' <<< "$sorted"; fi
  } > "$CSV"
  echo "Exported $(grep -c . <<< "$sorted") rows to $CSV" >&2
fi
