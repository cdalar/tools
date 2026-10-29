# tools
Tools for Cloud


## Get My IP in CIDR Format. 
`./myIP.sh`

## Add my IP to EKS whiteList 
`./addMyIP2EKS.sh` 

## Unset ALL AWS Related Env Vars.
`./unsetAWSCreds.sh`

## Kubernetes resource reports (`k8s-funcs.sh`)
Read-only kubectl + jq helpers, all prefixed `k-` (type `k-<TAB>`, or `k-help`):
`k-toppods [N] [key]`, `k-nodemem`, `k-nstotals [key]`, `k-nsreq <ns> [key]`, `k-nodereport [ns]`
(key: `mem`, `cpu`, `memlim`, `cpulim`).
Each shows memory and CPU requests and limits with percentages (of node / cluster allocatable / namespace total);
limits over 100% of allocatable are flagged with `!`.
Unschedulable nodes (cordoned, or tainted `NoSchedule`/`NoExecute` like control-plane nodes) are marked `*` and left out of totals.
Needs `kubectl`, `jq`, `awk` (bash).

In a Rancher "Kubectl Shell" (or anywhere), either download it:
```
curl -fsSLo ~/k8s-funcs.sh https://raw.githubusercontent.com/cdalar/tools/main/k8s-funcs.sh && source ~/k8s-funcs.sh
```
or paste it: run `cat > ~/k8s-funcs.sh`, paste the file contents, press `Ctrl-D`, then `source ~/k8s-funcs.sh`.

The Rancher shell pod is ephemeral, so repeat this per session.

### Live dashboard from the Rancher shell (`k-serve`)
`k-serve [port]` (default `8080`) starts a live dashboard for the current cluster: tiles, capacity bars, CPU and memory
by node and by namespace (requested vs. used), N+1 (room left for workloads if the largest node fails, after platform
components), and sortable tables of nodes, namespaces and pods. It auto-refreshes
every 30 s, follows the light/dark system theme and is self-contained (no CDN). It runs on what the shell image has
(perl, bash, kubectl, jq) and prints the URL that reaches it through Rancher:
```
https://<rancher>/k8s/clusters/<cluster-id>/api/v1/namespaces/cattle-system/pods/<shell-pod>:<port>/proxy/
```
Opening the URL needs the `pods/proxy` permission in `cattle-system` (cluster admins have it). It is read-only: it only
runs `kubectl get nodes,pods` and `kubectl top`, and serves no files. Usage needs metrics-server. If the cluster ID or
Rancher URL can't be detected, set `K_CLUSTER_ID` / `K_RANCHER_URL`.

**Rancher project names.** Downstream clusters only know each namespace's project ID. The dashboard first asks the
Rancher API for the names, through your browser session. If that is not allowed, export them from the Rancher local
cluster: run `k-projects` in the local cluster's shell, then paste the `echo '…' > ~/rancher-projects.json` line it
prints into the downstream cluster's shell before `k-serve`. One export covers all clusters. Names give a Project
column, charts by project, and the System project counts as platform for N+1.
