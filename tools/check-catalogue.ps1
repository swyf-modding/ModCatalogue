<#
.SYNOPSIS
    Checks that the catalogue is a catalogue Switchboard will accept.

.DESCRIPTION
    The rules are in catalogue-rules.ps1, which this dot-sources. This is the small script that
    applies them to a file and prints what is wrong: no network, no release, no code.

    It is for the times the network cannot answer - a hand-written entry before it is sent, a
    change to the file that has not been merged yet, a rule that was changed and wants to know
    what it breaks.

.EXAMPLE
    ./tools/check-catalogue.ps1
    ./tools/check-catalogue.ps1 -Path ./mods.json
    ./tools/check-catalogue.ps1 -Entry ./my-entry.json
#>
[CmdletBinding()]
param(
    # The catalogue to check.
    [string]$Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'mods.json'),

    # A single entry to check instead of the whole catalogue, in the shape a submission has.
    [string]$Entry
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'catalogue-rules.ps1')

if ($Entry) {
    $plain = ConvertTo-PlainObject ((Get-Content -Raw -LiteralPath $Entry) | ConvertFrom-Json)
    $problems = Test-CatalogueEntry -Entry $plain -Label 'the entry'
}
else {
    if (-not (Test-Path $Path)) { throw "There is no catalogue at $Path." }

    try { $catalogue = Read-Catalogue -Path $Path }
    catch { throw "The catalogue at $Path could not be read as JSON: $($_.Exception.Message)" }

    $problems = Test-Catalogue -Catalogue $catalogue
    $orderProblems = Test-CatalogueOrder -Catalogue $catalogue
    if ($orderProblems) { $problems += $orderProblems }
}

if ($problems.Count -eq 0) {
    if ($Entry) { Write-Host 'The entry is a valid catalogue entry.' -ForegroundColor Green }
    else { Write-Host "$Path is a valid catalogue." -ForegroundColor Green }
    exit 0
}

Write-Host ''
Write-Host 'PROBLEMS' -ForegroundColor Red
foreach ($problem in $problems) { Write-Host "  - $problem" -ForegroundColor Red }
Write-Host ''
Write-Host 'A catalogue with a problem in it is refused whole: Switchboard falls back to the' -ForegroundColor Yellow
Write-Host 'list it was built with, so one bad entry unlists every mod rather than one.' -ForegroundColor Yellow
exit 1
