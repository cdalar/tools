# tools
Tools for Cloud


## Get My IP in CIDR Format. 
`./myIP.sh`

## Add my IP to EKS whiteList 
`./addMyIP2EKS.sh` 

## Unset ALL AWS Related Env Vars.
`./unsetAWSCreds.sh`

## Kubernetes resource reports (`k8s-funcs.sh`)
Read-only kubectl + jq helpers: `toppods`, `nodemem`, `nstotals`, `nsreq <ns>`, `nodereport [ns]`.
Needs `kubectl`, `jq`, `awk` (bash).

In a Rancher "Kubectl Shell" (or anywhere), either download it:
```
curl -fsSLo ~/k8s-funcs.sh https://raw.githubusercontent.com/cdalar/tools/main/k8s-funcs.sh && source ~/k8s-funcs.sh
```
or paste it: run `cat > ~/k8s-funcs.sh`, paste the file contents, press `Ctrl-D`, then `source ~/k8s-funcs.sh`.

The Rancher shell pod is ephemeral, so repeat this per session.
