# tools
Tools for Cloud

Small standalone scripts, grouped by platform.

## AWS

| Script | What it does |
| --- | --- |
| [`aws/addMyIP2EKS.sh`](aws/addMyIP2EKS.sh) | Add my IP to the public-access allowlist of the current EKS cluster |
| [`aws/unsetAWSCreds.sh`](aws/unsetAWSCreds.sh) | Unset all AWS-related env vars (`source` it) |

## Azure DevOps

| Script | What it does |
| --- | --- |
| [`azure-devops/list-service-connections-by-last-usage.sh`](azure-devops/list-service-connections-by-last-usage.sh) | List service connections ordered by last usage (Bash, `az`) |
| [`azure-devops/Get-ServiceConnectionsByLastUsage.ps1`](azure-devops/Get-ServiceConnectionsByLastUsage.ps1) | Same, for PowerShell (PAT or `az`) |

See [azure-devops/README.md](azure-devops/README.md) for usage.

## Kubernetes

| Script | What it does |
| --- | --- |
| [`kubernetes/removeNSFinalizer.sh`](kubernetes/removeNSFinalizer.sh) | Force-remove finalizers from a namespace stuck in `Terminating` (`-n <namespace>`) |

## Network

| Script | What it does |
| --- | --- |
| [`network/myIP.sh`](network/myIP.sh) | Print my public IP in CIDR format (`x.x.x.x/32`) |

## Images

[`images/Dockerfile.ubuntu`](images/Dockerfile.ubuntu) builds `cdalar/ubuntu:latest`,
an Ubuntu toolbox image. CI rebuilds and pushes it when `images/` changes.
