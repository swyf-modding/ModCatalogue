<#
.SYNOPSIS
    Lists the catalogue entries that differ between two versions of mods.json.

.DESCRIPTION
    A change touches one entry; the rest of the catalogue is not that change's business. The
    verifier reads one release per entry, so an unrelated entry whose release was taken down
    would otherwise fail every submission, and a maintainer would learn nothing about the
    change under review.

    This prints the repository name of each new or changed entry, one per line, sorted, and
    nothing when the catalogue is identical. A workflow passes the names to
    verify-catalogue.ps1 -Only.

    Entries that were removed are not printed: there is no release left to read for them.

    The entries are compared in the shape the catalogue is written in, so a difference is a
    difference in what the entry says, not in the order its fields happen to be in.

.EXAMPLE
    ./changed-mods.ps1 -Before ./before/mods.json

.EXAMPLE
    ./changed-mods.ps1 -Before ./before/mods.json -After ./mods.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Before,
    [string]$After = (Join-Path (Split-Path -Parent $PSScriptRoot) 'mods.json')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'catalogue-rules.ps1')

if (-not (Test-Path $Before)) { throw "There is no catalogue at $Before." }
if (-not (Test-Path $After)) { throw "There is no catalogue at $After." }

# owner/repo in lower case, so the same entry is the same key even if its capitalisation moved.
function Get-Entries([string]$Path) {
    $model = ConvertTo-CatalogueModel -Catalogue (Read-Catalogue -Path $Path)
    $entries = @{}
    foreach ($mod in (Get-Field $model 'mods')) {
        $owner = Get-Field $mod 'owner'
        if ([string]::IsNullOrWhiteSpace($owner)) { $owner = $CatalogueLimits.DefaultOwner }
        $repo = Get-Field $mod 'repo'
        $key = "$($owner.ToLowerInvariant())/$($repo.ToLowerInvariant())"
        $entries[$key] = [pscustomobject]@{
            Repo = $repo
            Json = ConvertTo-JsonValue -Value $mod
        }
    }
    return $entries
}

# Not $before/$after: PowerShell does not distinguish them from the [string] parameters of the
# same names, and the assignment would be coerced back to a string.
$beforeEntries = Get-Entries $Before
$afterEntries = Get-Entries $After

foreach ($key in ($afterEntries.Keys | Sort-Object)) {
    $entry = $afterEntries[$key]
    if (-not $beforeEntries.ContainsKey($key) -or $beforeEntries[$key].Json -ne $entry.Json) {
        $entry.Repo
    }
}
