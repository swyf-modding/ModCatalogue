<#
.SYNOPSIS
    Checks that every pinned release in mods.json is still exactly what was approved.

.DESCRIPTION
    For each mod the catalogue pins an approvedVersion, and for each file a sha256 and the
    set of capabilities that file had when a human last looked at it. This downloads the
    pinned release, verifies the hash, rescans the assemblies and fails if either the bytes
    or the capabilities have moved.

    That makes a capability change impossible to land silently: a mod that gains the ability
    to start processes or open sockets cannot be approved without someone editing mods.json
    to say so, which is a reviewable diff.

    GitHub's own asset digest is NOT enough on its own. It is computed over whatever the
    author uploaded, so it proves the download was not corrupted in transit - not that the
    file is the one anyone reviewed. The sha256 here is recorded at approval time, which is
    what makes it an authenticity check rather than an integrity one.

.EXAMPLE
    ./verify-catalogue.ps1                 # CI gate
    ./verify-catalogue.ps1 -Update         # re-pin every mod to its current latest release
    ./verify-catalogue.ps1 -Only AI-Backend
#>
[CmdletBinding()]
param(
    [string]$Catalogue = (Join-Path (Split-Path -Parent $PSScriptRoot) 'mods.json'),
    # Resolve each mod's latest release and rewrite the pins. Review the diff before committing.
    [switch]$Update,
    # Restrict to one repo name.
    [string]$Only,
    [string]$Token = $env:GH_TOKEN
)

$ErrorActionPreference = 'Stop'
$scanner = Join-Path $PSScriptRoot 'scan-capabilities.ps1'

function Api($url) {
    $headers = @{ 'User-Agent' = 'swyf-modding-catalogue-check'; 'Accept' = 'application/vnd.github+json' }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    Invoke-RestMethod -Uri $url -Headers $headers -UseBasicParsing
}

function Download($url, $dest) {
    $headers = @{ 'User-Agent' = 'swyf-modding-catalogue-check' }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    Invoke-WebRequest -Uri $url -Headers $headers -OutFile $dest -UseBasicParsing
}

$cat = Get-Content $Catalogue -Raw | ConvertFrom-Json
$work = Join-Path ([IO.Path]::GetTempPath()) ('swyf-verify-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

$problems = New-Object System.Collections.ArrayList
$checked = 0

foreach ($mod in $cat.mods) {
    if ($Only -and $mod.repo -ne $Only) { continue }
    Write-Host ""
    Write-Host "$($mod.displayName)  ($($mod.owner)/$($mod.repo))" -ForegroundColor Cyan

    # Which release are we looking at?
    $tag = $null
    if ($Update) {
        $rel = Api "https://api.github.com/repos/$($mod.owner)/$($mod.repo)/releases/latest"
        $tag = $rel.tag_name
    } else {
        $tag = $mod.approvedVersion
        if (-not $tag) {
            [void]$problems.Add("$($mod.repo): no approvedVersion pinned")
            Write-Host "  NOT PINNED" -ForegroundColor Red
            continue
        }
        $rel = Api "https://api.github.com/repos/$($mod.owner)/$($mod.repo)/releases/tags/$tag"
    }
    Write-Host "  release   : $tag"

    $asset = $rel.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    if (-not $asset) {
        [void]$problems.Add("$($mod.repo): release $tag has no .zip asset")
        Write-Host "  NO ZIP ASSET" -ForegroundColor Red
        continue
    }

    $zip = Join-Path $work $asset.name
    Download $asset.browser_download_url $zip
    $scan = & $scanner -Path $zip -Json | ConvertFrom-Json
    if ($scan -isnot [array]) { $scan = @($scan) }

    # Setup steps are unpacked separately: the scanner reads assemblies, and a .ps1 is not one.
    # They still need pinning, because a setup step is PowerShell that runs on the machine.
    $unpacked = Join-Path $work ([IO.Path]::GetFileNameWithoutExtension($asset.name) + '-files')
    if (Test-Path $unpacked) { Remove-Item $unpacked -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $unpacked | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $unpacked)

    foreach ($file in $mod.files) {
        $found = $scan | Where-Object { $_.file -eq $file.fileName } | Select-Object -First 1
        if (-not $found) {
            [void]$problems.Add("$($mod.repo): $($file.fileName) is not in release $tag")
            Write-Host "  MISSING   : $($file.fileName)" -ForegroundColor Red
            continue
        }

        $caps = @($found.capabilities)
        $capText = if ($caps.Count) { $caps -join ', ' } else { 'none' }

        if ($Update) {
            $file | Add-Member -NotePropertyName sha256 -NotePropertyValue $found.sha256 -Force
            $file | Add-Member -NotePropertyName capabilities -NotePropertyValue $caps -Force
            Write-Host "  pinned    : $($file.fileName)" -ForegroundColor Green
            Write-Host "              sha256 $($found.sha256)"
            Write-Host "              caps   $capText"
            continue
        }

        $checked++
        if ($file.sha256 -ne $found.sha256) {
            [void]$problems.Add("$($mod.repo)/$($file.fileName): sha256 mismatch - pinned $($file.sha256), got $($found.sha256)")
            Write-Host "  SHA MISMATCH: $($file.fileName)" -ForegroundColor Red
            continue
        }

        $pinned = @($file.capabilities) | Sort-Object
        $gained = @($caps | Where-Object { $pinned -notcontains $_ })
        $lost = @($pinned | Where-Object { $caps -notcontains $_ })
        if ($gained.Count -or $lost.Count) {
            if ($gained.Count) { [void]$problems.Add("$($mod.repo)/$($file.fileName): GAINED capability: $($gained -join ', ')") }
            if ($lost.Count) { [void]$problems.Add("$($mod.repo)/$($file.fileName): lost capability: $($lost -join ', ')") }
            Write-Host "  CAPABILITY CHANGE: $($file.fileName)" -ForegroundColor Red
        } else {
            Write-Host "  ok        : $($file.fileName)  [$capText]" -ForegroundColor Green
        }
    }

    foreach ($step in @($mod.postInstall)) {
        if (-not $step) { continue }
        $scriptPath = Join-Path $unpacked $step.script
        if (-not (Test-Path $scriptPath)) {
            [void]$problems.Add("$($mod.repo): setup step $($step.script) is not in release $tag")
            Write-Host "  MISSING SETUP STEP: $($step.script)" -ForegroundColor Red
            continue
        }

        $scriptHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $scriptPath).Hash.ToLowerInvariant()

        if ($Update) {
            $step | Add-Member -NotePropertyName sha256 -NotePropertyValue $scriptHash -Force
            Write-Host "  pinned    : $($step.script) (setup step)" -ForegroundColor Green
            Write-Host "              sha256 $scriptHash"
            continue
        }

        $checked++
        if ($step.sha256 -ne $scriptHash) {
            [void]$problems.Add("$($mod.repo)/$($step.script): setup step sha256 mismatch - pinned $($step.sha256), got $scriptHash")
            Write-Host "  SETUP STEP CHANGED: $($step.script)" -ForegroundColor Red
        } else {
            Write-Host "  ok        : $($step.script) (setup step)" -ForegroundColor Green
        }
    }

    if ($Update) { $mod | Add-Member -NotePropertyName approvedVersion -NotePropertyValue $tag -Force }
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

if ($Update) {
    # schemaVersion stays as it is. The shipped Switchboard hard-fails on anything but 1
    # (`if (schema != 1) throw`), while ignoring fields it does not know - so the pins
    # below are additive and safe. Bump only once a Switchboard version that reads them has shipped.
    # Windows PowerShell 5.1 writes a BOM and eccentric indentation here; pwsh 7 is clean.
    # Either way the bytes are valid JSON - reformat before committing if it looks odd.
    $json = ($cat | ConvertTo-Json -Depth 10).TrimEnd() + "`n"
    [IO.File]::WriteAllText($Catalogue, $json, (New-Object Text.UTF8Encoding($false)))
    Write-Host ""
    Write-Host "Rewrote $Catalogue. Review the diff before committing." -ForegroundColor Cyan
    return
}

Write-Host ""
if ($problems.Count -eq 0) {
    Write-Host "All $checked pinned file(s) match their approved hash and capabilities." -ForegroundColor Green
    exit 0
}
Write-Host "PROBLEMS" -ForegroundColor Red
foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
Write-Host ""
Write-Host "A capability change is not automatically bad - it means a human needs to read the" -ForegroundColor Yellow
Write-Host "new release and, if it is fine, update mods.json to record the new pin." -ForegroundColor Yellow
exit 1
