<#
.SYNOPSIS
    Lists Azure DevOps service connections ordered by last usage date.

.DESCRIPTION
    For each service connection, the script queries its execution history
    (the pipeline runs that used it) and reports the most recent use.
    Results are sorted newest first. Connections that were never used go last.

.PARAMETER Organization
    Azure DevOps organization name (the part after dev.azure.com/).

.PARAMETER Project
    Project name. If omitted, every project in the organization is scanned.

.PARAMETER Pat
    Personal Access Token with the "Service Connections (Read)" scope.
    Defaults to the AZDO_PAT environment variable, then AZURE_DEVOPS_EXT_PAT
    (the one az devops reads). If none is set, the script falls back to the
    Azure CLI (az login) for a token; organizations that reject that token
    (e.g. ones backed by a personal Microsoft account) need a PAT.

.PARAMETER Ascending
    Sort oldest first, which is handy for finding stale connections.
    Never-used connections then appear at the top.

.PARAMETER CsvPath
    Optional path to also export the results as CSV.

.EXAMPLE
    ./Get-ServiceConnectionsByLastUsage.ps1 -Organization contoso -Project Web

.EXAMPLE
    $env:AZDO_PAT = '<pat>'
    ./Get-ServiceConnectionsByLastUsage.ps1 -Organization contoso -Ascending -CsvPath stale.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Organization,
    [string] $Project,
    [string] $Pat = $(if ($env:AZDO_PAT) { $env:AZDO_PAT } else { $env:AZURE_DEVOPS_EXT_PAT }),
    [switch] $Ascending,
    [string] $CsvPath
)

$ErrorActionPreference = 'Stop'
$baseUrl = "https://dev.azure.com/$Organization"

# --- Authentication ----------------------------------------------------------
if ($Pat) {
    $token = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
    $headers = @{ Authorization = "Basic $token" }
}
else {
    Write-Verbose 'No PAT supplied; requesting a token from the Azure CLI.'
    # 499b84ac-... is the fixed resource ID of Azure DevOps
    $aadToken = az account get-access-token `
        --resource 499b84ac-1321-427f-aa17-267ca6975798 `
        --query accessToken -o tsv
    if (-not $aadToken) { throw 'Could not get a token. Set AZDO_PAT or run "az login".' }
    $headers = @{ Authorization = "Bearer $aadToken" }
}

# Without this, a rejected token gets a redirect to an HTML sign-in page
# instead of a 401, which would read as "no history" rather than an error.
$headers['X-TFS-FedAuthRedirect'] = 'Suppress'

function Invoke-AzDo([string] $Url) {
    Invoke-RestMethod -Uri $Url -Headers $headers -Method Get
}

# --- Projects to scan --------------------------------------------------------
if ($Project) {
    $projects = @($Project)
}
else {
    $projects = (Invoke-AzDo "$baseUrl/_apis/projects?`$top=1000&api-version=7.1").value.name
}

# --- Collect connections and their last use ----------------------------------
$results = foreach ($proj in $projects) {
    $projEnc = [Uri]::EscapeDataString($proj)
    Write-Verbose "Scanning project '$proj'"

    $endpoints = (Invoke-AzDo "$baseUrl/$projEnc/_apis/serviceendpoint/endpoints?api-version=7.1").value

    foreach ($ep in $endpoints) {
        $last = $null
        $historyError = $false
        try {
            # History is returned newest first, so $top=1 is the last use
            $history = Invoke-AzDo ("$baseUrl/$projEnc/_apis/serviceendpoint/$($ep.id)" +
                "/executionhistory?`$top=1&api-version=7.1-preview.1")
            $last = $history.value | Select-Object -First 1
        }
        catch {
            Write-Warning "Could not read history for '$($ep.name)' in '$proj': $($_.Exception.Message)"
            $historyError = $true
        }

        $lastUsed = $null
        if ($last) {
            $time = if ($last.data.finishTime) { $last.data.finishTime } else { $last.data.startTime }
            if ($time) { $lastUsed = [datetime]$time }
        }

        [pscustomobject]@{
            Project        = $proj
            Name           = $ep.name
            Type           = $ep.type
            LastUsed       = $lastUsed
            DaysSinceUse   = if ($lastUsed) { [int]((Get-Date) - $lastUsed).TotalDays } else { $null }
            LastPipeline   = $last.data.definition.name
            LastRunBy      = $last.data.owner.name
            LastResult     = if ($historyError) { 'ERROR' } else { $last.data.result }
            IsShared       = $ep.isShared
            Id             = $ep.id
        }
    }
}

# --- Sort: never-used connections always grouped at the "stale" end ----------
if ($Ascending) {
    $sorted = $results | Sort-Object @{ Expression = { $null -ne $_.LastUsed } }, LastUsed
}
else {
    $sorted = $results | Sort-Object @{ Expression = { $null -ne $_.LastUsed }; Descending = $true },
                                     @{ Expression = 'LastUsed'; Descending = $true }
}

$sorted | Format-Table Project, Name, Type, LastUsed, DaysSinceUse, LastPipeline, LastResult -AutoSize

if ($CsvPath) {
    $sorted | Export-Csv -Path $CsvPath -NoTypeInformation
    Write-Host "Exported $($sorted.Count) rows to $CsvPath"
}
