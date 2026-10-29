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
#   k-serve [port] [dir]           serve a directory over HTTP from this pod (default 8080, .) and print the Rancher
#                                  URL that reaches it through the API server's pod proxy
# key (sort order): mem | cpu | memlim | cpulim
#
# Limits are summed over containers that set one; a container without a limit counts as 0 (and "-" means none set).
# LIM% over 100 is flagged with "!" (limits overcommit the allocatable capacity).
# Unschedulable nodes (cordoned, or tainted NoSchedule/NoExecute, e.g. control plane) are marked "*" and left out
# of node TOTALs; k-nstotals counts only schedulable nodes and the pods on them.
#
# Requires: kubectl, jq, awk, bash or zsh. Usage in k-nodereport needs metrics-server ("n/a" without it).
# k-serve needs perl (in the Rancher shell image) and the pods/proxy permission to open the URL.

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
k-serve [port] [dir]           serve a directory over HTTP (default 8080, .) and print its Rancher proxy URL
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
       tp+=$2; tm+=$3; tml+=$4; ta+=$5; tc+=$6; tcl+=$7; tca+=$8}
      END{row("TOTAL",tp,tm,tml,ta,tc,tcl,tca)
          if (nx) printf "* not schedulable (cordoned or NoSchedule/NoExecute taint), not in TOTAL: %d node(s)\n", nx}'
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

# Static file server for k-serve: GET/HEAD only, relative links (works behind the /proxy/ prefix),
# dotfiles and ".." refused so ~/.kube/config is never served.
_K8S_SERVE_PL='
use strict; use warnings; use IO::Socket::INET;
my ($port, $root) = @ARGV;
$SIG{PIPE} = "IGNORE";
my $srv = IO::Socket::INET->new(LocalAddr => "0.0.0.0", LocalPort => $port, Listen => 16, ReuseAddr => 1, Proto => "tcp")
  or die "k-serve: cannot listen on port $port: $!\n";
my %ct = (html => "text/html", htm => "text/html", css => "text/css", js => "text/javascript", json => "application/json",
          csv => "text/csv", svg => "image/svg+xml", png => "image/png", jpg => "image/jpeg", jpeg => "image/jpeg",
          gif => "image/gif", pdf => "application/pdf", gz => "application/gzip", tgz => "application/gzip");
sub esc { my $s = shift; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g; $s }
sub uenc { my $s = shift; $s =~ s/([^A-Za-z0-9._~-])/sprintf("%%%02X", ord $1)/ge; $s }
sub reply {
  my ($c, $head, $code, $type, $body, $extra) = @_;
  print $c "HTTP/1.0 $code\r\nContent-Type: $type\r\nContent-Length: " . length($body)
         . "\r\nCache-Control: no-store\r\nConnection: close\r\n" . ($extra // "") . "\r\n";
  print $c $body unless $head;
}
sub handle {
  my $c = shift;
  binmode $c;
  my $req = <$c> // return;
  while (my $h = <$c>) { last if $h =~ /^\r?\n$/ }
  my ($m, $uri) = $req =~ m{^(\S+)\s+(\S+)} or return reply($c, 0, "400 Bad Request", "text/plain", "bad request\n");
  my $head = $m eq "HEAD";
  return reply($c, 0, "405 Method Not Allowed", "text/plain", "GET or HEAD only\n") unless $m eq "GET" or $head;
  (my $path = $uri) =~ s/[?#].*//;
  $path =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
  my @seg = grep { length } split m{/}, $path;
  print STDERR scalar(localtime), " $m $path\n";
  return reply($c, $head, "403 Forbidden", "text/plain", "forbidden\n") if grep { /^\./ } @seg;
  my $fs = join "/", $root, @seg;
  if (-d $fs) {
    return reply($c, $head, "301 Moved Permanently", "text/plain", "", "Location: " . uenc($seg[-1]) . "/\r\n")
      if @seg and $path !~ m{/$};
    $fs .= "/index.html" if -f "$fs/index.html";
  }
  if (-d $fs) {
    opendir my $d, $fs or return reply($c, $head, "403 Forbidden", "text/plain", "forbidden\n");
    my @e = sort grep { !/^\./ } readdir $d;
    closedir $d;
    my $title = esc("/" . join("", map { "$_/" } @seg));
    my $html = "<!doctype html><meta charset=utf-8><title>$title</title>"
             . "<style>body{font:14px monospace;margin:2em}td{padding:0 1.5em 0 0}</style><h3>$title</h3><table>";
    $html .= "<tr><td><a href=\"../\">../</a><td>" if @seg;
    for (@e) {
      my $dir = -d "$fs/$_" ? "/" : "";
      $html .= "<tr><td><a href=\"" . uenc($_) . "$dir\">" . esc($_) . "$dir</a><td>" . ($dir ? "" : -s "$fs/$_");
    }
    return reply($c, $head, "200 OK", "text/html; charset=utf-8", "$html</table>\n");
  }
  return reply($c, $head, "404 Not Found", "text/plain", "not found\n") unless -f $fs;
  open my $f, "<", $fs or return reply($c, $head, "403 Forbidden", "text/plain", "forbidden\n");
  binmode $f;
  my $body = do { local $/; <$f> } // "";
  close $f;
  my ($ext) = $fs =~ m{\.([^./]+)$};
  my $type = $ct{lc($ext // "")} // (-T $fs ? "text/plain" : "application/octet-stream");
  $type .= "; charset=utf-8" if $type =~ m{^text/};
  reply($c, $head, "200 OK", $type, $body);
}
while (my $c = $srv->accept) {
  eval { local $SIG{ALRM} = sub { die "timeout\n" }; alarm 30; handle($c); alarm 0; };
  alarm 0;
  print STDERR "k-serve: $@" if $@;
  close $c;
}
'

# Serve a directory over HTTP from this pod (the Rancher shell) and print the Rancher URL that reaches it through
# the API server's pod proxy. Foreground; Ctrl-C stops it. Override detection with K_RANCHER_URL / K_CLUSTER_ID.
k-serve() {
  local port="${1:-8080}" dir="${2:-.}" pod ns cid server
  command -v perl >/dev/null 2>&1 || { echo "error: perl not found in PATH" >&2; return 1; }
  [ -d "$dir" ] || { echo "error: $dir is not a directory" >&2; return 1; }
  pod="$(hostname)"
  ns="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo cattle-system)"
  # Rancher puts every namespace in a project, annotated "<cluster-id>:<project-id>"
  cid="${K_CLUSTER_ID:-$(kubectl get ns "$ns" -o jsonpath='{.metadata.annotations.field\.cattle\.io/projectId}' 2>/dev/null | cut -d: -f1)}"
  server="${K_RANCHER_URL:-$(kubectl -n cattle-system get deploy cattle-cluster-agent \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CATTLE_SERVER")].value}' 2>/dev/null)}"
  [ -n "$server" ] || server="$(kubectl get settings.management.cattle.io server-url -o jsonpath='{.value}' 2>/dev/null)"
  echo "Serving $(cd "$dir" && pwd) on port $port (Ctrl-C to stop). Open:"
  echo "  ${server:-https://<rancher>}/k8s/clusters/${cid:-<cluster-id>}/api/v1/namespaces/$ns/pods/$pod:$port/proxy/"
  [ -n "$cid" ] || echo "  (cluster id not found: it is the <id> in your browser URL .../dashboard/c/<id>/...; or set K_CLUSTER_ID)"
  [ -n "$server" ] || echo "  (Rancher URL not found: set K_RANCHER_URL=https://your.rancher.host)"
  perl -e "$_K8S_SERVE_PL" "$port" "$dir"
}
