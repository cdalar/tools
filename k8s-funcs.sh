# k8s-funcs.sh -- kubectl + jq resource reports
#
# Load into your current shell (don't execute it):
#   source ~/k8s-funcs.sh
# Load it in every new terminal:
#   echo '[ -f ~/k8s-funcs.sh ] && source ~/k8s-funcs.sh' >> ~/.bashrc   # or ~/.zshrc
#
# Functions (all read-only, current kubectl context, Running pods only). Type k-<TAB> to list them:
#   k-help                         this list
#   k-toppods [N] [mem|cpu]        top N pods by memory or CPU request, with node and % of that node (default 20, mem)
#   k-nodemem                      per node: pods, memory and CPU requested vs allocatable
#   k-nstotals [mem|cpu]           per namespace: pods, memory and CPU requested, % of cluster; cluster total last
#   k-nsreq <namespace> [mem|cpu]  workloads in a namespace: pods, memory and CPU per pod and in total, % of namespace
#   k-nodereport [namespace]       per node: pods, memory allocatable / requested / limits / used, CPU requested / used;
#                                  with a namespace, also that namespace's pods and memory request per node
#
# Requires: kubectl, jq, awk, bash or zsh. Usage in k-nodereport needs metrics-server ("n/a" without it).

# jq helpers: memory quantities -> bytes, CPU quantities -> millicores, per-pod request sums
_K8S_JQ_DEFS='
  def bytes: if . == null then 0 else
    capture("(?<n>[0-9.]+)(?<u>[A-Za-z]*)")
    | (.n|tonumber) * ({"":1,"k":1e3,"K":1e3,"M":1e6,"G":1e9,"T":1e12,
        "Ki":1024,"Mi":1048576,"Gi":1073741824,"Ti":1099511627776}[.u] // 1) end;
  def millicores: if . == null then 0
    elif endswith("m") then (.[:-1] | tonumber)
    else (tonumber * 1000) end;
  def podmem: [.spec.containers[].resources.requests.memory | bytes] | add // 0;
  def podcpu: [.spec.containers[].resources.requests.cpu | millicores] | add // 0;
'

_k8s_need() {
  local b
  for b in kubectl jq awk; do
    command -v "$b" >/dev/null 2>&1 || { echo "error: $b not found in PATH" >&2; return 1; }
  done
}

_k8s_sortkey() {
  case "${1:-mem}" in mem|cpu) echo "${1:-mem}" ;; *) echo "error: sort key must be mem or cpu" >&2; return 1 ;; esac
}

k-help() {
  cat <<'EOF'
k-toppods [N] [mem|cpu]        top N pods by memory or CPU request, with node and % of that node (default 20, mem)
k-nodemem                      per node: pods, memory and CPU requested vs allocatable
k-nstotals [mem|cpu]           per namespace: pods, memory and CPU requested, % of cluster; cluster total last
k-nsreq <namespace> [mem|cpu]  workloads in a namespace: pods, memory and CPU per pod and in total, % of namespace
k-nodereport [namespace]       per node: memory alloc/requested/limits/used, CPU requested/used (+ namespace share)
EOF
}

# Top N pods by memory or CPU request (sum of the pod's containers), with namespace, node and % of the node.
k-toppods() {
  _k8s_need || return 1
  local n="${1:-20}" k col
  k="$(_k8s_sortkey "${2:-mem}")" || return 1
  [ "$k" = cpu ] && col=5 || col=4
  kubectl get nodes,pods -A -o json | jq -r "$_K8S_JQ_DEFS"'
    .items as $all
    | ($all | map(select(.kind=="Node"))
            | map({key: .metadata.name,
                   value: {mem: (.status.allocatable.memory | bytes),
                           cpu: (.status.allocatable.cpu | millicores)}})
            | from_entries) as $nodes
    | $all[] | select(.kind=="Pod" and .status.phase=="Running")
    | (.spec.nodeName // "-") as $n
    | [.metadata.namespace, .metadata.name, $n, podmem, podcpu,
       ($nodes[$n].mem // 0), ($nodes[$n].cpu // 0)] | @tsv' \
  | sort -t$'\t' -k"$col" -nr | head -n "$n" \
  | awk -F'\t' 'BEGIN{printf "%-25s %-50s %-35s %10s %6s %10s %6s\n","NAMESPACE","POD","NODE","MEM_REQ","NODE%","CPU_REQ","NODE%"}
                {printf "%-25s %-50s %-35s %7.0f Mi %5.1f%% %8.0f m %5.1f%%\n",
                        $1,$2,$3,$4/1048576,($6?$4/$6*100:0),$5,($7?$5/$7*100:0)}'
}

# Per node: pods, memory and CPU requested vs allocatable, highest memory % first.
k-nodemem() {
  _k8s_need || return 1
  kubectl get nodes,pods -A -o json | jq -r "$_K8S_JQ_DEFS"'
    .items as $all
    | ($all | map(select(.kind=="Pod" and .status.phase=="Running" and .spec.nodeName != null))) as $pods
    | [ $all[] | select(.kind=="Node") | .metadata.name as $n
        | ($pods | map(select(.spec.nodeName==$n))) as $p
        | { node: $n, pods: ($p|length),
            mem: ([$p[] | podmem] | add // 0), malloc: (.status.allocatable.memory | bytes),
            cpu: ([$p[] | podcpu] | add // 0), calloc: (.status.allocatable.cpu | millicores) } ]
    | sort_by(-(if .malloc > 0 then .mem/.malloc else 0 end))[]
    | [.node,.pods,.mem,.malloc,.cpu,.calloc] | @tsv' \
  | awk -F'\t' '
      BEGIN{printf "%-40s %5s %10s %10s %6s %10s %10s %6s\n","NODE","PODS","MEM_REQ","MEM_ALLOC","MEM%","CPU_REQ","CPU_ALLOC","CPU%"}
      {printf "%-40s %5d %7.0f Mi %7.0f Mi %5.0f%% %8.0f m %8.0f m %5.0f%%\n",
              $1,$2,$3/1048576,$4/1048576,($4?$3/$4*100:0),$5,$6,($6?$5/$6*100:0)
       tp+=$2; tm+=$3; ta+=$4; tc+=$5; tca+=$6}
      END{printf "%-40s %5d %7.0f Mi %7.0f Mi %5.0f%% %8.0f m %8.0f m %5.0f%%\n",
              "TOTAL",tp,tm/1048576,ta/1048576,(ta?tm/ta*100:0),tc,tca,(tca?tc/tca*100:0)}'
}

# Per namespace: pods, memory and CPU requested, as % of the cluster's allocatable; cluster total last.
k-nstotals() {
  _k8s_need || return 1
  local k
  k="$(_k8s_sortkey "${1:-mem}")" || return 1
  kubectl get nodes,pods -A -o json | jq -r --arg k "$k" "$_K8S_JQ_DEFS"'
    .items as $all
    | ([$all[] | select(.kind=="Node") | .status.allocatable.memory | bytes] | add // 0) as $malloc
    | ([$all[] | select(.kind=="Node") | .status.allocatable.cpu | millicores] | add // 0) as $calloc
    | [$all[] | select(.kind=="Pod" and .status.phase=="Running")
        | {ns: .metadata.namespace, mem: podmem, cpu: podcpu}]
    | group_by(.ns)
    | map({ns: .[0].ns, pods: length, mem: (map(.mem) | add), cpu: (map(.cpu) | add)})
    | sort_by(-.[$k])[]
    | [.ns, .pods, .mem, .cpu, $malloc, $calloc] | @tsv' \
  | awk -F'\t' '
      BEGIN{printf "%-30s %6s %12s %6s %11s %6s\n","NAMESPACE","PODS","MEM_REQ","MEM%","CPU_REQ","CPU%"}
      {printf "%-30s %6d %9.0f Mi %5.1f%% %9.0f m %5.1f%%\n",
              $1,$2,$3/1048576,($5?$3/$5*100:0),$4,($6?$4/$6*100:0)
       tp+=$2; tm+=$3; tc+=$4; ma=$5; ca=$6}
      END{printf "%-30s %6d %9.0f Mi %5.1f%% %9.0f m %5.1f%%\n",
              "TOTAL",tp,tm/1048576,(ma?tm/ma*100:0),tc,(ca?tc/ca*100:0)
          printf "%-30s %6s %9.0f Mi %6s %9.0f m\n","CLUSTER ALLOCATABLE","",ma/1048576,"",ca}'
}

# Workloads in one namespace (pods traced through their ReplicaSet to the Deployment), % of the namespace total.
k-nsreq() {
  _k8s_need || return 1
  local ns="${1:?usage: k-nsreq <namespace> [mem|cpu]}" k
  k="$(_k8s_sortkey "${2:-mem}")" || return 1
  kubectl get pods,replicasets -n "$ns" -o json | jq -r --arg k "$k" "$_K8S_JQ_DEFS"'
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
           mem: podmem, cpu: podcpu}]
    | (map(.mem) | add // 0) as $tm
    | (map(.cpu) | add // 0) as $tc
    | group_by(.owner)
    | map({owner: .[0].owner, pods: length,
           mem: (map(.mem) | add), cpu: (map(.cpu) | add)})
    | sort_by(-.[$k])[]
    | [.owner, .pods, .mem, .cpu, $tm, $tc] | @tsv' \
  | awk -F'\t' '
      BEGIN{printf "%-50s %5s %11s %11s %6s %10s %10s %6s\n","WORKLOAD","PODS","MEM/POD","MEM_TOTAL","MEM%","CPU/POD","CPU_TOTAL","CPU%"}
      {printf "%-50s %5d %8.0f Mi %8.0f Mi %5.1f%% %8.0f m %8.0f m %5.1f%%\n",
              $1,$2,($3/$2)/1048576,$3/1048576,($5?$3/$5*100:0),$4/$2,$4,($6?$4/$6*100:0)
       tp+=$2; tm+=$3; tc+=$4}
      END{printf "%-50s %5d %11s %8.0f Mi %6s %10s %8.0f m\n","TOTAL",tp,"",tm/1048576,"","",tc}'
}

# Pods spread over the nodes and each node's memory: allocatable, requested, limits, used; CPU requested and used.
k-nodereport() {
  _k8s_need || return 1
  local ns="${1:-}"
  awk -F'\t' -v ns="$ns" '
    # 1st input: kubectl top nodes (actual usage, optional): NAME CPU(cores) CPU% MEMORY(bytes) MEMORY%
    FILENAME==ARGV[1] { split($0,a," "); cuse[a[1]]=a[3]; muse[a[1]]=a[5]; next }
    FNR==1 {
      printf "%-35s %5s %9s %9s %6s %9s %6s %7s %8s %8s", "NODE","PODS","MEM_ALLOC","MEM_REQ","REQ%","MEM_LIM","LIM%","MEMUSE%","CPUREQ%","CPUUSE%"
      if (ns!="") printf " %8s %10s", "NS_PODS", "NS_MEMREQ"
      printf "\n"
    }
    {
      gi=1073741824
      lim=($3?$5/$3*100:0); flag=(lim>100)?"!":" "
      printf "%-35s %5d %7.1fGi %7.1fGi %5.0f%% %7.1fGi %5.0f%%%s %7s %7.0f%% %8s",
             $1,$2,$3/gi,$4/gi,($3?$4/$3*100:0),$5/gi,lim,flag,(muse[$1]?muse[$1]:"n/a"),
             ($6?$7/$6*100:0),(cuse[$1]?cuse[$1]:"n/a")
      if (ns!="") printf " %8d %8.1fGi", $8, $9/gi
      printf "\n"
      tp+=$2; ta+=$3; tr+=$4; tl+=$5; tca+=$6; tcr+=$7; tnp+=$8; tnm+=$9
    }
    END {
      printf "%-35s %5d %7.1fGi %7.1fGi %5.0f%% %7.1fGi %5.0f%%  %7s %7.0f%% %8s", "TOTAL",tp,ta/gi,tr/gi,(ta?tr/ta*100:0),
             tl/gi,(ta?tl/ta*100:0),"",(tca?tcr/tca*100:0),""
      if (ns!="") printf " %8d %8.1fGi", tnp, tnm/gi
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
            req:    ([$p[] | podmem] | add // 0),
            lim:    ([$p[].spec.containers[].resources.limits.memory | bytes] | add // 0),
            calloc: (.status.allocatable.cpu | millicores),
            creq:   ([$p[] | podcpu] | add // 0),
            nspods: ($q|length),
            nsreq:  ([$q[] | podmem] | add // 0) } ]
    | sort_by(-(if .alloc > 0 then .req/.alloc else 0 end))[]
    | [.node,.pods,.alloc,.req,.lim,.calloc,.creq,.nspods,.nsreq] | @tsv')
}
