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

### Serve files from the Rancher shell (`k-serve`)
`k-serve [port] [dir]` (default `8080`, current dir) starts a small HTTP file server (perl, which the shell image has)
and prints the URL that reaches it through Rancher:
```
https://<rancher>/k8s/clusters/<cluster-id>/api/v1/namespaces/cattle-system/pods/<shell-pod>:<port>/proxy/
```
Handy for viewing report output in the browser, e.g. `mkdir ~/r && k-nodereport > ~/r/nodes.txt && k-serve 8080 ~/r`.
Opening the URL needs the `pods/proxy` permission in `cattle-system` (cluster admins have it). Dotfiles (like
`~/.kube/config`) are never served. If the cluster ID or Rancher URL can't be detected, set `K_CLUSTER_ID` / `K_RANCHER_URL`.
