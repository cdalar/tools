# k8s-funcs.sh -- kubectl + jq resource reports
#
# Load into your current shell (don't execute it):
#   source ~/k8s-funcs.sh
# Load it in every new terminal:
#   echo '[ -f ~/k8s-funcs.sh ] && source ~/k8s-funcs.sh' >> ~/.bashrc   # or ~/.zshrc
#
# Functions (all read-only, current kubectl context, Running pods only). Type k-<TAB> to list them:
#   k-help                         this list
#   k-toppods [N] [key]            top N pods by request or limit, with node and % of that node (default 20, mem)
#   k-nodemem                      per node: pods, memory and CPU requests and limits vs allocatable
#   k-nstotals [key]               per namespace: pods, memory and CPU requests and limits, % of cluster; total last
#   k-nsreq <namespace> [key]      workloads in a namespace: pods, requests per pod and in total (% of namespace), limits per pod
#   k-nodereport [namespace]       per node: pods, memory allocatable / requested / limits / used, CPU requested / limits / used;
#                                  with a namespace, also that namespace's pods and memory request per node
#   k-serve [port]                 live dashboard in the browser (charts, tables; default port 8080), served from this pod;
#                                  prints the Rancher URL that reaches it through the API server's pod proxy
# key (sort order): mem | cpu | memlim | cpulim
#
# Limits are summed over containers that set one; a container without a limit counts as 0 (and "-" means none set).
# LIM% over 100 is flagged with "!" (limits overcommit the allocatable capacity).
# Unschedulable nodes (cordoned, or tainted NoSchedule/NoExecute, e.g. control plane) are marked "*" and left out
# of node TOTALs; k-nstotals counts only schedulable nodes and the pods on them.
#
# Requires: kubectl, jq, awk, bash or zsh. Usage in k-nodereport needs metrics-server ("n/a" without it).
# k-serve needs perl and bash (both in the Rancher shell image) and the pods/proxy permission to open the URL.

# jq helpers: memory quantities -> bytes, CPU quantities -> millicores, per-pod request and limit sums
_K8S_JQ_DEFS='
  def bytes: if . == null then 0 else
    capture("(?<n>[0-9.]+)(?<u>[A-Za-z]*)")
    | (.n|tonumber) * ({"":1,"k":1e3,"K":1e3,"M":1e6,"G":1e9,"T":1e12,
        "Ki":1024,"Mi":1048576,"Gi":1073741824,"Ti":1099511627776}[.u] // 1) end;
  def millicores: if . == null then 0
    elif endswith("m") then (.[:-1] | tonumber)
    else (tonumber * 1000) end;
  def podmem:    [.spec.containers[].resources.requests.memory | bytes] | add // 0;
  def podcpu:    [.spec.containers[].resources.requests.cpu | millicores] | add // 0;
  def podmemlim: [.spec.containers[].resources.limits.memory | bytes] | add // 0;
  def podcpulim: [.spec.containers[].resources.limits.cpu | millicores] | add // 0;
  def schedulable: (.spec.unschedulable // false | not)
    and ([.spec.taints[]? | select(.effect=="NoSchedule" or .effect=="NoExecute")] | length == 0);
'

# awk helpers: Mi / millicores, or "-" when zero (no limit set); percentage with "!" over 100
_K8S_AWK_DEFS='
  function mi(b) { return b ? sprintf("%.0f Mi", b/1048576) : "-" }
  function mc(m) { return m ? sprintf("%.0f m", m) : "-" }
  function pct(v, of,   p) { if (!v || !of) return "-"; p = v/of*100; return sprintf("%.0f%%%s", p, p > 100 ? "!" : "") }
'

_k8s_need() {
  local b
  for b in kubectl jq awk; do
    command -v "$b" >/dev/null 2>&1 || { echo "error: $b not found in PATH" >&2; return 1; }
  done
}

_k8s_sortkey() {
  case "${1:-mem}" in mem|cpu|memlim|cpulim) echo "${1:-mem}" ;;
    *) echo "error: sort key must be mem, cpu, memlim or cpulim" >&2; return 1 ;; esac
}

k-help() {
  cat <<'EOF'
k-toppods [N] [key]            top N pods by request or limit, with node and % of that node (default 20, mem)
k-nodemem                      per node: memory and CPU requests and limits vs allocatable
k-nstotals [key]               per namespace: memory and CPU requests and limits, % of cluster; cluster total last
k-nsreq <namespace> [key]      workloads in a namespace: requests per pod and in total (% of namespace), limits per pod
k-nodereport [namespace]       per node: memory alloc/requested/limits/used, CPU requested/limits/used (+ namespace share)
key (sort order): mem | cpu | memlim | cpulim
* = unschedulable node (cordoned / NoSchedule / NoExecute), left out of totals
k-serve [port]                 live dashboard in the browser (default 8080); prints its Rancher proxy URL
EOF
}

# Top N pods by request or limit (sum of the pod's containers), with namespace, node and % of the node.
k-toppods() {
  _k8s_need || return 1
  local n="${1:-20}" k col
  k="$(_k8s_sortkey "${2:-mem}")" || return 1
  case "$k" in mem) col=4 ;; cpu) col=5 ;; memlim) col=6 ;; cpulim) col=7 ;; esac
  kubectl get nodes,pods -A -o json | jq -r "$_K8S_JQ_DEFS"'
    .items as $all
    | ($all | map(select(.kind=="Node"))
            | map({key: .metadata.name,
                   value: {mem: (.status.allocatable.memory | bytes),
                           cpu: (.status.allocatable.cpu | millicores)}})
            | from_entries) as $nodes
    | $all[] | select(.kind=="Pod" and .status.phase=="Running")
    | (.spec.nodeName // "-") as $n
    | [.metadata.namespace, .metadata.name, $n, podmem, podcpu, podmemlim, podcpulim,
       ($nodes[$n].mem // 0), ($nodes[$n].cpu // 0)] | @tsv' \
  | sort -t$'\t' -k"$col" -nr | head -n "$n" \
  | awk -F'\t' "$_K8S_AWK_DEFS"'
      BEGIN{printf "%-25s %-50s %-35s %10s %6s %10s %6s %10s %6s %10s %6s\n",
                   "NAMESPACE","POD","NODE","MEM_REQ","NODE%","MEM_LIM","NODE%","CPU_REQ","NODE%","CPU_LIM","NODE%"}
      {printf "%-25s %-50s %-35s %10s %6s %10s %6s %10s %6s %10s %6s\n",
              $1,$2,$3,mi($4),pct($4,$8),mi($6),pct($6,$8),mc($5),pct($5,$9),mc($7),pct($7,$9)}'
}

# Per node: pods, memory and CPU requests and limits vs allocatable, highest memory request % first.
k-nodemem() {
  _k8s_need || return 1
  kubectl get nodes,pods -A -o json | jq -r "$_K8S_JQ_DEFS"'
    .items as $all
    | ($all | map(select(.kind=="Pod" and .status.phase=="Running" and .spec.nodeName != null))) as $pods
    | [ $all[] | select(.kind=="Node") | .metadata.name as $n
        | ($pods | map(select(.spec.nodeName==$n))) as $p
        | { node: $n, pods: ($p|length),
            mem: ([$p[] | podmem] | add // 0), mlim: ([$p[] | podmemlim] | add // 0),
            malloc: (.status.allocatable.memory | bytes),
            cpu: ([$p[] | podcpu] | add // 0), clim: ([$p[] | podcpulim] | add // 0),
            calloc: (.status.allocatable.cpu | millicores),
            sched: (if schedulable then 1 else 0 end) } ]
    | sort_by(-.sched, -(if .malloc > 0 then .mem/.malloc else 0 end))[]
    | [.node,.pods,.mem,.mlim,.malloc,.cpu,.clim,.calloc,.sched] | @tsv' \
  | awk -F'\t' "$_K8S_AWK_DEFS"'
      function row(name, p, m, ml, ma, c, cl, ca) {
        printf "%-40s %5d %10s %10s %10s %6s %6s %10s %10s %10s %6s %6s\n",
               name, p, mi(m), mi(ml), mi(ma), pct(m,ma), pct(ml,ma), mc(c), mc(cl), mc(ca), pct(c,ca), pct(cl,ca)
      }
      BEGIN{printf "%-40s %5s %10s %10s %10s %6s %6s %10s %10s %10s %6s %6s\n",
                   "NODE","PODS","MEM_REQ","MEM_LIM","MEM_ALLOC","REQ%","LIM%","CPU_REQ","CPU_LIM","CPU_ALLOC","REQ%","LIM%"}
      {row($1 ($9 ? "" : "*"),$2,$3,$4,$5,$6,$7,$8)
       if (!$9) { nx++; next }
       tp+=$2; tm+=$3; tml+=$4; ta+=$5; tc+=$6; tcl+=$7; tca+=$8; ns_++
       if ($5 > bigm) bigm=$5; if ($8 > bigc) bigc=$8}
      END{row("TOTAL",tp,tm,tml,ta,tc,tcl,tca)
          if (nx) printf "* not schedulable (cordoned or NoSchedule/NoExecute taint), not in TOTAL: %d node(s)\n", nx
          # N+1: what is left if the largest schedulable node fails, against everything requested on schedulable nodes
          if (ns_ < 2) { print "N+1: only one schedulable node, nothing survives a node failure"; exit }
          printf "N+1 (largest node fails): memory %s left for %s requested (%s), CPU %s left for %s requested (%s)\n",
                 mi(ta-bigm), mi(tm), (tm <= ta-bigm ? "fits" : "short by " mi(tm-(ta-bigm))),
                 mc(tca-bigc), mc(tc), (tc <= tca-bigc ? "fits" : "short by " mc(tc-(tca-bigc)))}'
}

# Per namespace: pods, memory and CPU requests and limits, as % of the cluster's allocatable; cluster total last.
k-nstotals() {
  _k8s_need || return 1
  local k
  k="$(_k8s_sortkey "${1:-mem}")" || return 1
  kubectl get nodes,pods -A -o json | jq -r --arg k "$k" "$_K8S_JQ_DEFS"'
    .items as $all
    | [$all[] | select(.kind=="Node")] as $nodes
    | ($nodes | map(select(schedulable))) as $ok
    | ($ok | map({key: .metadata.name, value: true}) | from_entries) as $okname
    | ([$ok[] | .status.allocatable.memory | bytes] | add // 0) as $malloc
    | ([$ok[] | .status.allocatable.cpu | millicores] | add // 0) as $calloc
    | [$all[] | select(.kind=="Pod" and .status.phase=="Running")] as $running
    | ($running | map(select($okname[.spec.nodeName // ""]))) as $pods
    | (($nodes|length) - ($ok|length)) as $nx
    | (($running|length) - ($pods|length)) as $px
    | [$pods[] | {ns: .metadata.namespace, mem: podmem, cpu: podcpu, memlim: podmemlim, cpulim: podcpulim}]
    | group_by(.ns)
    | map({ns: .[0].ns, pods: length, mem: (map(.mem) | add), cpu: (map(.cpu) | add),
           memlim: (map(.memlim) | add), cpulim: (map(.cpulim) | add)})
    | sort_by(-.[$k])[]
    | [.ns, .pods, .mem, .memlim, .cpu, .cpulim, $malloc, $calloc, $nx, $px] | @tsv' \
  | awk -F'\t' "$_K8S_AWK_DEFS"'
      function row(name, p, m, ml, c, cl, ma, ca) {
        printf "%-30s %6s %10s %6s %10s %6s %10s %6s %10s %6s\n",
               name, p, mi(m), pct(m,ma), mi(ml), pct(ml,ma), mc(c), pct(c,ca), mc(cl), pct(cl,ca)
      }
      BEGIN{printf "%-30s %6s %10s %6s %10s %6s %10s %6s %10s %6s\n",
                   "NAMESPACE","PODS","MEM_REQ","MEM%","MEM_LIM","LIM%","CPU_REQ","CPU%","CPU_LIM","LIM%"}
      {row($1,$2,$3,$4,$5,$6,$7,$8); tp+=$2; tm+=$3; tml+=$4; tc+=$5; tcl+=$6; ma=$7; ca=$8; nx=$9; px=$10}
      END{row("TOTAL",tp,tm,tml,tc,tcl,ma,ca)
          printf "%-30s %6s %10s %6s %10s %6s %10s\n","SCHEDULABLE ALLOCATABLE","",mi(ma),"","","",mc(ca)
          if (nx) printf "not counted: %d unschedulable node(s) (cordoned or NoSchedule/NoExecute taint) and their %d pod(s)\n", nx, px}'
}

# Workloads in one namespace (pods traced through their ReplicaSet to the Deployment), % of the namespace total.
k-nsreq() {
  _k8s_need || return 1
  local ns="${1:?usage: k-nsreq <namespace> [mem|cpu|memlim|cpulim]}" k
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
           mem: podmem, cpu: podcpu, memlim: podmemlim, cpulim: podcpulim}]
    | (map(.mem) | add // 0) as $tm
    | (map(.cpu) | add // 0) as $tc
    | group_by(.owner)
    | map({owner: .[0].owner, pods: length,
           mem: (map(.mem) | add), cpu: (map(.cpu) | add),
           memlim: (map(.memlim) | add), cpulim: (map(.cpulim) | add)})
    | sort_by(-.[$k])[]
    | [.owner, .pods, .mem, .cpu, .memlim, .cpulim, $tm, $tc] | @tsv' \
  | awk -F'\t' "$_K8S_AWK_DEFS"'
      BEGIN{printf "%-50s %5s %10s %10s %6s %10s %10s %10s %6s %10s\n",
                   "WORKLOAD","PODS","MEM/POD","MEM_TOTAL","MEM%","MEMLIM/POD","CPU/POD","CPU_TOTAL","CPU%","CPULIM/POD"}
      {printf "%-50s %5d %10s %10s %6s %10s %10s %10s %6s %10s\n",
              $1,$2,mi($3/$2),mi($3),pct($3,$7),mi($5/$2),mc($4/$2),mc($4),pct($4,$8),mc($6/$2)
       tp+=$2; tm+=$3; tc+=$4}
      END{printf "%-50s %5d %10s %10s %6s %10s %10s %10s\n","TOTAL",tp,"",mi(tm),"","","",mc(tc)}'
}

# Pods spread over the nodes and each node's memory: allocatable, requested, limits, used; CPU requested, limits, used.
k-nodereport() {
  _k8s_need || return 1
  local ns="${1:-}"
  awk -F'\t' -v ns="$ns" '
    # 1st input: kubectl top nodes (actual usage, optional): NAME CPU(cores) CPU% MEMORY(bytes) MEMORY%
    FILENAME==ARGV[1] { split($0,a," "); cuse[a[1]]=a[3]; muse[a[1]]=a[5]; next }
    FNR==1 {
      printf "%-35s %5s %9s %9s %6s %9s %6s %7s %8s %8s %8s", "NODE","PODS","MEM_ALLOC","MEM_REQ","REQ%","MEM_LIM","LIM%","MEMUSE%","CPUREQ%","CPULIM%","CPUUSE%"
      if (ns!="") printf " %8s %10s", "NS_PODS", "NS_MEMREQ"
      printf "\n"
    }
    {
      gi=1073741824
      lim=($3?$5/$3*100:0); flag=(lim>100)?"!":" "
      clim=($6?$8/$6*100:0); cflag=(clim>100)?"!":" "
      printf "%-35s %5d %7.1fGi %7.1fGi %5.0f%% %7.1fGi %5.0f%%%s %7s %7.0f%% %7.0f%%%s %7s",
             $1 ($11 ? "" : "*"),$2,$3/gi,$4/gi,($3?$4/$3*100:0),$5/gi,lim,flag,(muse[$1]?muse[$1]:"n/a"),
             ($6?$7/$6*100:0),clim,cflag,(cuse[$1]?cuse[$1]:"n/a")
      if (ns!="") printf " %8d %8.1fGi", $9, $10/gi
      printf "\n"
      if (!$11) { nx++; next }
      tp+=$2; ta+=$3; tr+=$4; tl+=$5; tca+=$6; tcr+=$7; tcl+=$8; tnp+=$9; tnm+=$10
    }
    END {
      printf "%-35s %5d %7.1fGi %7.1fGi %5.0f%% %7.1fGi %5.0f%%  %7s %7.0f%% %7.0f%%  %7s", "TOTAL",tp,ta/gi,tr/gi,(ta?tr/ta*100:0),
             tl/gi,(ta?tl/ta*100:0),"",(tca?tcr/tca*100:0),(tca?tcl/tca*100:0),""
      if (ns!="") printf " %8d %8.1fGi", tnp, tnm/gi
      printf "\n"
      if (nx) printf "* not schedulable (cordoned or NoSchedule/NoExecute taint), not in TOTAL: %d node(s)\n", nx
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
            lim:    ([$p[] | podmemlim] | add // 0),
            calloc: (.status.allocatable.cpu | millicores),
            creq:   ([$p[] | podcpu] | add // 0),
            clim:   ([$p[] | podcpulim] | add // 0),
            nspods: ($q|length),
            nsreq:  ([$q[] | podmem] | add // 0),
            sched:  (if schedulable then 1 else 0 end) } ]
    | sort_by(-.sched, -(if .alloc > 0 then .req/.alloc else 0 end))[]
    | [.node,.pods,.alloc,.req,.lim,.calloc,.creq,.clim,.nspods,.nsreq,.sched] | @tsv')
}


# ---------- k-serve: live dashboard in the browser through the Rancher pod proxy ----------

# jq for k-serve's api/data: nodes and pods (Running and Pending) with requests, limits and metrics-server usage.
# Input: kubectl get nodes,pods -A -o json; $topn / $topp: kubectl top nodes / pods -A --no-headers.
_K8S_DASH_JQ='
  ($topn | split("\n") | map(select(length > 0) | [splits(" +")])
         | map({key: .[0], value: {cpu: (.[1] | millicores), mem: (.[3] | bytes)}}) | from_entries) as $un
  | ($topp | split("\n") | map(select(length > 0) | [splits(" +")])
         | map({key: "\(.[0])/\(.[1])", value: {cpu: (.[2] | millicores), mem: (.[3] | bytes)}}) | from_entries) as $up
  | [.items[] | select(.kind == "Pod" and (.status.phase == "Running" or .status.phase == "Pending"))
      | "\(.metadata.namespace)/\(.metadata.name)" as $k
      | {ns: .metadata.namespace, name: .metadata.name, node: (.spec.nodeName // ""), phase: .status.phase,
         owner: ((.metadata.ownerReferences // [])[0] | if . then "\(.kind)/\(.name)" else "" end),
         cpu_req: podcpu, cpu_lim: podcpulim, mem_req: podmem, mem_lim: podmemlim,
         cpu_used: ($up[$k].cpu // null), mem_used: ($up[$k].mem // null),
         containers: (.spec.containers | length),
         no_cpu_req: ([.spec.containers[] | select(.resources.requests.cpu == null)] | length),
         no_mem_lim: ([.spec.containers[] | select(.resources.limits.memory == null)] | length)}] as $pods
  | {collected_at: (now | todate), cluster: $cluster, metrics: ($un | length > 0), pods: $pods,
     nodes: [.items[] | select(.kind == "Node") | .metadata.name as $n
       | ($pods | map(select(.node == $n and .phase == "Running"))) as $p
       | {name: $n, sched: schedulable,
          ready: ([.status.conditions[]? | select(.type == "Ready") | .status == "True"] | any),
          roles: ([(.metadata.labels // {}) | keys[] | select(startswith("node-role.kubernetes.io/"))
                   | ltrimstr("node-role.kubernetes.io/")] | join(",")),
          cpu_alloc: (.status.allocatable.cpu | millicores), mem_alloc: (.status.allocatable.memory | bytes),
          pod_cap: (.status.allocatable.pods // "0" | tonumber), pods: ($p | length),
          cpu_req: ([$p[].cpu_req] | add // 0), cpu_lim: ([$p[].cpu_lim] | add // 0),
          mem_req: ([$p[].mem_req] | add // 0), mem_lim: ([$p[].mem_lim] | add // 0),
          cpu_used: ($un[$n].cpu // null), mem_used: ($un[$n].mem // null)}]}
'

# bash, run by the k-serve server for each api/data request (the env carries the jq program and cluster id)
_K8S_SERVE_COLLECT='
set -o pipefail
t="$K_SERVE_DIR"
kubectl top nodes --no-headers > "$t/topn" 2>/dev/null || : > "$t/topn"
kubectl top pods -A --no-headers > "$t/topp" 2>/dev/null || : > "$t/topp"
kubectl get nodes,pods -A -o json \
  | jq -c --rawfile topn "$t/topn" --rawfile topp "$t/topp" --arg cluster "$K_SERVE_CLUSTER" "$K_SERVE_JQ"
'

# HTTP server for k-serve: GET / (the dashboard page) and GET api/data (collector output, cached 10 s;
# ?fresh=1 skips the cache). Nothing else; it never serves files from disk.
_K8S_SERVE_PL='
use strict; use warnings; use IO::Socket::INET;
my ($port, $dir) = @ARGV;
$SIG{PIPE} = "IGNORE";
open my $fh, "<", "$dir/index.html" or die "k-serve: $dir/index.html: $!\n";
my $page = do { local $/; <$fh> };
close $fh;
my $srv = IO::Socket::INET->new(LocalAddr => "0.0.0.0", LocalPort => $port, Listen => 16, ReuseAddr => 1, Proto => "tcp")
  or die "k-serve: cannot listen on port $port: $!\n";
my ($cache, $cached_at) = ("", 0);
sub reply {
  my ($c, $code, $type, $body) = @_;
  print $c "HTTP/1.0 $code\r\nContent-Type: $type\r\nContent-Length: " . length($body)
         . "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n$body";
}
sub collect {
  my $out = qx{bash -c "\$K_SERVE_COLLECT" 2>"$dir/err"};
  return (1, $out) if $? == 0 and $out =~ /^\{/;
  open my $e, "<", "$dir/err"; my $err = $e ? do { local $/; <$e> } // "" : ""; close $e if $e;
  $err =~ s/[\\"]/\\$&/g; $err =~ s/[\r\n\t]+/ /g;
  return (0, "{\"error\":\"collection failed: $err\"}");
}
sub handle {
  my $c = shift;
  binmode $c;
  my $req = <$c> // return;
  while (my $h = <$c>) { last if $h =~ /^\r?\n$/ }
  my ($m, $uri) = $req =~ m{^(\S+)\s+(\S+)} or return reply($c, "400 Bad Request", "text/plain", "bad request\n");
  return reply($c, "405 Method Not Allowed", "text/plain", "GET only\n") unless $m eq "GET";
  my ($path, $query) = split /\?/, $uri, 2;
  print STDERR scalar(localtime), " $m $uri\n";
  return reply($c, "200 OK", "text/html; charset=utf-8", $page) if $path eq "/" or $path eq "/index.html";
  if ($path eq "/api/data") {
    if (time - $cached_at > 10 or ($query // "") =~ /fresh=1/) {
      my ($ok, $out) = collect();
      return reply($c, "500 Internal Server Error", "application/json", $out) unless $ok;
      ($cache, $cached_at) = ($out, time);
    }
    return reply($c, "200 OK", "application/json", $cache);
  }
  reply($c, "404 Not Found", "text/plain", "not found\n");
}
while (my $c = $srv->accept) {
  eval { local $SIG{ALRM} = sub { die "timeout\n" }; alarm 180; handle($c); alarm 0; };
  alarm 0;
  print STDERR "k-serve: $@" if $@;
  close $c;
}
'

# The dashboard page: self-contained (no CDN), light/dark, same look as the cluster resource report.
_k8s_dash_html() {
  cat <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cluster Resources</title>
<style>
:root {
  color-scheme: light;
  --page: #f9f9f7; --surface-1: #fcfcfb; --text-primary: #0b0b0b; --text-secondary: #52514e; --text-muted: #898781;
  --grid: #e1e0d9; --axis: #c3c2b7; --border: rgba(11,11,11,0.10); --track: #efeee9;
  --series-1: #2a78d6; --series-2: #eb6834; --series-3: #1baf7a;
  --status-good: #0ca30c; --status-warning: #fab219; --status-serious: #ec835a; --status-critical: #d03b3b;
  --accent-ink: #1c5cab; --hover: rgba(11,11,11,0.04);
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --page: #0d0d0d; --surface-1: #1a1a19; --text-primary: #ffffff; --text-secondary: #c3c2b7; --text-muted: #898781;
    --grid: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10); --track: #262624;
    --series-1: #3987e5; --series-2: #d95926; --series-3: #199e70; --accent-ink: #86b6ef; --hover: rgba(255,255,255,0.05);
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --page: #0d0d0d; --surface-1: #1a1a19; --text-primary: #ffffff; --text-secondary: #c3c2b7; --text-muted: #898781;
  --grid: #2c2c2a; --axis: #383835; --border: rgba(255,255,255,0.10); --track: #262624;
  --series-1: #3987e5; --series-2: #d95926; --series-3: #199e70; --accent-ink: #86b6ef; --hover: rgba(255,255,255,0.05);
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--page); color: var(--text-primary); font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
.wrap { max-width: 1280px; margin: 0 auto; padding: 20px 16px 48px; }
header { display: flex; flex-wrap: wrap; gap: 12px 24px; align-items: flex-end; justify-content: space-between; margin-bottom: 16px; }
h1 { font-size: 20px; margin: 0; font-weight: 600; }
h2 { font-size: 15px; margin: 0 0 2px; font-weight: 600; }
.sub { color: var(--text-secondary); font-size: 13px; }
.muted { color: var(--text-muted); }
.actions { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
button, input[type=search] { font: inherit; color: var(--text-primary); background: var(--surface-1); border: 1px solid var(--border); border-radius: 6px; padding: 6px 10px; }
button { cursor: pointer; }
button:hover { background: var(--hover); }
button:disabled { opacity: .5; cursor: default; }
.card { background: var(--surface-1); border: 1px solid var(--border); border-radius: 10px; padding: 16px; min-width: 0; }
.banner { display: flex; gap: 8px; align-items: flex-start; padding: 10px 12px; border-radius: 8px; border: 1px solid var(--border); background: var(--surface-1); margin-bottom: 12px; font-size: 13px; }
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(160px, 100%), 1fr)); gap: 12px; margin-bottom: 16px; }
.tile .label { color: var(--text-secondary); font-size: 13px; }
.tile .value { font-size: 26px; font-weight: 600; margin-top: 2px; }
.tile .unit { font-size: 14px; font-weight: 400; color: var(--text-secondary); }
.tile .note { font-size: 12px; color: var(--text-muted); margin-top: 2px; }
.grid2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(420px, 100%), 1fr)); gap: 16px; margin-bottom: 16px; }
.section { margin-bottom: 16px; }
.section-head { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: baseline; gap: 8px; margin-bottom: 10px; }
.legend { display: flex; flex-wrap: wrap; gap: 14px; font-size: 12px; color: var(--text-secondary); }
.legend span { display: inline-flex; align-items: center; gap: 6px; }
.sw { width: 10px; height: 10px; border-radius: 2px; display: inline-block; }
.filters { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin: 8px 0 16px; }
.chip { display: inline-flex; gap: 6px; align-items: center; border: 1px solid var(--border); border-radius: 999px; padding: 4px 10px; background: var(--surface-1); cursor: pointer; user-select: none; font-size: 13px; }
.chip input { margin: 0; }
svg { display: block; max-width: 100%; height: auto; }
svg text { fill: var(--text-secondary); font-size: 12px; }
svg .val { fill: var(--text-primary); font-variant-numeric: tabular-nums; }
svg .tick { fill: var(--text-muted); font-size: 11px; font-variant-numeric: tabular-nums; }
svg .dim { fill: var(--text-muted); }
.hit { fill: transparent; cursor: default; }
.hit.click { cursor: pointer; }
.hit:hover, .hit:focus { fill: var(--hover); outline: none; }
.table-wrap { overflow-x: auto; max-height: 560px; overflow-y: auto; }
table { border-collapse: collapse; width: 100%; font-size: 13px; }
th, td { padding: 6px 8px; border-bottom: 1px solid var(--grid); text-align: right; white-space: nowrap; }
th:first-child, td:first-child, th.l, td.l { text-align: left; }
th { font-weight: 600; color: var(--text-secondary); cursor: pointer; position: sticky; top: 0; background: var(--surface-1); }
th[aria-sort]::after { content: " ▾"; color: var(--text-muted); }
th[aria-sort="ascending"]::after { content: " ▴"; }
td { font-variant-numeric: tabular-nums; }
tbody tr:hover { background: var(--hover); }
tr.clickable { cursor: pointer; }
tr.selected { background: var(--hover); }
.flag { display: inline-flex; align-items: center; gap: 4px; }
.dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; flex: none; }
.empty { color: var(--text-muted); padding: 24px 0; text-align: center; }
#tooltip { position: fixed; pointer-events: none; z-index: 10; background: var(--surface-1); color: var(--text-primary); border: 1px solid var(--border); border-radius: 8px; padding: 8px 10px; font-size: 12px; box-shadow: 0 4px 16px rgba(0,0,0,.12); display: none; min-width: 160px; }
#tooltip .t { color: var(--text-secondary); margin-bottom: 4px; }
#tooltip .r { display: flex; align-items: center; gap: 8px; justify-content: space-between; }
#tooltip .k { display: inline-flex; align-items: center; gap: 6px; color: var(--text-secondary); }
#tooltip .k i { width: 12px; height: 2px; display: inline-block; }
#tooltip b { font-variant-numeric: tabular-nums; }
.loading { opacity: .55; transition: opacity .2s; }
@media (max-width: 520px) { .tile .value { font-size: 22px; } .tiles { grid-template-columns: 1fr 1fr; } #search { flex: 1 1 100%; } }
</style>
</head>
<body>
<div class="wrap" id="app">
  <header>
    <div>
      <h1>Cluster resources</h1>
      <div class="sub" id="meta">Loading…</div>
    </div>
    <div class="actions">
      <label class="chip"><input type="checkbox" id="auto" checked> Auto-refresh 30 s</label>
      <button id="refresh" type="button">Refresh now</button>
      <button id="theme" type="button" aria-label="Toggle theme">◐</button>
    </div>
  </header>

  <div id="banners"></div>
  <div class="tiles" id="tiles"></div>

  <div class="card section">
    <div class="section-head">
      <div><h2>Cluster capacity</h2><div class="sub">Requests vs. allocatable of schedulable nodes</div></div>
      <div class="legend" id="capLegend"></div>
    </div>
    <div id="capacity"></div>
    <div class="sub" id="capNote" style="margin-top:8px"></div>
  </div>

  <div class="grid2">
    <div class="card">
      <div class="section-head"><div><h2>CPU by node</h2><div class="sub">% of the node's allocatable</div></div><div class="legend" id="nodeCpuLegend"></div></div>
      <div id="nodeCpu"></div>
    </div>
    <div class="card">
      <div class="section-head"><div><h2>Memory by node</h2><div class="sub">% of the node's allocatable</div></div><div class="legend" id="nodeMemLegend"></div></div>
      <div id="nodeMem"></div>
    </div>
  </div>

  <div class="filters" role="group" aria-label="Filters">
    <label class="chip"><input type="checkbox" id="sys" checked> System namespaces</label>
    <input type="search" id="search" placeholder="Filter namespaces / pods" aria-label="Filter namespaces and pods">
  </div>

  <div class="grid2">
    <div class="card">
      <div class="section-head"><div><h2>CPU by namespace</h2><div class="sub">vCPU · top 15 by requests · click to see its pods</div></div><div class="legend" id="nsCpuLegend"></div></div>
      <div id="nsCpu"></div>
    </div>
    <div class="card">
      <div class="section-head"><div><h2>Memory by namespace</h2><div class="sub">GiB · top 15 by requests · click to see its pods</div></div><div class="legend" id="nsMemLegend"></div></div>
      <div id="nsMem"></div>
    </div>
  </div>

  <div class="card section">
    <div class="section-head"><div><h2>Nodes</h2><div class="sub">* not schedulable (cordoned, or NoSchedule / NoExecute taint): not in the cluster totals</div></div></div>
    <div class="table-wrap"><table id="nodesTable"></table></div>
  </div>

  <div class="card section">
    <div class="section-head"><div><h2>Namespaces</h2><div class="sub">Click a namespace to show its pods below</div></div></div>
    <div class="table-wrap"><table id="nsTable"></table></div>
  </div>

  <div class="card section">
    <div class="section-head">
      <div><h2>Pods</h2><div class="sub" id="podsSub"></div></div>
      <button id="clearNs" type="button" hidden>Show all namespaces</button>
    </div>
    <div class="table-wrap"><table id="podsTable"></table></div>
  </div>

  <p class="sub">Requests and limits are the sum of each pod's containers. "Used" is the current metrics-server snapshot
  (kubectl top). Efficiency = used / requested. Limits over 100% of allocatable mean the node or cluster is overcommitted.</p>
</div>
<div id="tooltip" role="tooltip"></div>

<script>
"use strict";
const $ = (s) => document.querySelector(s);
const GIB = 1073741824, MIB = 1048576;
const SYSTEM_NS = /^(kube-|cattle-|fleet-|calico-|tigera-|rancher-|longhorn-|ingress-|cert-manager$)|-system$/;
const state = { data: null, d: null, err: null, q: "", sys: true, ns: null, busy: false,
                sort: { nodes: ["mem_req_pct", -1], ns: ["cpu_req", -1], pods: ["mem_req", -1] } };

// ---------- formatting ----------
const nf = (d) => { const f = new Intl.NumberFormat("en-US", { maximumFractionDigits: d, minimumFractionDigits: 0 });
  return { format: (n) => f.format(n).replace(/,/g, " ") }; };
const f0 = nf(0), f1 = nf(1), f2 = nf(2);
function num(v, digits) {
  if (v === "" || v === null || v === undefined) return "–";
  const n = Number(v);
  if (!isFinite(n)) return "–";
  return (digits === 0 ? f0 : digits === 1 ? f1 : f2).format(n);
}
function smart(v) { return Math.abs(v) >= 100 ? f0.format(v) : Math.abs(v) >= 10 ? f1.format(v) : f2.format(v); }
const vcpu = (m) => (m || 0) / 1000, gib = (b) => (b || 0) / GIB, mib = (b) => (b || 0) / MIB;
const pct = (v, of) => (of ? 100 * (v || 0) / of : 0);
function ago(iso) {
  if (!iso) return "never";
  const s = Math.round((Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return `${Math.max(s, 0)}s ago`;
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  return `${Math.round(s / 3600)} h ago`;
}
function el(tag, attrs, ...children) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k === "class") e.className = v; else if (k === "text") e.textContent = v; else e.setAttribute(k, v);
  }
  for (const c of children) if (c !== null && c !== undefined) e.append(c);
  return e;
}
const SVGNS = "http://www.w3.org/2000/svg";
function sv(tag, attrs) {
  const e = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs || {})) e.setAttribute(k, v);
  return e;
}
function svText(attrs, text) { const t = sv("text", attrs); t.textContent = text; return t; }

// ---------- tooltip ----------
const tip = $("#tooltip");
function showTip(evt, title, rows) {
  tip.replaceChildren(el("div", { class: "t", text: title }),
    ...rows.map(([color, label, value]) => el("div", { class: "r" },
      el("span", { class: "k" }, color ? el("i", { style: `background:${color}` }) : null, label),
      el("b", { text: value }))));
  tip.style.display = "block";
  moveTip(evt);
}
function moveTip(evt) {
  let x, y;
  if (evt.clientX !== undefined && evt.type !== "focus") { x = evt.clientX; y = evt.clientY; }
  else { const b = evt.target.getBoundingClientRect(); x = b.left + b.width / 2; y = b.top; }
  const w = tip.offsetWidth, h = tip.offsetHeight;
  tip.style.left = Math.min(window.innerWidth - w - 8, x + 12) + "px";
  tip.style.top = Math.max(8, y - h - 12) + "px";
}
const hideTip = () => { tip.style.display = "none"; };
function attachTip(node, fn) {
  node.setAttribute("tabindex", "0");
  node.addEventListener("pointerenter", (e) => fn(e));
  node.addEventListener("pointermove", moveTip);
  node.addEventListener("pointerleave", hideTip);
  node.addEventListener("focus", (e) => fn(e));
  node.addEventListener("blur", hideTip);
}

// ---------- derived data ----------
function derive(data) {
  const sum = (arr, k) => arr.reduce((a, x) => a + (x[k] || 0), 0);
  for (const n of data.nodes) {
    n.cpu_req_pct = pct(n.cpu_req, n.cpu_alloc); n.cpu_lim_pct = pct(n.cpu_lim, n.cpu_alloc); n.cpu_used_pct = n.cpu_used == null ? null : pct(n.cpu_used, n.cpu_alloc);
    n.mem_req_pct = pct(n.mem_req, n.mem_alloc); n.mem_lim_pct = pct(n.mem_lim, n.mem_alloc); n.mem_used_pct = n.mem_used == null ? null : pct(n.mem_used, n.mem_alloc);
  }
  const sched = data.nodes.filter((n) => n.sched);
  const running = data.pods.filter((p) => p.phase === "Running"), pending = data.pods.filter((p) => p.phase === "Pending");
  const c = {
    nodes: data.nodes.length, nodesSched: sched.length,
    cpu_alloc: sum(sched, "cpu_alloc"), mem_alloc: sum(sched, "mem_alloc"),
    cpu_req: sum(sched, "cpu_req"), cpu_lim: sum(sched, "cpu_lim"), cpu_used: sum(sched, "cpu_used"),
    mem_req: sum(sched, "mem_req"), mem_lim: sum(sched, "mem_lim"), mem_used: sum(sched, "mem_used"),
    pods: running.length, pending: pending.length, pend_cpu: sum(pending, "cpu_req"), pend_mem: sum(pending, "mem_req"),
    containers: sum(running, "containers"), no_cpu_req: sum(running, "no_cpu_req"), no_mem_lim: sum(running, "no_mem_lim"),
  };
  // N+1: capacity left if the largest schedulable node fails; platform components (system namespaces) come off
  // first, the rest is what workloads can safely request
  const onSched = new Set(sched.map((n) => n.name));
  const schedPods = running.filter((p) => onSched.has(p.node));
  const sys = schedPods.filter((p) => SYSTEM_NS.test(p.ns)), work = schedPods.filter((p) => !SYSTEM_NS.test(p.ns));
  Object.assign(c, {
    cpu_req_sys: sum(sys, "cpu_req"), mem_req_sys: sum(sys, "mem_req"),
    cpu_req_work: sum(work, "cpu_req"), mem_req_work: sum(work, "mem_req"),
    largest_cpu: Math.max(0, ...sched.map((n) => n.cpu_alloc)), largest_mem: Math.max(0, ...sched.map((n) => n.mem_alloc)),
  });
  c.cpu_n1 = c.cpu_alloc - c.largest_cpu; c.mem_n1 = c.mem_alloc - c.largest_mem;
  c.cpu_room = c.cpu_n1 - c.cpu_req_sys; c.mem_room = c.mem_n1 - c.mem_req_sys;
  c.n1_fits = c.nodesSched >= 2 && c.cpu_req_work <= c.cpu_room && c.mem_req_work <= c.mem_room;
  const byNs = new Map();
  const keys = ["cpu_req", "cpu_lim", "cpu_used", "mem_req", "mem_lim", "mem_used", "no_cpu_req", "no_mem_lim"];
  for (const p of data.pods) {
    let r = byNs.get(p.ns);
    if (!r) { r = { ns: p.ns, sys: SYSTEM_NS.test(p.ns), pods: 0, pending: 0 }; keys.forEach((k) => { r[k] = 0; }); byNs.set(p.ns, r); }
    if (p.phase === "Pending") { r.pending++; continue; }
    r.pods++;
    keys.forEach((k) => { r[k] += p[k] || 0; });
  }
  return { c, ns: [...byNs.values()] };
}
const matches = (...fields) => !state.q || fields.some((f) => String(f || "").toLowerCase().includes(state.q));
const nsVisible = (ns) => (state.sys || !SYSTEM_NS.test(ns));
const filteredNs = () => state.d.ns.filter((r) => nsVisible(r.ns) &&
  (matches(r.ns) || state.data.pods.some((p) => p.ns === r.ns && matches(p.name))));
function filteredPods() {
  return state.data.pods.filter((p) => state.ns ? p.ns === state.ns : nsVisible(p.ns) && matches(p.ns, p.name, p.node, p.owner));
}

// ---------- header, banners, tiles ----------
function renderMeta() {
  const parts = [];
  if (state.data) {
    parts.push(state.data.cluster || "current cluster");
    parts.push(`${state.data.nodes.length} nodes · ${f0.format(state.data.pods.length)} pods`);
    parts.push(`updated ${ago(state.data.collected_at)} (${new Date(state.data.collected_at).toLocaleTimeString()})`);
  }
  if (state.busy) parts.push("refreshing…");
  $("#meta").textContent = parts.join(" · ") || "Loading…";
  $("#refresh").disabled = state.busy;
}
function statusBanner(kind, title, text) {
  const color = `var(--status-${kind})`;
  return el("div", { class: "banner", role: kind === "critical" ? "alert" : "status" },
    el("span", { class: "flag", "aria-hidden": "true" }, el("span", { class: "dot", style: `background:${color}` }), kind === "good" ? "✓" : "!"),
    el("div", {}, el("strong", { text: title }), text ? el("div", { text }) : null));
}
function renderBanners() {
  const out = [];
  if (state.err) out.push(statusBanner("critical", state.data ? "Last refresh failed — showing the previous data" : "Could not load data", state.err));
  if (state.data && !state.data.metrics) out.push(statusBanner("warning", "metrics-server not available", "Usage (kubectl top) is missing; charts show requests and limits only."));
  $("#banners").replaceChildren(...out);
}
function tile(label, value, unit, note, status) {
  const v = el("div", { class: "value" }, value, unit ? el("span", { class: "unit", text: " " + unit }) : null);
  const n = note ? el("div", { class: "note" }) : null;
  if (n && status) n.append(el("span", { class: "flag" }, el("span", { class: "dot", style: `background:var(--status-${status})` }), note));
  else if (n) n.textContent = note;
  return el("div", { class: "card tile" }, el("div", { class: "label", text: label }), v, n);
}
function renderTiles() {
  const c = state.d.c, m = state.data.metrics;
  const cpuLim = pct(c.cpu_lim, c.cpu_alloc), memLim = pct(c.mem_lim, c.mem_alloc);
  $("#tiles").replaceChildren(
    tile("Allocatable (schedulable nodes)", smart(vcpu(c.cpu_alloc)), "vCPU", `${smart(gib(c.mem_alloc))} GiB · ${c.nodesSched} of ${c.nodes} nodes`),
    tile("CPU requested", `${num(pct(c.cpu_req, c.cpu_alloc), 0)}%`, "", `${smart(vcpu(c.cpu_req))} of ${smart(vcpu(c.cpu_alloc))} vCPU`),
    tile("Memory requested", `${num(pct(c.mem_req, c.mem_alloc), 0)}%`, "", `${smart(gib(c.mem_req))} of ${smart(gib(c.mem_alloc))} GiB`),
    c.nodesSched < 2
      ? tile("Room for workloads (N+1)", "0", "vCPU", "one schedulable node: nothing survives a node failure", "serious")
      : tile("Room for workloads (N+1)", smart(vcpu(Math.max(c.cpu_room, 0))), "vCPU",
          `${smart(gib(Math.max(c.mem_room, 0)))} GiB · workloads request ${smart(vcpu(c.cpu_req_work))} vCPU / ${smart(gib(c.mem_req_work))} GiB`,
          c.n1_fits ? "good" : "serious"),
    tile("CPU limits", `${num(cpuLim, 0)}%`, "", `${smart(vcpu(c.cpu_lim))} vCPU` + (cpuLim > 100 ? " · overcommitted" : ""), cpuLim > 100 ? "serious" : null),
    tile("Memory limits", `${num(memLim, 0)}%`, "", `${smart(gib(c.mem_lim))} GiB` + (memLim > 100 ? " · overcommitted" : ""), memLim > 100 ? "serious" : null),
    m ? tile("Used now", smart(vcpu(c.cpu_used)), "vCPU", `${smart(gib(c.mem_used))} GiB · ${num(pct(c.cpu_used, c.cpu_alloc), 0)}% CPU / ${num(pct(c.mem_used, c.mem_alloc), 0)}% memory`)
      : tile("Used now", "n/a", "", "metrics-server not available", "warning"),
    tile("Pods running", f0.format(c.pods), "", c.pending ? `${c.pending} pending · ${smart(vcpu(c.pend_cpu))} vCPU / ${smart(gib(c.pend_mem))} GiB requested` : "none pending",
      c.pending ? "warning" : "good"),
    tile("Containers without CPU request", f0.format(c.no_cpu_req), "", `of ${f0.format(c.containers)} · ${f0.format(c.no_mem_lim)} without memory limit`,
      c.no_cpu_req + c.no_mem_lim > 0 ? "serious" : "good"),
  );
}

// ---------- charts ----------
function legend(target, items) {
  $(target).replaceChildren(...items.map(([color, label, dashed]) =>
    el("span", {}, el("i", { class: "sw", style: dashed ? `background:none;border-left:2px ${dashed} ${color};border-radius:0` : `background:${color}` }), label)));
}
function barPath(x, y, w, h, r) {
  if (w <= 0) return "";
  r = Math.min(r, w, h / 2);
  return `M${x},${y}H${x + w - r}Q${x + w},${y} ${x + w},${y + r}V${y + h - r}Q${x + w},${y + h} ${x + w - r},${y + h}H${x}Z`;
}
function niceScale(maxv, n = 4) {
  if (!(maxv > 0)) return { max: 1, step: 0.25 };
  const raw = maxv / n, p = Math.pow(10, Math.floor(Math.log10(raw))), m = raw / p;
  const step = (m <= 1 ? 1 : m <= 2 ? 2 : m <= 5 ? 5 : 10) * p;
  return { max: Math.ceil(maxv / step - 1e-9) * step, step };
}
function widthOf(box, fallback) { return Math.max(280, Math.floor(box.clientWidth || fallback)); }
const truncate = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s);

function renderCapacity() {
  const c = state.d.c, m = state.data.metrics, box = $("#capacity");
  const colors = ["var(--series-1)", "var(--series-2)"], names = ["Workloads", "System (platform)"];
  legend("#capLegend", [[colors[0], names[0]], [colors[1], names[1]], ...(m ? [["var(--series-3)", "Used now", "solid"]] : []),
    ["var(--track)", "Free"], ["var(--text-primary)", "If the largest node fails", "dashed"]]);
  const rows = [
    ["CPU", "vCPU", vcpu(c.cpu_alloc), [vcpu(c.cpu_req_work), vcpu(c.cpu_req_sys)], m ? vcpu(c.cpu_used) : null, vcpu(c.cpu_lim), vcpu(c.cpu_n1)],
    ["Memory", "GiB", gib(c.mem_alloc), [gib(c.mem_req_work), gib(c.mem_req_sys)], m ? gib(c.mem_used) : null, gib(c.mem_lim), gib(c.mem_n1)],
  ];
  const W = widthOf(box, 1000), narrow = W < 640;
  const labelW = narrow ? 0 : 70, rightW = narrow ? 0 : 230, barH = 22, rowH = narrow ? 64 : 40, barY = narrow ? 18 : 6;
  const svg = sv("svg", { viewBox: `0 0 ${W} ${rows.length * rowH}`, width: W, height: rows.length * rowH, role: "img", "aria-label": "Cluster capacity" });
  rows.forEach(([name, unit, alloc, parts, used, lim, n1], i) => {
    const y = i * rowH + barY, plotW = W - labelW - rightW;
    const req = parts[0] + parts[1];
    const scale = plotW / Math.max(alloc, req, used || 0, 1e-9);
    svg.append(svText({ x: 0, y: narrow ? y - 6 : y + barH / 2 + 4 }, name));
    svg.append(sv("rect", { x: labelW, y, width: Math.max(alloc, req) * scale, height: barH, rx: 4, fill: "var(--track)" }));
    let x = labelW;
    parts.forEach((v, k) => {
      if (v <= 0) return;
      const w = Math.max(v * scale - 2, 1), isLast = k === parts.length - 1 || parts[k + 1] <= 0;
      svg.append(isLast ? sv("path", { d: barPath(x, y, w, barH, 4), fill: colors[k] }) : sv("rect", { x, y, width: w, height: barH, fill: colors[k] }));
      const hit = sv("rect", { x, y: y - 4, width: w + 2, height: barH + 8, class: "hit" });
      attachTip(hit, (e) => showTip(e, `${name} · ${names[k]}`, [
        [colors[k], "Requested", `${smart(v)} ${unit}`], [null, "Share of allocatable", `${num(pct(v, alloc), 1)}%`]]));
      svg.append(hit);
      x += v * scale;
    });
    const rest = sv("rect", { x, y: y - 4, width: Math.max(labelW + plotW - x, 0), height: barH + 8, class: "hit" });
    attachTip(rest, (e) => showTip(e, name, [
      [null, "Requested", `${smart(req)} ${unit} (${num(pct(req, alloc), 0)}%)`],
      ...(used != null ? [["var(--series-3)", "Used now", `${smart(used)} ${unit} (${num(pct(used, alloc), 0)}%)`]] : []),
      [null, "Limits", `${smart(lim)} ${unit} (${num(pct(lim, alloc), 0)}%)`],
      [null, "Allocatable", `${smart(alloc)} ${unit}`]]));
    svg.append(rest);
    if (req > alloc && alloc > 0) {   // allocatable marker when requests exceed schedulable capacity
      const ax = labelW + alloc * scale;
      svg.append(sv("line", { x1: ax, x2: ax, y1: y - 4, y2: y + barH + 4, stroke: "var(--text-primary)", "stroke-width": 2 }));
    }
    if (used != null) {
      const ux = labelW + used * scale;
      svg.append(sv("line", { x1: ux, x2: ux, y1: y - 5, y2: y + barH + 5, stroke: "var(--series-3)", "stroke-width": 3, "pointer-events": "none" }));
    }
    if (c.nodesSched >= 2 && alloc > 0) {   // N+1 marker: capacity left if the largest node fails
      const nx = labelW + Math.max(n1, 0) * scale;
      svg.append(sv("line", { x1: nx, x2: nx, y1: y - 5, y2: y + barH + 5, stroke: "var(--text-primary)", "stroke-width": 2, "stroke-dasharray": "3 2" }));
      const hit = sv("rect", { x: nx - 4, y: y - 5, width: 8, height: barH + 10, class: "hit" });
      attachTip(hit, (e) => showTip(e, `${name} · if the largest node fails`, [
        [null, "Capacity left", `${smart(n1)} ${unit}`], [null, "Share of allocatable", `${num(pct(n1, alloc), 0)}%`]]));
      svg.append(hit);
    }
    const free = alloc - req;
    svg.append(svText(narrow ? { x: 0, y: y + barH + 16, class: "val" } : { x: W, y: y + barH / 2 + 4, "text-anchor": "end", class: "val" },
      `${num(pct(req, alloc), 0)}% · ` + (free >= 0 ? `${smart(free)} ${unit} free` : `over by ${smart(-free)} ${unit}`)));
  });
  box.replaceChildren(svg);
  renderN1Note(c);
}
function renderN1Note(c) {
  const off = c.nodes - c.nodesSched;
  const line = (res, unit, alloc, largest, n1, system, left, work) =>
    `${res}: ${smart(alloc)} allocatable − ${smart(largest)} largest node = ${smart(n1)} after a node failure − ${smart(system)} platform components = ` +
    `${smart(left)} ${unit} for workloads; workloads request ${smart(work)} ${unit}` +
    (work > left + 1e-9 ? ` — ${smart(work - left)} ${unit} would not fit after a node failure.` : " — fits.");
  const notCounted = off ? ` Not counted: ${off} unschedulable node(s) (cordoned, or NoSchedule / NoExecute taint such as a dedicated control plane) and what runs on them.` : "";
  const limits = `Limits: CPU ${num(pct(c.cpu_lim, c.cpu_alloc), 0)}% · memory ${num(pct(c.mem_lim, c.mem_alloc), 0)}% of allocatable (over 100% = overcommitted).`;
  if (c.nodesSched < 2) {
    $("#capNote").replaceChildren(el("b", { text: "N+1: " }), "only one schedulable node, so nothing survives a node failure." + notCounted, el("br"), limits);
    return;
  }
  $("#capNote").replaceChildren(
    el("b", { text: "N+1 (dashed line): " }),
    "the capacity left if the largest schedulable node fails. Platform components (system namespaces: kube-*, cattle-*, *-system, ingress, …) " +
      "come off first; the rest is what workloads can safely request." + notCounted,
    el("br"), line("CPU", "vCPU", vcpu(c.cpu_alloc), vcpu(c.largest_cpu), vcpu(c.cpu_n1), vcpu(c.cpu_req_sys), vcpu(c.cpu_room), vcpu(c.cpu_req_work)),
    el("br"), line("Memory", "GiB", gib(c.mem_alloc), gib(c.largest_mem), gib(c.mem_n1), gib(c.mem_req_sys), gib(c.mem_room), gib(c.mem_req_work)),
    el("br"), limits);
}

// grouped horizontal bars; rows: [{label, dim, a, b, valText, tip:[...], onClick}]
function hbars(box, rows, { aColor, bColor, ref, unitTick, ariaLabel }) {
  if (!rows.length) { box.replaceChildren(el("div", { class: "empty", text: "Nothing matches the filters" })); return; }
  const W = widthOf(box, 560);
  const labelW = Math.min(170, Math.round(W * 0.36)), valW = 52, barH = 9, gap = 2, rowH = 30, axisH = 18;
  const maxChars = Math.floor((labelW - 8) / 7.2);
  const { max, step } = niceScale(Math.max(ref || 0, ...rows.map((r) => Math.max(r.a, r.b || 0))));
  const plotW = W - labelW - valW, H = rows.length * rowH + axisH;
  const svg = sv("svg", { viewBox: `0 0 ${W} ${H}`, width: W, height: H, role: "img", "aria-label": ariaLabel });
  for (let v = 0; v <= max + step / 2; v += step) {
    const x = labelW + plotW * v / max;
    svg.append(sv("line", { x1: x, x2: x, y1: 0, y2: rows.length * rowH, stroke: "var(--grid)", "stroke-width": 1 }));
    svg.append(svText({ x, y: H - 4, "text-anchor": "middle", class: "tick" }, smart(v) + (unitTick || "")));
  }
  svg.append(sv("line", { x1: labelW, x2: labelW, y1: 0, y2: rows.length * rowH, stroke: "var(--axis)", "stroke-width": 1 }));
  if (ref) {
    const x = labelW + plotW * ref / max;
    svg.append(sv("line", { x1: x, x2: x, y1: 0, y2: rows.length * rowH, stroke: "var(--text-muted)", "stroke-width": 1.5, "stroke-dasharray": "3 2" }));
  }
  rows.forEach((r, i) => {
    const y = i * rowH + (rowH - 2 * barH - gap) / 2;
    const hit = sv("rect", { x: 0, y: i * rowH, width: W, height: rowH, class: "hit" + (r.onClick ? " click" : "") });
    attachTip(hit, (e) => showTip(e, r.label, r.tip));
    if (r.onClick) hit.addEventListener("click", r.onClick);
    svg.append(hit);
    svg.append(svText({ x: labelW - 8, y: y + barH + 4, "text-anchor": "end", class: r.dim ? "dim" : "" }, truncate(r.label, maxChars)));
    svg.append(sv("path", { d: barPath(labelW, y, r.a / max * plotW, barH, 4), fill: aColor, "pointer-events": "none" }));
    if (r.b != null) svg.append(sv("path", { d: barPath(labelW, y + barH + gap, r.b / max * plotW, barH, 4), fill: bColor, "pointer-events": "none" }));
    // value next to the requested bar it describes (not the longer bar, which may be usage)
    svg.append(svText({ x: labelW + r.a / max * plotW + 6, y: y + barH - 0.5, class: "val", "pointer-events": "none" }, r.valText));
  });
  box.replaceChildren(svg);
}

function renderNodeChart(target, legendTarget, kind) {
  const m = state.data.metrics, conv = kind === "cpu" ? vcpu : gib, unit = kind === "cpu" ? "vCPU" : "GiB";
  legend(legendTarget, [["var(--series-1)", "Requested"], ...(m ? [["var(--series-2)", "Used now"]] : []), ["var(--text-muted)", "100%", "dashed"]]);
  const nodes = state.data.nodes.slice().sort((a, b) => (b.sched - a.sched) || (b[`${kind}_req_pct`] - a[`${kind}_req_pct`]));
  hbars($(target), nodes.map((n) => ({
    label: n.name + (n.sched ? "" : " *"), dim: !n.sched,
    a: n[`${kind}_req_pct`], b: m ? (n[`${kind}_used_pct`] || 0) : null,
    valText: `${num(n[`${kind}_req_pct`], 0)}%`,
    tip: [
      ["var(--series-1)", "Requested", `${smart(conv(n[`${kind}_req`]))} ${unit} (${num(n[`${kind}_req_pct`], 0)}%)`],
      ...(m ? [["var(--series-2)", "Used now", n[`${kind}_used`] == null ? "–" : `${smart(conv(n[`${kind}_used`]))} ${unit} (${num(n[`${kind}_used_pct`], 0)}%)`]] : []),
      [null, "Limits", `${smart(conv(n[`${kind}_lim`]))} ${unit} (${num(n[`${kind}_lim_pct`], 0)}%)`],
      [null, "Allocatable", `${smart(conv(n[`${kind}_alloc`]))} ${unit}`],
      [null, "Pods", `${n.pods} / ${n.pod_cap}`],
      ...(n.roles ? [[null, "Roles", n.roles]] : []),
      ...(n.sched ? [] : [[null, "Schedulable", "no"]])],
  })), { aColor: "var(--series-1)", bColor: "var(--series-2)", ref: 100, unitTick: "%", ariaLabel: `${kind} by node` });
}

function renderNsChart(target, legendTarget, kind) {
  const m = state.data.metrics, conv = kind === "cpu" ? vcpu : gib, unit = kind === "cpu" ? "vCPU" : "GiB";
  const second = m ? "used" : "lim";
  legend(legendTarget, [["var(--series-1)", "Requested"], ["var(--series-2)", m ? "Used now" : "Limits"]]);
  const rows = filteredNs().sort((a, b) => b[`${kind}_req`] - a[`${kind}_req`]).slice(0, 15);
  hbars($(target), rows.map((r) => ({
    label: r.ns, a: conv(r[`${kind}_req`]), b: conv(r[`${kind}_${second}`]),
    valText: smart(conv(r[`${kind}_req`])),
    onClick: () => selectNs(r.ns),
    tip: [
      ["var(--series-1)", "Requested", `${smart(conv(r[`${kind}_req`]))} ${unit}`],
      ...(m ? [["var(--series-2)", "Used now", `${smart(conv(r[`${kind}_used`]))} ${unit}`],
               [null, "Efficiency", r[`${kind}_req`] ? `${num(pct(r[`${kind}_used`], r[`${kind}_req`]), 0)}%` : "–"]] : []),
      [m ? null : "var(--series-2)", "Limits", `${smart(conv(r[`${kind}_lim`]))} ${unit}`],
      [null, "Pods", `${r.pods}` + (r.pending ? ` (+${r.pending} pending)` : "")]],
  })), { aColor: "var(--series-1)", bColor: "var(--series-2)", ariaLabel: `${kind} by namespace` });
}

// ---------- tables ----------
function pctCell(v) {
  const td = el("td");
  if (v == null) { td.textContent = "–"; return td; }
  if (v > 100) td.append(el("span", { class: "flag", title: "Over 100% of allocatable" }, el("span", { class: "dot", style: "background:var(--status-serious)" }), `${num(v, 0)}%`));
  else td.textContent = `${num(v, 0)}%`;
  return td;
}
function effCell(req, used) {
  if (!req || !state.data.metrics) return el("td", { text: "–" });
  const p = pct(used, req), td = el("td");
  if (p < 30) td.append(el("span", { class: "flag", title: "Low: requests much higher than use" }, el("span", { class: "dot", style: "background:var(--status-warning)" }), `${num(p, 0)}% low`));
  else td.textContent = `${num(p, 0)}%`;
  return td;
}
function countCell(v, status) {
  const td = el("td");
  if (v > 0 && status) td.append(el("span", { class: "flag" }, el("span", { class: "dot", style: `background:var(--status-${status})` }), f0.format(v)));
  else td.textContent = f0.format(v || 0);
  return td;
}
function renderTable(table, key, cols, rows, onRow, limit) {
  const [sk, sd] = state.sort[key];
  const col = cols.find((c) => c.k === sk);
  const sorted = rows.slice().sort((a, b) => {
    const va = col && col.v ? col.v(a) : a[sk], vb = col && col.v ? col.v(b) : b[sk];
    if (typeof va === "string" || typeof vb === "string") return sd * String(va).localeCompare(String(vb));
    return sd * ((va || 0) - (vb || 0));
  });
  const shown = limit ? sorted.slice(0, limit) : sorted;
  const head = el("tr", {}, ...cols.map((c) => {
    const th = el("th", { class: c.l ? "l" : "", scope: "col", text: c.h, title: c.title || "" });
    if (c.k === sk) th.setAttribute("aria-sort", sd > 0 ? "ascending" : "descending");
    th.addEventListener("click", () => { state.sort[key] = [c.k, c.k === sk ? -sd : (c.l ? 1 : -1)]; render(); });
    return th;
  }));
  const body = shown.length ? shown.map((r) => {
    const tr = el("tr", {}, ...cols.map((c) => c.cell ? c.cell(r) : el("td", { class: c.l ? "l" : "", text: c.fmt ? c.fmt(r) : r[c.k] })));
    if (onRow) onRow(tr, r);
    return tr;
  }) : [el("tr", {}, el("td", { colspan: cols.length, class: "empty", text: "Nothing matches the filters" }))];
  table.replaceChildren(el("thead", {}, head), el("tbody", {}, ...body));
  return sorted.length;
}
function renderNodesTable() {
  const used = (k) => (r) => r[k] == null ? -1 : r[k];
  renderTable($("#nodesTable"), "nodes", [
    { k: "name", h: "Node", l: true, fmt: (r) => r.name + (r.sched ? "" : " *") },
    { k: "roles", h: "Roles", l: true, fmt: (r) => r.roles || "–" },
    { k: "ready", h: "Ready", l: true, cell: (r) => el("td", { class: "l" }, el("span", { class: "flag" }, el("span", { class: "dot", style: `background:var(--status-${r.ready ? "good" : "critical"})` }), r.ready ? "Ready" : "NotReady")) },
    { k: "pods", h: "Pods", fmt: (r) => `${r.pods} / ${r.pod_cap}` },
    { k: "cpu_alloc", h: "CPU alloc", fmt: (r) => smart(vcpu(r.cpu_alloc)) },
    { k: "cpu_req_pct", h: "CPU req", cell: (r) => pctCell(r.cpu_req_pct) },
    { k: "cpu_lim_pct", h: "CPU lim", cell: (r) => pctCell(r.cpu_lim_pct) },
    { k: "cpu_used_pct", h: "CPU used", v: used("cpu_used_pct"), cell: (r) => pctCell(r.cpu_used_pct) },
    { k: "mem_alloc", h: "Mem alloc GiB", fmt: (r) => smart(gib(r.mem_alloc)) },
    { k: "mem_req_pct", h: "Mem req", cell: (r) => pctCell(r.mem_req_pct) },
    { k: "mem_lim_pct", h: "Mem lim", cell: (r) => pctCell(r.mem_lim_pct) },
    { k: "mem_used_pct", h: "Mem used", v: used("mem_used_pct"), cell: (r) => pctCell(r.mem_used_pct) },
  ], state.data.nodes);
}
function renderNsTable() {
  renderTable($("#nsTable"), "ns", [
    { k: "ns", h: "Namespace", l: true },
    { k: "pods", h: "Pods", fmt: (r) => f0.format(r.pods) },
    { k: "pending", h: "Pending", cell: (r) => countCell(r.pending, "warning") },
    { k: "cpu_req", h: "CPU req", fmt: (r) => smart(vcpu(r.cpu_req)), title: "vCPU" },
    { k: "cpu_lim", h: "CPU lim", fmt: (r) => smart(vcpu(r.cpu_lim)) },
    { k: "cpu_used", h: "CPU used", fmt: (r) => state.data.metrics ? smart(vcpu(r.cpu_used)) : "–" },
    { k: "cpu_eff", h: "CPU eff.", v: (r) => r.cpu_req ? r.cpu_used / r.cpu_req : 0, cell: (r) => effCell(r.cpu_req, r.cpu_used) },
    { k: "mem_req", h: "Mem req GiB", fmt: (r) => smart(gib(r.mem_req)) },
    { k: "mem_lim", h: "Mem lim GiB", fmt: (r) => smart(gib(r.mem_lim)) },
    { k: "mem_used", h: "Mem used GiB", fmt: (r) => state.data.metrics ? smart(gib(r.mem_used)) : "–" },
    { k: "mem_eff", h: "Mem eff.", v: (r) => r.mem_req ? r.mem_used / r.mem_req : 0, cell: (r) => effCell(r.mem_req, r.mem_used) },
    { k: "no_cpu_req", h: "No CPU req", title: "Containers without CPU request", cell: (r) => countCell(r.no_cpu_req, "serious") },
    { k: "no_mem_lim", h: "No mem limit", title: "Containers without memory limit", cell: (r) => countCell(r.no_mem_lim, "serious") },
  ], filteredNs(), (tr, r) => {
    tr.classList.add("clickable");
    if (state.ns === r.ns) tr.classList.add("selected");
    tr.addEventListener("click", () => selectNs(state.ns === r.ns ? null : r.ns));
  });
}
function renderPodsTable() {
  const m = state.data.metrics, LIMIT = 200;
  const rows = filteredPods();
  const total = renderTable($("#podsTable"), "pods", [
    { k: "ns", h: "Namespace", l: true },
    { k: "name", h: "Pod", l: true },
    { k: "node", h: "Node", l: true, fmt: (r) => r.node || "–" },
    { k: "owner", h: "Owner", l: true, fmt: (r) => r.owner || "–" },
    { k: "phase", h: "Phase", l: true, cell: (r) => el("td", { class: "l" }, r.phase === "Pending"
        ? el("span", { class: "flag" }, el("span", { class: "dot", style: "background:var(--status-warning)" }), "Pending") : "Running") },
    { k: "cpu_req", h: "CPU req m", fmt: (r) => f0.format(r.cpu_req) },
    { k: "cpu_lim", h: "CPU lim m", fmt: (r) => r.cpu_lim ? f0.format(r.cpu_lim) : "–" },
    { k: "cpu_used", h: "CPU used m", fmt: (r) => m && r.cpu_used != null ? f0.format(r.cpu_used) : "–" },
    { k: "mem_req", h: "Mem req MiB", fmt: (r) => f0.format(mib(r.mem_req)) },
    { k: "mem_lim", h: "Mem lim MiB", fmt: (r) => r.mem_lim ? f0.format(mib(r.mem_lim)) : "–" },
    { k: "mem_used", h: "Mem used MiB", fmt: (r) => m && r.mem_used != null ? f0.format(mib(r.mem_used)) : "–" },
  ], rows, null, LIMIT);
  $("#podsSub").textContent = (state.ns ? `Pods in namespace ${state.ns}` : "Pods matching the filters") +
    (total > LIMIT ? ` · showing ${LIMIT} of ${f0.format(total)} (sort or filter to narrow)` : ` · ${f0.format(total)}`) + " · \"–\" limit = none set";
  $("#clearNs").hidden = !state.ns;
}
function selectNs(ns) {
  state.ns = ns;
  render();
  if (ns) $("#podsTable").scrollIntoView({ behavior: "smooth", block: "start" });
}

function render() {
  renderMeta();
  renderBanners();
  if (!state.data) return;
  renderTiles();
  renderCapacity();
  renderNodeChart("#nodeCpu", "#nodeCpuLegend", "cpu");
  renderNodeChart("#nodeMem", "#nodeMemLegend", "mem");
  renderNsChart("#nsCpu", "#nsCpuLegend", "cpu");
  renderNsChart("#nsMem", "#nsMemLegend", "mem");
  renderNodesTable();
  renderNsTable();
  renderPodsTable();
}

// ---------- data loading ----------
let timer = null;
async function load(fresh) {
  clearTimeout(timer);
  state.busy = true; renderMeta();
  $("#app").classList.add("loading");
  try {
    const res = await fetch("api/data" + (fresh ? "?fresh=1" : ""), { cache: "no-store" });
    const body = await res.json().catch(() => ({ error: `HTTP ${res.status}` }));
    if (!res.ok || body.error) throw new Error(body.error || `HTTP ${res.status}`);
    state.data = body; state.d = derive(body); state.err = null;
  } catch (e) {
    state.err = e.message;
  } finally {
    state.busy = false;
    $("#app").classList.remove("loading");
  }
  render();
  if ($("#auto").checked) timer = setTimeout(() => load(false), 30000);
}

$("#refresh").addEventListener("click", () => load(true));
$("#auto").addEventListener("change", (e) => { clearTimeout(timer); if (e.target.checked) timer = setTimeout(() => load(false), 30000); });
$("#sys").addEventListener("change", (e) => { state.sys = e.target.checked; render(); });
$("#search").addEventListener("input", (e) => { state.q = e.target.value.trim().toLowerCase(); state.ns = null; render(); });
$("#clearNs").addEventListener("click", () => selectNs(null));
$("#theme").addEventListener("click", () => {
  const root = document.documentElement;
  const dark = root.dataset.theme ? root.dataset.theme === "dark" : matchMedia("(prefers-color-scheme: dark)").matches;
  root.dataset.theme = dark ? "light" : "dark";
  try { localStorage.setItem("theme", root.dataset.theme); } catch (e) { /* storage unavailable */ }
});
try { const t = localStorage.getItem("theme"); if (t) document.documentElement.dataset.theme = t; } catch (e) { /* ignore */ }
setInterval(renderMeta, 5000);
let resizeTimer;
window.addEventListener("resize", () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(render, 150); });
load(false);
</script>
</body>
</html>
HTML
}

# Live dashboard (charts, tables) for the current cluster, served from this pod -- the Rancher shell -- and reached
# through the API server's pod proxy. Foreground; Ctrl-C stops it. Override detection with K_RANCHER_URL / K_CLUSTER_ID.
k-serve() {
  _k8s_need || return 1
  local port="${1:-8080}" dir="${TMPDIR:-/tmp}/k-serve-$$" pod ns cid server
  command -v perl >/dev/null 2>&1 || { echo "error: perl not found in PATH" >&2; return 1; }
  command -v bash >/dev/null 2>&1 || { echo "error: bash not found in PATH" >&2; return 1; }
  mkdir -p "$dir" && _k8s_dash_html > "$dir/index.html" || return 1
  pod="$(hostname)"
  ns="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo cattle-system)"
  # Rancher puts every namespace in a project, annotated "<cluster-id>:<project-id>"
  cid="${K_CLUSTER_ID:-$(kubectl get ns "$ns" -o jsonpath='{.metadata.annotations.field\.cattle\.io/projectId}' 2>/dev/null | cut -d: -f1)}"
  server="${K_RANCHER_URL:-$(kubectl -n cattle-system get deploy cattle-cluster-agent \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CATTLE_SERVER")].value}' 2>/dev/null)}"
  [ -n "$server" ] || server="$(kubectl get settings.management.cattle.io server-url -o jsonpath='{.value}' 2>/dev/null)"
  echo "Dashboard on port $port (Ctrl-C to stop). Open:"
  echo "  ${server:-https://<rancher>}/k8s/clusters/${cid:-<cluster-id>}/api/v1/namespaces/$ns/pods/$pod:$port/proxy/"
  [ -n "$cid" ] || echo "  (cluster id not found: it is the <id> in your browser URL .../dashboard/c/<id>/...; or set K_CLUSTER_ID)"
  [ -n "$server" ] || echo "  (Rancher URL not found: set K_RANCHER_URL=https://your.rancher.host)"
  K_SERVE_DIR="$dir" K_SERVE_CLUSTER="${cid:-}" K_SERVE_JQ="$_K8S_JQ_DEFS$_K8S_DASH_JQ" K_SERVE_COLLECT="$_K8S_SERVE_COLLECT" \
    perl -e "$_K8S_SERVE_PL" "$port" "$dir"
  rm -rf "$dir"
}
