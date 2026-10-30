<#
.SYNOPSIS
    Writes releases.json: what GitHub says about every entry, so that Switchboard does not have to ask.

.DESCRIPTION
    Switchboard reads releases/latest and releases/tags/<pin> per entry to fill the Get mods tab.
    That is one or two calls per mod against an unauthenticated limit of 60 an hour, so the ceiling
    arrives after three refreshes and lands on every row at once.

    This runs with a token, once, and writes what it read to a file in this repository. Switchboard
    then reads that file off raw.githubusercontent, which is a static GET and counts against
    nothing. The trade is freshness: an entry approved after this last ran falls back to the API
    for that entry only, so the list is never emptier than it was without the snapshot.

    A release that cannot be read is recorded as a problem on its entry rather than failing the
    run. An author who deletes a tag should not stop every other mod being published.

.EXAMPLE
    ./write-releases.ps1
    ./write-releases.ps1 -Out ./releases.json -Only chaos-mode
#>
[CmdletBinding()]
param(
    [string]$Catalogue = (Join-Path (Split-Path -Parent $PSScriptRoot) 'mods.json'),
    [string]$Out = (Join-Path (Split-Path -Parent $PSScriptRoot) 'releases.json'),
    # Restrict to these repo names, for trying out one entry.
    [string[]]$Only,
    [string]$Token = $env:GH_TOKEN
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'catalogue-rules.ps1')

# Not optional. Two calls per mod is under 60 only for a short list, and a snapshot that silently
# took the unauthenticated path would fail halfway through and publish a file with holes in it.
if (-not $Token) {
    throw "GH_TOKEN is not set. The snapshot reads two releases per mod, which needs a token."
}

function Api($url) {
    $headers = @{ 'User-Agent' = 'swyf-modding-catalogue-check'; 'Accept' = 'application/vnd.github+json' }
    $headers['Authorization'] = "Bearer $Token"
    try {
        return Invoke-RestMethod -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 60
    }
    catch {
        throw "GitHub did not answer $url : $($_.Exception.Message)"
    }
}

function Read-Release($owner, $repo, $tag) {
    $url = if ($tag) {
        "https://api.github.com/repos/$owner/$repo/releases/tags/$tag"
    }
    else {
        "https://api.github.com/repos/$owner/$repo/releases/latest"
    }

    $release = Api $url
    $asset = @($release.assets | Where-Object { $_.name -like '*.zip' }) | Select-Object -First 1
    if (-not $asset) { throw "release $($release.tag_name) has no .zip asset" }

    # GitHub publishes a digest per asset and Switchboard already carries it as an integrity check.
    # Absent on older releases, so it is optional here and null in the file.
    $digest = $null
    if ($asset.PSObject.Properties['digest'] -and $asset.digest) {
        $digest = ([string]$asset.digest) -replace '^sha256:', ''
    }

    return [ordered]@{
        tag    = [string]$release.tag_name
        asset  = [string]$asset.name
        url    = [string]$asset.browser_download_url
        size   = [long]$asset.size
        sha256 = $digest
        page   = [string]$release.html_url
    }
}

$catalogueData = Read-Catalogue -Path $Catalogue
$entries = @()

foreach ($mod in (Get-Field $catalogueData 'mods')) {
    $repo = [string](Get-Field $mod 'repo')
    if ($Only -and $Only -notcontains $repo) { continue }

    $owner = [string](Get-Field $mod 'owner')
    if ([string]::IsNullOrWhiteSpace($owner)) { $owner = 'swyf-modding' }

    $pin = [string](Get-Field $mod 'approvedVersion')
    if ([string]::IsNullOrWhiteSpace($pin)) { $pin = $null }

    Write-Host "$owner/$repo" -ForegroundColor Cyan

    $entry = [ordered]@{ owner = $owner; repo = $repo; pinned = $null; newest = $null; problem = $null }

    try {
        $entry.pinned = Read-Release $owner $repo $pin
        Write-Host "  listed $($entry.pinned.tag), $($entry.pinned.asset)" -ForegroundColor DarkGray
    }
    catch {
        $entry.problem = "the listed release could not be read: $($_.Exception.Message)"
        Write-Host "  $($entry.problem)" -ForegroundColor Yellow
    }

    try {
        $entry.newest = Read-Release $owner $repo $null
        if ($entry.newest.tag -ne $(if ($entry.pinned) { $entry.pinned.tag } else { '' })) {
            Write-Host "  newest $($entry.newest.tag)" -ForegroundColor DarkGray
        }
    }
    catch {
        if (-not $entry.problem) {
            $entry.problem = "the newest release could not be read: $($_.Exception.Message)"
        }
        Write-Host "  the newest release could not be read" -ForegroundColor Yellow
    }

    $entries += , $entry
}

$entries = @($entries | Sort-Object { $_.repo })

$model = [ordered]@{
    schemaVersion = 1
    generatedAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    mods          = $entries
}

$json = (ConvertTo-JsonValue -Value $model -Depth 0) + "`n"
$full = Resolve-FullPath $Out
$directory = [IO.Path]::GetDirectoryName($full)
if ($directory -and -not (Test-Path $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
[IO.File]::WriteAllText($full, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host "Wrote $($entries.Count) entries to $full" -ForegroundColor Green
