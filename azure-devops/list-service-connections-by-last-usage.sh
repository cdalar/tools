#!/usr/bin/env bash
#
# List Azure DevOps service connections ordered by last usage date.
# Uses only the Azure CLI (with the azure-devops extension).
#
# Auth: set AZURE_DEVOPS_EXT_PAT to a PAT with "Service Connections (Read)",
# plus "Project and Team (Read)" when -p is omitted. It's the same variable
# `az devops` reads. Or leave it unset to use your
# `az login` token. If the organization rejects that token (e.g. one backed
# by a personal Microsoft account), use a PAT.
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
    *) awk 'NR > 1 { if (!/^#/) exit; print }' "$0"; exit 1 ;;
  esac
done
[[ -z $ORG ]] && { echo "Error: -o <organization> is required" >&2; exit 1; }

ORG_URL="https://dev.azure.com/$ORG"
ADO_RESOURCE="499b84ac-1321-427f-aa17-267ca6975798"   # fixed Azure DevOps app ID
SEP=$'\x1f'                                           # field separator safe for empty fields

# Make sure the azure-devops extension is present
az extension show --name azure-devops >/dev/null 2>&1 \
  || az extension add --name azure-devops --only-show-errors

rows=$(mktemp); headers=$(mktemp)          # mktemp files are private (0600)
trap 'rm -f "$rows" "$headers"' EXIT

# Calls with no dedicated az devops command go through az rest. The PAT is
# passed in a headers file so it never shows up in the process list.
# Suppressing the sign-in redirect makes a rejected token fail with 401
# instead of returning an HTML login page that looks like empty history.
auth=(--resource "$ADO_RESOURCE")
if [[ -n ${AZURE_DEVOPS_EXT_PAT:-} ]]; then
  auth=(--skip-authorization-header)
  printf '{"X-TFS-FedAuthRedirect":"Suppress","Authorization":"Basic %s"}' \
    "$(printf ':%s' "$AZURE_DEVOPS_EXT_PAT" | base64 | tr -d '\n')" > "$headers"
else
  printf '{"X-TFS-FedAuthRedirect":"Suppress"}' > "$headers"
fi

ado_get() {   # $1 URL, $2 JMESPath query; prints TSV
  az rest --method get "${auth[@]}" --headers "@$headers" --url "$1" --query "$2" -o tsv
}

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
  (( ${#projects[@]} )) || { echo "Error: could not list projects in $ORG_URL" >&2; exit 1; }
fi

# Check the REST credentials once, on the API the scan needs, so a rejected
# token stops here instead of making every connection look unused.
if ! ado_get "$ORG_URL/$(urlencode "${projects[0]}")/_apis/serviceendpoint/endpoints?\$top=1&api-version=7.1" \
     "count" >/dev/null 2>&1; then
  echo "Error: $ORG_URL rejected the REST API credentials." >&2
  if [[ -n ${AZURE_DEVOPS_EXT_PAT:-} ]]; then
    echo "Check that AZURE_DEVOPS_EXT_PAT is valid for this organization and has" >&2
    echo "the Service Connections (Read) scope." >&2
  else
    echo "Run 'az login', or set AZURE_DEVOPS_EXT_PAT to a PAT if this org does" >&2
    echo "not accept az login tokens (e.g. one backed by a personal Microsoft account)." >&2
  fi
  exit 1
fi

for proj in "${projects[@]}"; do
  echo "Scanning project: $proj" >&2
  proj_enc=$(urlencode "$proj")

  while IFS="$SEP" read -r id name type; do
    [[ -z $id ]] && continue

    # Most recent execution of this connection (history is newest first)
    last="" pipeline="" result="" ok=1
    if hist=$(ado_get \
        "$ORG_URL/$proj_enc/_apis/serviceendpoint/$id/executionhistory?\$top=1&api-version=7.1-preview.1" \
        "value[0].data.[finishTime || startTime, definition.name, result]" 2>/dev/null); then
      IFS="$SEP" read -r last pipeline result <<< "$(tr '\t' "$SEP" <<< "$hist")" || true
      [[ $last == "None" ]] && last=""
      [[ -z $last || $last == [0-9]* ]] || ok=0
    else
      ok=0
    fi
    # Never report a connection whose history couldn't be read as unused
    if (( ! ok )); then
      echo "Warning: could not read usage history of '$name' in '$proj'" >&2
      last="" pipeline="" result="ERROR"
    fi
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
  if [[ -n $sorted ]]; then printf '%s\n' "$sorted"; fi
} | awk -F "$SEP" -v OFS=$'\t' '
    NR > 1 && $1 == "" { $1 = ($7 == "ERROR") ? "unknown" : "never" }
    { $1=$1; for (i=1;i<=NF;i++) if ($i=="") $i="-"; print }' \
  | if command -v column >/dev/null; then column -t -s $'\t'; else cat; fi

# Optional CSV
if [[ -n $CSV ]]; then
  {
    echo "LastUsed,DaysSinceUse,Project,Name,Type,LastPipeline,LastResult"
    if [[ -n $sorted ]]; then awk -F "$SEP" -v OFS=',' '{ for (i=1;i<=NF;i++) { gsub(/"/,"\"\"",$i); $i="\"" $i "\"" } print }' <<< "$sorted"; fi
  } > "$CSV"
  echo "Exported $(grep -c . <<< "$sorted") rows to $CSV" >&2
fi
