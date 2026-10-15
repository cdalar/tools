# Azure DevOps

## Service connections by last usage

Lists every service connection in a project (or a whole organization) with
the last time a pipeline used it, sorted newest first. Use `-a` /
`-Ascending` to put stale and never-used connections at the top, which is
handy for cleanup.

Both scripts produce the same report; pick the one that fits your shell.

| Script | Runs on | Auth |
| --- | --- | --- |
| `list-service-connections-by-last-usage.sh` | Bash (macOS / Linux) | `az login` |
| `Get-ServiceConnectionsByLastUsage.ps1` | PowerShell 7+ | `AZDO_PAT`, or `az login` |

Both need read access to service connections in the projects you scan
(a PAT needs the **Service Connections (Read)** scope).

### Bash

Requires the Azure CLI; the `azure-devops` extension is installed on first
run if missing.

```bash
./list-service-connections-by-last-usage.sh -o <org> [-p <project>] [-a] [-c out.csv]

# One project, most recently used first
./list-service-connections-by-last-usage.sh -o contoso -p Web

# Whole organization, stale first, exported to CSV
./list-service-connections-by-last-usage.sh -o contoso -a -c stale.csv
```

### PowerShell

```powershell
./Get-ServiceConnectionsByLastUsage.ps1 -Organization contoso -Project Web

$env:AZDO_PAT = '<pat>'
./Get-ServiceConnectionsByLastUsage.ps1 -Organization contoso -Ascending -CsvPath stale.csv
```

The PowerShell version also reports who triggered the last run
(`LastRunBy`), whether the connection is shared, and its ID in the CSV.

### Output

| Column | Meaning |
| --- | --- |
| Last used | Finish (or start) time of the most recent run; `never` if unused |
| Days | Days since that run |
| Project / Name / Type | The service connection |
| Last pipeline / Result | The pipeline of that run and its result |
