<#
.SYNOPSIS
    Checks that every pinned release in mods.json is still exactly what was approved.

.DESCRIPTION
    Downloads each pinned release, verifies the recorded hashes, rescans the assemblies, and
    fails if the bytes or the capabilities moved - so a capability cannot appear in a release
    without someone editing mods.json to say so.

    It also catches what would break an install: a file not at the top of the download, the
    shared library misrouted, a plugin with no [BepInPlugin] or an unparseable version, an
    assembly the entry does not name, and a setup script that is missing.

    GitHub's digest comes from the same place as the file, so it only proves the download was
    not mangled. The hashes here were recorded at review time, which is what makes this an
    authenticity check rather than an integrity one.

.EXAMPLE
    ./verify-catalogue.ps1                 # CI gate
    ./verify-catalogue.ps1 -Update         # re-pin every mod to its current latest release
    ./verify-catalogue.ps1 -Refresh        # re-read the pinned releases, keeping the pins
    ./verify-catalogue.ps1 -Only AI-Backend
#>
[CmdletBinding()]
param(
    # The catalogue to check. Named apart from the variable the parsed catalogue is held in,
    # because PowerShell does not distinguish $Catalogue from $catalogue.
    [string]$Catalogue = (Join-Path (Split-Path -Parent $PSScriptRoot) 'mods.json'),
    # Resolve each mod's latest release and rewrite the pins. Review the diff before committing.
    [switch]$Update,
    # Read the pinned releases again and rewrite what they record - the hashes, the
    # capabilities, the attribute - without moving the pin to a different release.
    [switch]$Refresh,
    # Restrict to one repo name.
    [string]$Only,
    [string]$Token = $env:GH_TOKEN
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'catalogue-rules.ps1')

$scanner = Join-Path $PSScriptRoot 'scan-capabilities.ps1'

# Whether the pins are rewritten. -Update moves the pin to the latest release; -Refresh keeps
# the release and re-reads what it holds.
$pin = $Update -or $Refresh

function Api($url) {
    $headers = @{ 'User-Agent' = 'swyf-modding-catalogue-check'; 'Accept' = 'application/vnd.github+json' }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    # A bounded request: a gate that hangs is a gate that says nothing.
    try {
        return Invoke-RestMethod -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 60
    }
    catch {
        throw "GitHub did not answer $url : $($_.Exception.Message)"
    }
}

function Download($url, $dest) {
    # Deliberately no Authorization header. A release asset is public, the URL redirects to
    # a CDN, and a token that is not needed for the request should not be offered to
    # whatever host the redirect names.
    $headers = @{ 'User-Agent' = 'swyf-modding-catalogue-check' }
    try {
        Invoke-WebRequest -Uri $url -Headers $headers -OutFile $dest -UseBasicParsing -TimeoutSec 300
    }
    catch {
        throw "The release could not be downloaded from $url : $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- the file itself

if (-not (Test-Path $Catalogue)) { throw "There is no catalogue at $Catalogue." }

try { $catalogueData = Read-Catalogue -Path $Catalogue }
catch { throw "The catalogue at $Catalogue could not be read as JSON: $($_.Exception.Message)" }

# A catalogue that does not follow the rules is one Switchboard refuses whole, so there is
# nothing to check the pins of until it does.
$shapeProblems = Test-Catalogue -Catalogue $catalogueData
if ($shapeProblems.Count -gt 0) {
    Write-Host ''
    Write-Host 'PROBLEMS' -ForegroundColor Red
    foreach ($p in $shapeProblems) { Write-Host "  - $p" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'The catalogue does not follow the rules, so its pins were not checked.' -ForegroundColor Yellow
    Write-Host 'tools/check-catalogue.ps1 says the same thing without touching the network.' -ForegroundColor Yellow
    exit 1
}

foreach ($p in (Test-CatalogueOrder -Catalogue $catalogueData)) {
    Write-Host "NOTE: $p" -ForegroundColor Yellow
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('swyf-verify-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $work | Out-Null

$problems = New-Object System.Collections.ArrayList
$checked = 0
$changed = $false

try {
    $mods = Get-Field $catalogueData 'mods'

    foreach ($mod in $mods) {
        $repo = Get-Field $mod 'repo'
        if ($Only -and $repo -ne $Only) { continue }

        # An entry with no owner belongs to the project's own account.
        $owner = Get-Field $mod 'owner'
        if ($null -eq $owner -or [string]::IsNullOrWhiteSpace($owner)) { $owner = $CatalogueLimits.DefaultOwner }

        Write-Host ''
        Write-Host "$((Get-Field $mod 'displayName'))  ($owner/$repo)" -ForegroundColor Cyan

        # Which release are we looking at?
        $tag = $null
        try {
            if ($Update) {
                $rel = Api "https://api.github.com/repos/$owner/$repo/releases/latest"
                $tag = $rel.tag_name
            }
            else {
                $tag = Get-Field $mod 'approvedVersion'
                if (-not $tag) {
                    [void]$problems.Add("$($repo): no approvedVersion pinned")
                    Write-Host '  NOT PINNED' -ForegroundColor Red
                    continue
                }
                $rel = Api "https://api.github.com/repos/$owner/$repo/releases/tags/$tag"
            }
        }
        catch {
            # One mod that cannot be reached is not a reason to stop looking at the others:
            # the rest of the catalogue still deserves to be checked, and the mod that
            # could not be reached is reported as unchecked rather than as fine.
            [void]$problems.Add("$($repo): the release could not be read - $($_.Exception.Message)")
            Write-Host '  COULD NOT BE READ' -ForegroundColor Red
            continue
        }
        Write-Host "  release   : $tag"

        $asset = $rel.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
        if (-not $asset) {
            [void]$problems.Add("$($repo): release $tag has no .zip asset")
            Write-Host '  NO ZIP ASSET' -ForegroundColor Red
            continue
        }

        $zip = Join-Path $work $asset.name
        try {
            Download $asset.browser_download_url $zip
        }
        catch {
            [void]$problems.Add("$($repo): the release could not be downloaded - $($_.Exception.Message)")
            Write-Host '  COULD NOT BE DOWNLOADED' -ForegroundColor Red
            continue
        }

        $scanJson = (& $scanner -Path $zip -Json) -join "`n"
        $scan = @($scanJson | ConvertFrom-Json)

        $byName = @{}
        foreach ($s in $scan) { $byName[$s.file] = $s }

        # The setup steps are unpacked separately: the scanner reads assemblies, not .ps1 files.
        $unpacked = Join-Path $work ([IO.Path]::GetFileNameWithoutExtension($asset.name) + '-files')
        if (Test-Path $unpacked) { Remove-Item $unpacked -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $unpacked | Out-Null
        $releaseNames = Expand-Release -ZipPath $zip -Destination $unpacked

        $files = Get-Field $mod 'files'
        foreach ($file in $files) {
            $name = Get-Field $file 'fileName'
            $found = $byName[$name]

            if (-not $found) {
                [void]$problems.Add("$($repo): $name is not in release $tag")
                Write-Host "  MISSING   : $name" -ForegroundColor Red
                continue
            }

            # Switchboard only installs what is at the top of the download.
            if (-not $found.atRoot) {
                [void]$problems.Add("$($repo): $name is in $($found.path) in release $tag, and switchboard installs only what is at the top of the download")
                Write-Host "  IN A FOLDER: $name" -ForegroundColor Red
                continue
            }

            $caps = @($found.capabilities)
            $capText = if ($caps.Count) { $caps -join ', ' } else { 'none' }

            # The shared library is not a plugin, and the loader is what decides that.
            $isLibrary = $name -ieq $CatalogueLimits.SharedLibrary
            if ($isLibrary -and ((Get-Field $file 'folder') -ne 'core' -or (Get-Field $file 'expectsPluginAttribute') -ne $false)) {
                [void]$problems.Add("$($repo): $name is the shared library, so it belongs in core and is not a plugin")
                Write-Host "  MISROUTED : $name" -ForegroundColor Red
            }
            if (-not $isLibrary -and (Get-Field $file 'folder') -eq 'core') {
                [void]$problems.Add("$($repo): $name is routed to core, and core is for the shared library only")
                Write-Host "  MISROUTED : $name" -ForegroundColor Red
            }

            $hasAttribute = @($found.bepInPlugin).Count -gt 0
            if ((Get-Field $file 'expectsPluginAttribute') -and -not $hasAttribute) {
                [void]$problems.Add("$($repo): $name has no [BepInPlugin] attribute, so the loader would never load it")
                Write-Host "  NO ATTRIBUTE: $name" -ForegroundColor Red
            }
            if (-not (Get-Field $file 'expectsPluginAttribute') -and $hasAttribute) {
                [void]$problems.Add("$($repo): $name carries a [BepInPlugin] attribute, so it is a plugin and belongs in plugins")
                Write-Host "  UNEXPECTED ATTRIBUTE: $name" -ForegroundColor Red
            }
            foreach ($declaration in @($found.bepInPlugin)) {
                $version = Get-BepInPluginVersion $declaration
                if ($version -and -not (Test-BepInExVersion $version)) {
                    [void]$problems.Add("$($repo): $name declares the version $version, which BepInEx cannot parse - the plugin would install and do nothing")
                    Write-Host "  UNPARSEABLE VERSION: $name $version" -ForegroundColor Red
                }
            }

            if ($pin) {
                # Plain dictionaries: Add-Member would add a property the dictionary never sees.
                $file['sha256'] = $found.sha256
                $file['capabilities'] = @($caps)
                if (@($found.bepInPlugin).Count -gt 0) { $file['bepInPlugin'] = @($found.bepInPlugin) }
                else { $file.Remove('bepInPlugin') }
                $changed = $true
                Write-Host "  pinned    : $name" -ForegroundColor Green
                Write-Host "              sha256 $($found.sha256)"
                Write-Host "              caps   $capText"
                continue
            }

            $checked++

            if ((Get-Field $file 'sha256') -ne $found.sha256) {
                [void]$problems.Add("$($repo)/$($name): sha256 mismatch - pinned $((Get-Field $file 'sha256')), got $($found.sha256)")
                Write-Host "  SHA MISMATCH: $name" -ForegroundColor Red
                continue
            }

            # The attribute the plugin declares is part of what was reviewed, so a change in
            # it is a change worth seeing.
            $pinnedDecls = Get-Field $file 'bepInPlugin'
            $pinned = @($pinnedDecls) | Sort-Object
            $foundDecls = @($found.bepInPlugin) | Sort-Object
            if (($pinned -join '|') -ne ($foundDecls -join '|')) {
                [void]$problems.Add("$($repo)/$($name): the [BepInPlugin] attribute changed - pinned '$($pinned -join ', ')', now '$($foundDecls -join ', ')'")
                Write-Host "  ATTRIBUTE CHANGED: $name" -ForegroundColor Red
            }

            $pinnedCapsValue = Get-Field $file 'capabilities'
            $pinnedCaps = @($pinnedCapsValue) | Sort-Object
            $gained = @($caps | Where-Object { $pinnedCaps -notcontains $_ })
            $lost = @($pinnedCaps | Where-Object { $caps -notcontains $_ })
            if ($gained.Count -or $lost.Count) {
                if ($gained.Count) { [void]$problems.Add("$($repo)/$($name): GAINED capability: $($gained -join ', ')") }
                if ($lost.Count) { [void]$problems.Add("$($repo)/$($name): lost capability: $($lost.Count -join ', ')") }
                Write-Host "  CAPABILITY CHANGE: $name" -ForegroundColor Red
            }
            else {
                Write-Host "  ok        : $name  [$capText]" -ForegroundColor Green
            }
        }

        # Every assembly in the release has to be named by the entry. One that is not named
        # is one nobody installs and nobody knows is there.
        if (-not $pin) {
            foreach ($s in $scan) {
                $named = $false
                foreach ($file in $files) {
                    if ((Get-Field $file 'fileName') -eq $s.file) { $named = $true; break }
                }
                if (-not $named) {
                    [void]$problems.Add("$($repo): the release holds $($s.file), which the entry does not name")
                    Write-Host "  UNNAMED  : $($s.file)" -ForegroundColor Red
                }
            }
        }

        # The setup steps
        $steps = Get-Field $mod 'postInstall'
        if ($null -ne $steps) {
            foreach ($step in $steps) {
                $script = Get-Field $step 'script'

                # The script has to be at the top of the download, by bare name: that is where
                # Switchboard looks for it.
                if ($releaseNames -notcontains $script) {
                    $nested = @($releaseNames | Where-Object { $_ -like "*/$script" })
                    if ($nested.Count -gt 0) {
                        [void]$problems.Add("$($repo): the setup script $script is in $($nested[0]) in release $tag, and switchboard looks for it at the top of the download")
                    }
                    else {
                        [void]$problems.Add("$($repo): setup step $script is not in release $tag")
                    }
                    Write-Host "  MISSING SETUP STEP: $script" -ForegroundColor Red
                    continue
                }

                $scriptPath = Join-Path $unpacked $script
                $scriptHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $scriptPath).Hash.ToLowerInvariant()

                if ($pin) {
                    $step['sha256'] = $scriptHash
                    $changed = $true
                    Write-Host "  pinned    : $script (setup step)" -ForegroundColor Green
                    Write-Host "              sha256 $scriptHash"
                    continue
                }

                $checked++
                if ((Get-Field $step 'sha256') -ne $scriptHash) {
                    [void]$problems.Add("$($repo)/$($script): setup step sha256 mismatch - pinned $((Get-Field $step 'sha256')), got $scriptHash")
                    Write-Host "  SETUP STEP CHANGED: $script" -ForegroundColor Red
                }
                else {
                    Write-Host "  ok        : $script (setup step)" -ForegroundColor Green
                }
            }
        }

        if ($Update) { $mod['approvedVersion'] = $tag }
    }
}
finally {
    if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($pin) {
    # The file that is about to be written has to be one Switchboard will accept.
    $newProblems = Test-Catalogue -Catalogue $catalogueData
    if ($newProblems.Count -gt 0) {
        Write-Host ''
        Write-Host 'The new catalogue is not valid, so it was not written:' -ForegroundColor Red
        foreach ($p in $newProblems) { Write-Host "  - $p" -ForegroundColor Red }
        exit 1
    }

    # The file is written in one shape, so the diff a person reads is the change and not
    # the formatting.
    $catalogueData['mods'] = Sort-CatalogueMods -Mods $catalogueData['mods']
    Save-Catalogue -Catalogue $catalogueData -Path $Catalogue
    Write-Host ''
    if ($changed) { Write-Host "Rewrote $Catalogue. Review the diff before committing." -ForegroundColor Cyan }
    else { Write-Host "Nothing changed. $Catalogue was rewritten in its canonical shape." -ForegroundColor Green }
    exit 0
}

Write-Host ''
if ($problems.Count -eq 0) {
    Write-Host "All $checked pinned file(s) match their approved hash and capabilities." -ForegroundColor Green
    exit 0
}
Write-Host 'PROBLEMS' -ForegroundColor Red
foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
Write-Host ''
Write-Host 'A capability change is not automatically bad - it means a human needs to read the' -ForegroundColor Yellow
Write-Host 'new release and, if it is fine, update mods.json to record the new pin.' -ForegroundColor Yellow
exit 1
