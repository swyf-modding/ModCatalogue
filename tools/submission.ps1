<#
.SYNOPSIS
    Turns a mod submission into a checked catalogue entry.

.DESCRIPTION
    A submission arrives as an issue. The website has already filled in the entry and
    checked the release it names; this is the part that needs the code.

    It downloads the release, reads the code with the same scan the catalogue's own
    verification uses, checks that what the entry names is what the release holds, and
    writes the entry with the file hashes and the capabilities recorded - which is what
    makes a change between two releases impossible to miss.

    It writes the new catalogue and a report. It does not commit anything: the workflow
    that runs this opens a pull request, so a maintainer still merges it.

.EXAMPLE
    ./tools/submission.ps1 -Body (Get-Content -Raw submission.md)

.OUTPUTS
    A report at ./out/submission-report.md, and the new catalogue at ./out/mods.json.
#>
[CmdletBinding()]
param(
    # The submission issue's body. Read from a file when the body is long or has
    # lines in it, which it always does: a command-line argument cannot carry a
    # newline safely.
    [string]$Body,

    # A file holding the submission issue's body, as an alternative to -Body.
    [string]$BodyFile,

    # The catalogue to add the entry to. Named apart from the variable the parsed catalogue is
    # held in, because PowerShell does not distinguish $Catalogue from $catalogue and a
    # [string] parameter would coerce the parsed catalogue back into a string.
    [string]$CataloguePath = (Join-Path (Join-Path $PSScriptRoot '..') 'mods.json'),

    # Where to write the report and the new catalogue.
    [string]$OutDir = (Join-Path (Join-Path $PSScriptRoot '..') 'out'),

    # A GitHub token, so the API's rate limit is not the unauthenticated one.
    [string]$Token = $env:GH_TOKEN
)

$ErrorActionPreference = 'Stop'
$api = 'https://api.github.com'

if (-not $Body -and $BodyFile) { $Body = Get-Content -Raw -LiteralPath $BodyFile }
if (-not $Body) { throw 'The submission has no body: pass -Body or -BodyFile.' }

# ---------------------------------------------------------------- the entry

function Get-EntryJson([string]$Text) {
    $match = [regex]::Match($Text, '(?s)```json\s*(.*?)\s*```')
    if (-not $match.Success) { throw 'The submission does not contain an entry.' }

    try { return $match.Groups[1].Value | ConvertFrom-Json }
    catch { throw "The entry in the submission is not valid JSON: $($_.Exception.Message)" }
}

$entry = Get-EntryJson $Body

if (-not $entry.owner) { $entry | Add-Member -NotePropertyName owner -NotePropertyValue 'swyf-modding' -Force }
if (-not $entry.repo) { throw 'The entry names no repository.' }
if (-not $entry.displayName) { throw 'The entry names no display name.' }
if (-not $entry.summary) { throw 'The entry says nothing about what the mod does.' }
if (-not $entry.files -or $entry.files.Count -eq 0) { throw 'The entry names no files.' }

# ---------------------------------------------------------------- the release

$headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'swyf-modding-catalogue' }
if ($Token) { $headers['Authorization'] = "Bearer $Token" }

Write-Host "Checking $($entry.owner)/$($entry.repo) ..."
$release = Invoke-RestMethod -Uri "$api/repos/$($entry.owner)/$($entry.repo)/releases/latest" -Headers $headers

if ($release.draft -or $release.prerelease) {
    throw "The latest release ($($release.tag_name)) is a draft or a prerelease, so it is not the one Switchboard would install from."
}

$zipAsset = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
if (-not $zipAsset) { throw 'The latest release has no .zip asset, so there is nothing to install from.' }

$temp = Join-Path ([IO.Path]::GetTempPath()) ('swyf-submission-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$zip = Join-Path $temp $zipAsset.name

try {
    Write-Host "Downloading $($zipAsset.name) ..."
    Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $zip -Headers $headers

    # ---------------------------------------------------------------- the code

    Write-Host 'Reading the code ...'
    $json = (& (Join-Path $PSScriptRoot 'scan-capabilities.ps1') -Path $zip -Json) -join "`n"

    # PowerShell 5.1's ConvertFrom-Json hands back an array as one object rather than
    # enumerating it, so the results are flattened here. Without this, $scan holds a
    # single element that is an array, and every lookup against it finds nothing.
    $parsed = $json | ConvertFrom-Json
    $scan = @()
    foreach ($item in $parsed) { $scan += $item }
} finally {
    if (Test-Path $temp) { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($scan.Count -eq 0) { throw 'The release holds no .NET assembly this can read, so there is nothing to install.' }

$byName = @{}
foreach ($s in $scan) { $byName[$s.file] = $s }

# ---------------------------------------------------------------- the checks

$problems = New-Object System.Collections.ArrayList
$notes = New-Object System.Collections.ArrayList

# Every file the entry names has to be in the release, and every assembly in the
# release has to be named by the entry. Half an entry is how a mod ends up
# installed with its library missing.
foreach ($f in $entry.files) {
    if (-not $byName.ContainsKey($f.fileName)) {
        [void]$problems.Add("the entry names $($f.fileName), which is not in the release")
    }
}
foreach ($s in $scan) {
    $named = @($entry.files | Where-Object { $_.fileName -eq $s.file })
    if ($named.Count -eq 0) { [void]$problems.Add("the release holds $($s.file), which the entry does not name") }
}

# The shared library goes to core and is not loaded as a plugin. In plugins the
# chainloader would try to load it and the install would break in a way nothing
# explains.
foreach ($f in $entry.files) {
    $isLibrary = $f.fileName -ieq 'ScamWYF.Modding.Core.dll'
    if ($isLibrary -and ($f.folder -ne 'core' -or $f.expectsPluginAttribute -ne $false)) {
        [void]$problems.Add("$($f.fileName) is the shared library, so it belongs in core and is not a plugin")
    }
}

# Every plugin has to carry the attribute the loader reads, with a version the
# loader can parse. A plugin without one is silently never loaded.
foreach ($f in $entry.files) {
    if (-not $byName.ContainsKey($f.fileName)) { continue }
    $s = $byName[$f.fileName]
    $hasAttribute = @($s.bepInPlugin).Count -gt 0

    if ($f.expectsPluginAttribute -and -not $hasAttribute) {
        [void]$problems.Add("$($f.fileName) has no [BepInPlugin] attribute, so the loader would never load it")
    }
    if (-not $f.expectsPluginAttribute -and $hasAttribute) {
        [void]$problems.Add("$($f.fileName) carries a [BepInPlugin] attribute, so it is a plugin and belongs in plugins")
    }
    if ($hasAttribute) {
        foreach ($p in $s.bepInPlugin) { [void]$notes.Add("$($f.fileName) declares $p") }
    }
}

if ($problems.Count -gt 0) {
    Write-Host ''
    Write-Host 'The submission did not pass:' -ForegroundColor Red
    foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
    throw "The submission has $($problems.Count) problem(s) and was not added."
}

# ---------------------------------------------------------------- the entry

$files = @()
foreach ($f in $entry.files) {
    $s = $byName[$f.fileName]
    $files += [ordered]@{
        fileName                = $f.fileName
        folder                  = $f.folder
        expectsPluginAttribute  = [bool]$f.expectsPluginAttribute
        sha256                  = $s.sha256
        capabilities            = @($s.capabilities)
    }
}

$new = [ordered]@{
    owner           = $entry.owner
    repo            = $entry.repo
    displayName     = $entry.displayName
    summary         = $entry.summary
    approvedVersion = $release.tag_name
    files           = $files
}


# ---------------------------------------------------------------- the catalogue

$catalogue = Get-Content -Raw -LiteralPath $CataloguePath | ConvertFrom-Json
$existing = @($catalogue.mods | Where-Object {
    $_.owner -ieq $new.owner -and $_.repo -ieq $new.repo
})

if ($existing.Count -gt 0) {
    Write-Host "The catalogue already has $($new.owner)/$($new.repo); it will be updated in place."
    $catalogue.mods = @($catalogue.mods | ForEach-Object {
        if ($_.owner -ieq $new.owner -and $_.repo -ieq $new.repo) { $new } else { $_ }
    })
} else {
    $catalogue.mods = @($catalogue.mods) + @($new)
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$newPath = Join-Path $OutDir 'mods.json'
$catalogue | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $newPath -Encoding UTF8

# ---------------------------------------------------------------- the report

$lines = New-Object System.Collections.ArrayList
[void]$lines.Add("# Submission: $($new.owner)/$($new.repo)")
[void]$lines.Add('')
[void]$lines.Add("**Release:** $($release.tag_name)")
[void]$lines.Add('')
[void]$lines.Add('| File | Folder | Plugin | SHA-256 | Capabilities |')
[void]$lines.Add('|---|---|---|---|---|')
foreach ($f in $files) {
    [void]$lines.Add("| $($f.fileName) | $($f.folder) | $($f.expectsPluginAttribute) | ``$($f.sha256)`` | $($f.capabilities -join ', ') |")
}
[void]$lines.Add('')
if ($notes.Count -gt 0) {
    [void]$lines.Add('## What the code declares')
    [void]$lines.Add('')
    foreach ($n in $notes) { [void]$lines.Add("- $n") }
    [void]$lines.Add('')
}

$reportPath = Join-Path $OutDir 'submission-report.md'
Set-Content -LiteralPath $reportPath -Value ($lines -join "`n") -Encoding UTF8

Write-Host ''
Write-Host "The submission passed. The new catalogue is at $newPath" -ForegroundColor Green
Write-Host "The report is at $reportPath" -ForegroundColor Green
