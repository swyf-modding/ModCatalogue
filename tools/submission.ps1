<#
.SYNOPSIS
    Turns a mod submission into a checked catalogue entry.

.DESCRIPTION
    Downloads the release, scans it, and checks that what the entry names is what the release
    holds - both directions, because half an entry is how a mod ends up installed with its
    library missing. Writes the new catalogue and a report; commits nothing.

.EXAMPLE
    ./tools/submission.ps1 -BodyFile ./submission.md -OutDir ./out

.OUTPUTS
    ./out/mods.json and ./out/submission-report.md.
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
    [string]$Token = $env:GH_TOKEN,

    # Check the submission and stop, without writing anything.
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'catalogue-rules.ps1')

$api = 'https://api.github.com'
$scanner = Join-Path $PSScriptRoot 'scan-capabilities.ps1'

if (-not $Body -and $BodyFile) { $Body = Get-Content -Raw -LiteralPath $BodyFile }
if (-not $Body) { throw 'The submission has no body: pass -Body or -BodyFile.' }

# ---------------------------------------------------------------- the entry

<#
    The entry the submission carries.

    It is a fenced JSON block in the issue body. A body that is nothing but JSON is read as
    the entry too, so a submission can be written by hand and sent this way.
#>
function Get-EntryJson([string]$Text) {
    $match = [regex]::Match($Text, '(?s)```json\s*(.*?)\s*```')
    if ($match.Success) { $candidate = $match.Groups[1].Value }
    else { $candidate = $Text.Trim() }

    if (-not $candidate) { throw 'The submission does not contain an entry.' }

    try { return ($candidate | ConvertFrom-Json) }
    catch { throw "The entry in the submission is not valid JSON: $($_.Exception.Message)" }
}

<#
    The release the submission says it is about, which the body carries as a line.
    It is a note, not the source of truth: Switchboard installs releases/latest, so that is
    what the entry is pinned to.
#>
function Get-StatedRelease([string]$Text) {
    $match = [regex]::Match($Text, '(?im)^\*\*Release:\*\*\s*(.+?)\s*$')
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return $null
}

$entry = ConvertTo-PlainObject (Get-EntryJson $Body)
$statedRelease = Get-StatedRelease $Body

if (-not (Get-Field $entry 'owner')) { $entry['owner'] = $CatalogueLimits.DefaultOwner }

# The shape of the entry first: a release worth downloading is a question worth asking only
# of an entry that could be listed at all.
$entryProblems = Test-CatalogueEntry -Entry $entry -Label 'the submitted entry'
if ($entryProblems.Count -gt 0) {
    Write-Host ''
    Write-Host 'The submission did not pass:' -ForegroundColor Red
    foreach ($problem in $entryProblems) { Write-Host "  - $problem" -ForegroundColor Red }
    throw "The submission is not a valid catalogue entry ($($entryProblems.Count) problem(s))."
}

$owner = (Get-Field $entry 'owner').Trim()
$repo = (Get-Field $entry 'repo').Trim()
$displayName = (Get-Field $entry 'displayName').Trim()
$summary = (Get-Field $entry 'summary').Trim()
$entryFiles = Get-Field $entry 'files'

# ---------------------------------------------------------------- the release

$headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'swyf-modding-catalogue' }
if ($Token) { $headers['Authorization'] = "Bearer $Token" }

Write-Host "Checking $owner/$repo ..."

# A bounded request: a submission that hangs is a submission that says nothing.
try {
    $release = Invoke-RestMethod -Uri "$api/repos/$owner/$repo/releases/latest" -Headers $headers -TimeoutSec 60
}
catch {
    throw "GitHub did not answer for $owner/$repo : $($_.Exception.Message)"
}

if ($release.draft -or $release.prerelease) {
    throw "The latest release ($($release.tag_name)) is a draft or a prerelease, so it is not the one Switchboard would install from."
}

if ($statedRelease -and $statedRelease -ne $release.tag_name) {
    Write-Host "NOTE: the submission named $statedRelease, but Switchboard installs releases/latest, which is $($release.tag_name). The entry is pinned to the latter." -ForegroundColor Yellow
}

$zipAsset = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
if (-not $zipAsset) { throw 'The latest release has no .zip asset, so there is nothing to install from.' }

# The temp folder holds the download for as long as this script needs it: the setup scripts
# are hashed from it after the checks have run.
$temp = Join-Path ([IO.Path]::GetTempPath()) ('swyf-submission-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$zip = Join-Path $temp $zipAsset.name
$unpacked = Join-Path $temp 'unpacked'

try {
    Write-Host "Downloading $($zipAsset.name) ..."
    try {
        # No Authorization header: a release asset is public, and the URL redirects to a
        # CDN. The token is for the API, not for whatever host the redirect names.
        $downloadHeaders = @{ 'User-Agent' = 'swyf-modding-catalogue' }
        Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $zip -Headers $downloadHeaders -TimeoutSec 300
    }
    catch {
        throw "The release could not be downloaded : $($_.Exception.Message)"
    }

    # ---------------------------------------------------------------- the code

    Write-Host 'Reading the code ...'
    $json = (& $scanner -Path $zip -Json) -join "`n"
    $scan = @($json | ConvertFrom-Json)

    if ($scan.Count -eq 0) { throw 'The release holds no .NET assembly this can read, so there is nothing to install.' }

    # The setup steps are not assemblies, so the scanner does not see them. The zip is
    # unpacked separately to find them, and to know what is at the top of the download.
    Write-Host 'Unpacking the release ...'
    $releaseNames = Expand-Release -ZipPath $zip -Destination $unpacked

    $byName = @{}
    foreach ($s in $scan) { $byName[$s.file] = $s }

    # ---------------------------------------------------------------- the checks

    $problems = New-Object System.Collections.ArrayList
    $notes = New-Object System.Collections.ArrayList

    # Every file named must be in the release at the top, and every assembly in it must be
    # named: a half entry installs a mod with its library missing.
    foreach ($f in $entryFiles) {
        $name = (Get-Field $f 'fileName').Trim()

        if (-not $byName.ContainsKey($name)) {
            [void]$problems.Add("the entry names $name, which is not in the release")
            continue
        }

        # Switchboard only installs what is at the top of the unpacked download.
        if (-not $byName[$name].atRoot) {
            [void]$problems.Add("the release holds $name in $($byName[$name].path), and Switchboard installs only what is at the top of the download")
        }
    }

    foreach ($s in $scan) {
        $named = @($entryFiles | Where-Object { (Get-Field $_ 'fileName').Trim() -eq $s.file })
        if ($named.Count -eq 0) { [void]$problems.Add("the release holds $($s.file), which the entry does not name") }
    }

    # The shared library goes to core and is not a plugin; core is for it and nothing else.
    foreach ($f in $entryFiles) {
        $name = (Get-Field $f 'fileName').Trim()
        $folder = (Get-Field $f 'folder').Trim().ToLowerInvariant()

        $isLibrary = $name -ieq $CatalogueLimits.SharedLibrary
        if ($isLibrary -and ($folder -ne 'core' -or (Get-Field $f 'expectsPluginAttribute') -ne $false)) {
            [void]$problems.Add("$name is the shared library, so it belongs in core and is not a plugin")
        }
        if (-not $isLibrary -and $folder -eq 'core') {
            [void]$problems.Add("$name is routed to core, and core is for the shared library ($($CatalogueLimits.SharedLibrary)) only")
        }
    }

    # A plugin without the attribute is never loaded; a version BepInEx cannot parse is the
    # same, so both are refused here rather than discovered in a log.
    foreach ($f in $entryFiles) {
        $name = (Get-Field $f 'fileName').Trim()
        if (-not $byName.ContainsKey($name)) { continue }
        $s = $byName[$name]
        $hasAttribute = @($s.bepInPlugin).Count -gt 0

        if ((Get-Field $f 'expectsPluginAttribute') -and -not $hasAttribute) {
            [void]$problems.Add("$name has no [BepInPlugin] attribute, so the loader would never load it")
        }
        if (-not (Get-Field $f 'expectsPluginAttribute') -and $hasAttribute) {
            [void]$problems.Add("$name carries a [BepInPlugin] attribute, so it is a plugin and belongs in plugins")
        }

        if ($hasAttribute) {
            foreach ($p in $s.bepInPlugin) {
                [void]$notes.Add("$name declares $p")
                $version = Get-BepInPluginVersion $p
                if ($version -and -not (Test-BepInExVersion $version)) {
                    [void]$problems.Add("$name declares the version $version, which BepInEx cannot parse - the plugin would install and do nothing")
                }
            }
        }
    }

    # A setup script has to be there, at the top of the download, small enough to show, and
    # not empty.
    $submittedSteps = Get-Field $entry 'postInstall'
    if ($null -ne $submittedSteps) {
        foreach ($step in $submittedSteps) {
            if ($null -eq $step) { continue }
            $script = (Get-Field $step 'script').Trim()

            if ($releaseNames -notcontains $script) {
                $nested = @($releaseNames | Where-Object { $_ -like "*/$script" })
                if ($nested.Count -gt 0) {
                    [void]$problems.Add("the setup script $script is in $($nested[0]) in the release, and Switchboard looks for it at the top of the download")
                }
                else {
                    [void]$problems.Add("the release does not contain the setup script $script")
                }
                continue
            }

            $scriptPath = Join-Path $unpacked $script
            $size = (Get-Item -LiteralPath $scriptPath).Length
            if ($size -gt $CatalogueLimits.MaxScriptBytes) {
                [void]$problems.Add("the setup script $script is $size bytes, which is over the $($CatalogueLimits.MaxScriptBytes) a setup step may be")
            }
            if ([string]::IsNullOrWhiteSpace((Get-Content -Raw -LiteralPath $scriptPath))) {
                [void]$problems.Add("the setup script $script is empty, so there is nothing to run")
            }
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
    foreach ($f in $entryFiles) {
        $name = (Get-Field $f 'fileName').Trim()
        $s = $byName[$name]
        $file = [ordered]@{
            fileName               = $name
            folder                 = (Get-Field $f 'folder').Trim()
            expectsPluginAttribute = [bool](Get-Field $f 'expectsPluginAttribute')
            sha256                 = $s.sha256
            capabilities           = @($s.capabilities)
        }
        if (@($s.bepInPlugin).Count -gt 0) { $file['bepInPlugin'] = @($s.bepInPlugin) }
        $files += ,$file
    }

    # Setup steps are pinned like everything else: a script reaches a shell, so it is hashed.
    $postInstall = @()
    if ($null -ne $submittedSteps) {
        foreach ($step in $submittedSteps) {
            if ($null -eq $step) { continue }
            $script = (Get-Field $step 'script').Trim()
            $scriptPath = Join-Path $unpacked $script
            $postInstall += ,([ordered]@{
                script      = $script
                description = (Get-Field $step 'description').Trim()
                sha256      = (Get-FileHash -Algorithm SHA256 -LiteralPath $scriptPath).Hash.ToLowerInvariant()
            })
        }
    }

    $new = [ordered]@{
        owner           = $owner
        repo            = $repo
        displayName     = $displayName
        summary         = $summary
        approvedVersion = $release.tag_name
        files           = $files
    }
    if ($postInstall.Count -gt 0) { $new['postInstall'] = $postInstall }

    # ---------------------------------------------------------------- the catalogue

    $catalogue = Read-Catalogue -Path $CataloguePath

    # A broken catalogue is refused whole, so say so here rather than writing on top of it.
    $existingProblems = Test-Catalogue -Catalogue $catalogue
    if ($existingProblems.Count -gt 0) {
        Write-Host ''
        Write-Host 'The catalogue is already not valid:' -ForegroundColor Red
        foreach ($p in $existingProblems) { Write-Host "  - $p" -ForegroundColor Red }
        throw 'Fix the catalogue before adding to it (tools/check-catalogue.ps1 says what is wrong).'
    }

    $catalogueMods = Get-Field $catalogue 'mods'
    $existing = @($catalogueMods | Where-Object {
        (Get-Field $_ 'owner').ToLowerInvariant() -eq $owner.ToLowerInvariant() -and
        (Get-Field $_ 'repo').ToLowerInvariant() -eq $repo.ToLowerInvariant()
    })

    if ($existing.Count -gt 0) {
        Write-Host "The catalogue already has $owner/$repo; it will be updated in place."

        # A setup step belongs to the mod, not the submission, so one already listed carries
        # over when the submission does not mention it.
        if ($postInstall.Count -eq 0) {
            $carried = Get-Field $existing[0] 'postInstall'
            if ($null -ne $carried) {
                foreach ($step in $carried) {
                    if ($null -eq $step) { continue }
                    $script = (Get-Field $step 'script').Trim()
                    $scriptPath = Join-Path $unpacked $script
                    if (Test-Path -LiteralPath $scriptPath) {
                        Write-Host "Keeping the setup step $script, which the submission did not mention." -ForegroundColor Yellow
                        $postInstall += ,([ordered]@{
                            script      = $script
                            description = (Get-Field $step 'description').Trim()
                            sha256      = (Get-FileHash -Algorithm SHA256 -LiteralPath $scriptPath).Hash.ToLowerInvariant()
                        })
                    }
                    else {
                        Write-Host "WARNING: the release no longer holds the setup step $script, so it has been dropped." -ForegroundColor Yellow
                    }
                }
                if ($postInstall.Count -gt 0) { $new['postInstall'] = $postInstall }
            }
        }

        $catalogue['mods'] = @($catalogueMods | ForEach-Object {
            if ((Get-Field $_ 'owner').ToLowerInvariant() -eq $owner.ToLowerInvariant() -and
                (Get-Field $_ 'repo').ToLowerInvariant() -eq $repo.ToLowerInvariant()) { $new } else { $_ }
        })
    }
    else {
        $catalogue['mods'] = @($catalogueMods) + @($new)
    }

    # Alphabetical by repository, so the file reads the same way twice.
    $catalogue['mods'] = Sort-CatalogueMods -Mods $catalogue['mods']

    # The file that is about to be written has to be one Switchboard will accept.
    $newProblems = Test-Catalogue -Catalogue $catalogue
    if ($newProblems.Count -gt 0) {
        Write-Host ''
        Write-Host 'The new catalogue is not valid, so it was not written:' -ForegroundColor Red
        foreach ($p in $newProblems) { Write-Host "  - $p" -ForegroundColor Red }
        throw "The new catalogue has $($newProblems.Count) problem(s)."
    }

    if ($CheckOnly) {
        Write-Host ''
        Write-Host 'The submission passes every check. Nothing was written (-CheckOnly).' -ForegroundColor Green
        exit 0
    }

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $newPath = Join-Path $OutDir 'mods.json'
    Save-Catalogue -Catalogue $catalogue -Path $newPath

    # ---------------------------------------------------------------- the report

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("# Submission: $owner/$repo")
    [void]$lines.Add('')
    [void]$lines.Add("**Release:** $($release.tag_name)")
    [void]$lines.Add('')
    [void]$lines.Add('| File | Folder | Plugin | SHA-256 | Capabilities |')
    [void]$lines.Add('|---|---|---|---|---|')
    foreach ($f in $files) {
        [void]$lines.Add("| $($f.fileName) | $($f.folder) | $($f.expectsPluginAttribute) | ``$($f.sha256)`` | $($f.capabilities -join ', ') |")
    }
    [void]$lines.Add('')

    if ($postInstall.Count -gt 0) {
        [void]$lines.Add('## Setup steps')
        [void]$lines.Add('')
        [void]$lines.Add('| Script | SHA-256 | Description |')
        [void]$lines.Add('|---|---|---|')
        foreach ($step in $postInstall) {
            [void]$lines.Add("| $($step.script) | ``$($step.sha256)`` | $($step.description) |")
        }
        [void]$lines.Add('')
    }

    if ($notes.Count -gt 0) {
        [void]$lines.Add('## What the code declares')
        [void]$lines.Add('')
        foreach ($n in $notes) { [void]$lines.Add("- $n") }
        [void]$lines.Add('')
    }

    $reportPath = Join-Path $OutDir 'submission-report.md'
    [IO.File]::WriteAllText((Resolve-FullPath $reportPath), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

    Write-Host ''
    Write-Host 'The submission passed. The new catalogue is at ' -ForegroundColor Green -NoNewline
    Write-Host $newPath -ForegroundColor Green
    Write-Host 'The report is at ' -ForegroundColor Green -NoNewline
    Write-Host $reportPath -ForegroundColor Green
}
finally {
    if (Test-Path $temp) { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
