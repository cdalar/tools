# k8s-funcs.sh -- kubectl + jq resource reports
#
# Load into your current shell (don't execute it):
#   source ~/k8s-funcs.sh
# Load it in every new terminal:
#   echo '[ -f ~/k8s-funcs.sh ] && source ~/k8s-funcs.sh' >> ~/.bashrc   # or ~/.zshrc
#
# Functions (all read-only, current kubectl context, Running pods only):
#   toppods [N]                 top N pods by memory request, with node (default 20)
#   nodemem                     memory requested per node
#   nstotals                    memory requested per namespace, cluster total last
#   nsreq <namespace> [mem|cpu] workloads in a namespace: pods, memory and CPU per pod and in total
#   nodereport [namespace]      per node: pods, memory allocatable / requested / limits / used, CPU requested %;
#                               with a namespace, also that namespace's pods and memory request per node
#
# Requires: kubectl, jq, awk. Usage in nodereport needs metrics-server ("n/a" without it).

# jq helpers: memory quantities -> bytes, CPU quantities -> millicores
_K8S_JQ_DEFS='
  def bytes: if . == null then 0 else
    capture("(?<n>[0-9.]+)(?<u>[A-Za-z]*)")
    | (.n|tonumber) * ({"":1,"k":1e3,"K":1e3,"M":1e6,"G":1e9,"T":1e12,
        "Ki":1024,"Mi":1048576,"Gi":1073741824,"Ti":1099511627776}[.u] // 1) end;
  def millicores: if . == null then 0
    elif endswith("m") then (.[:-1] | tonumber)
    else (tonumber * 1000) end;
'

_k8s_need() {
  local b
  for b in kubectl jq awk; do
    command -v "$b" >/dev/null 2>&1 || { echo "error: $b not found in PATH" >&2; return 1; }
  done
}

# Top N pods by memory request (sum of the pod's containers), with namespace and node.
toppods() {
  _k8s_need || return 1
  local n="${1:-20}"
  kubectl get pods -A --field-selector=status.phase=Running -o json | jq -r "$_K8S_JQ_DEFS"'
    .items[] | [.metadata.namespace, .metadata.name, (.spec.nodeName // "-"),
      ([.spec.containers[].resources.requests.memory | bytes] | add // 0)] | @tsv' \
  | sort -t$'\t' -k4 -nr | head -n "$n" \
  | awk -F'\t' 'BEGIN{printf "%-25s %-50s %-35s %10s\n","NAMESPACE","POD","NODE","MEM_REQ"}
                {printf "%-25s %-50s %-35s %7.0f Mi\n",$1,$2,$3,$4/1048576}'
}

# Memory requested per node, highest first.
nodemem() {
  _k8s_need || return 1
  kubectl get pods -A --field-selector=status.phase=Running -o json | jq -r "$_K8S_JQ_DEFS"'
    .items[] | [(.spec.nodeName // "-"),
      ([.spec.containers[].resources.requests.memory | bytes] | add // 0)] | @tsv' \
  | awk -F'\t' '{s[$1]+=$2} END{for(n in s) printf "%-40s %8.0f Mi\n",n,s[n]/1048576}' \
  | sort -k2 -nr
}

# Memory requested per namespace, with pod count and a cluster total.
nstotals() {
  _k8s_need || return 1
  kubectl get pods -A --field-selector=status.phase=Running -o json | jq -r "$_K8S_JQ_DEFS"'
    [.items[] | {ns: .metadata.namespace,
                 mem: ([.spec.containers[].resources.requests.memory | bytes] | add // 0)}]
    | group_by(.ns)
    | map({ns: .[0].ns, pods: length, mem: (map(.mem) | add)})
    | sort_by(-.mem)[]
    | [.ns, .pods, .mem] | @tsv' \
  | awk -F'\t' 'BEGIN{printf "%-30s %6s %12s\n","NAMESPACE","PODS","MEM_REQ"}
                {printf "%-30s %6d %9.0f Mi\n",$1,$2,$3/1048576; t+=$3}
                END{printf "%-30s %6s %9.0f Mi\n","TOTAL","",t/1048576}'
}

# Workloads in one namespace (pods traced through their ReplicaSet to the Deployment).
nsreq() {
  _k8s_need || return 1
  local ns="${1:?usage: nsreq <namespace> [mem|cpu]}"
  local sortkey="${2:-mem}"
  case "$sortkey" in mem|cpu) ;; *) echo "usage: nsreq <namespace> [mem|cpu]" >&2; return 1 ;; esac
  kubectl get pods,replicasets -n "$ns" -o json | jq -r --arg k "$sortkey" "$_K8S_JQ_DEFS"'
    .items as $all
    | ($all | map(select(.kind=="ReplicaSet"))
            | map({key: .metadata.name,
                   value: ((.metadata.ownerReferences // [])[0]
                           | if . then "\(.kind)/\(.name)" else null end)})
            | from_entries) as $rs
    | [$all[] | select(.kind=="Pod" and .status.phase=="Running")
        | ((.metadata.ownerReferences // [])[0]) as $o
        | {owner: (if $o == null then "Pod/\(.metadata.name)"
                   elif $o.kind=="ReplicaSet" then ($rs[$o.name] // "ReplicaSet/\($o.name)")
                   else "\($o.kind)/\($o.name)" end),
           mem: ([.spec.containers[].resources.requests.memory | bytes] | add // 0),
           cpu: ([.spec.containers[].resources.requests.cpu | millicores] | add // 0)}]
    | group_by(.owner)
    | map({owner: .[0].owner, pods: length,
           mem: (map(.mem) | add), cpu: (map(.cpu) | add)})
    | sort_by(-.[$k])[]
    | [.owner, .pods, .mem, .cpu] | @tsv' \
  | awk -F'\t' '
      BEGIN{printf "%-50s %5s %11s %11s %10s %10s\n","WORKLOAD","PODS","MEM/POD","MEM_TOTAL","CPU/POD","CPU_TOTAL"}
      {printf "%-50s %5d %8.0f Mi %8.0f Mi %8.0f m %8.0f m\n",
              $1,$2,($3/$2)/1048576,$3/1048576,$4/$2,$4; tm+=$3; tc+=$4}
      END{printf "%-50s %5s %11s %8.0f Mi %10s %8.0f m\n","TOTAL","","",tm/1048576,"",tc}'
}

# Pods spread over the nodes and each node's memory: allocatable, requested, limits, used; CPU requested %.
nodereport() {
  _k8s_need || return 1
  local ns="${1:-}"
  awk -F'\t' -v ns="$ns" '
    # 1st input: kubectl top nodes (actual usage, optional)
    FILENAME==ARGV[1] { split($0,a," "); use[a[1]]=a[5]; next }
    FNR==1 {
      printf "%-35s %5s %9s %9s %6s %9s %6s %6s %8s", "NODE","PODS","MEM_ALLOC","MEM_REQ","REQ%","MEM_LIM","LIM%","USE%","CPUREQ%"
      if (ns!="") printf " %8s %10s", "NS_PODS", "NS_MEMREQ"
      printf "\n"
    }
    {
      gi=1073741824
      lim=($3?$5/$3*100:0); flag=(lim>100)?"!":" "
      printf "%-35s %5d %7.1fGi %7.1fGi %5.0f%% %7.1fGi %5.0f%%%s %6s %7.0f%%",
             $1,$2,$3/gi,$4/gi,($3?$4/$3*100:0),$5/gi,lim,flag,(use[$1]?use[$1]:"n/a"),($6?$7/$6*100:0)
      if (ns!="") printf " %8d %8.1fGi", $8, $9/gi
      printf "\n"
      tp+=$2; ta+=$3; tr+=$4; tl+=$5; tnp+=$8; tnm+=$9
    }
    END {
      printf "%-35s %5d %7.1fGi %7.1fGi %5.0f%% %7.1fGi %5.0f%%", "TOTAL",tp,ta/gi,tr/gi,(ta?tr/ta*100:0),tl/gi,(ta?tl/ta*100:0)
      if (ns!="") printf "%17s %8d %8.1fGi", "", tnp, tnm/gi
      printf "\n"
    }' \
  <(kubectl top nodes --no-headers 2>/dev/null) \
  <(kubectl get nodes,pods -A -o json | jq -r --arg ns "$ns" "$_K8S_JQ_DEFS"'
    .items as $all
    | ($all | map(select(.kind=="Pod" and .status.phase=="Running" and .spec.nodeName != null))) as $pods
    | [ $all[] | select(.kind=="Node") | .metadata.name as $n
        | ($pods | map(select(.spec.nodeName==$n))) as $p
        | ($p | map(select(.metadata.namespace==$ns))) as $q
        | { node: $n, pods: ($p|length),
            alloc:  (.status.allocatable.memory | bytes),
            req:    ([$p[].spec.containers[].resources.requests.memory | bytes] | add // 0),
            lim:    ([$p[].spec.containers[].resources.limits.memory   | bytes] | add // 0),
            calloc: (.status.allocatable.cpu | millicores),
            creq:   ([$p[].spec.containers[].resources.requests.cpu | millicores] | add // 0),
            nspods: ($q|length),
            nsreq:  ([$q[].spec.containers[].resources.requests.memory | bytes] | add // 0) } ]
    | sort_by(-(if .alloc > 0 then .req/.alloc else 0 end))[]
    | [.node,.pods,.alloc,.req,.lim,.calloc,.creq,.nspods,.nsreq] | @tsv')
}
