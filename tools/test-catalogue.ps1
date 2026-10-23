<#
.SYNOPSIS
    Tests the catalogue's rules. No network, no releases, no code.

.DESCRIPTION
    The rules are the part of this repository that can be wrong without anybody noticing for
    weeks: a rule that stops refusing what it used to refuse, or a writer that starts writing
    a different shape, breaks the gate and the submission tool in ways that only show up as a
    confusing failure much later.

    So they are tested here, in the same repository, runnable by hand and by CI:

        ./tools/test-catalogue.ps1

    It exits non-zero when something is wrong, so it can be a step in a workflow.
#>
[CmdletBinding()]
param(
    # The catalogue to test against.
    [string]$Catalogue = (Join-Path (Split-Path -Parent $PSScriptRoot) 'mods.json')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'catalogue-rules.ps1')

$failures = New-Object System.Collections.ArrayList

function Test-It {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        Write-Host "  ok    $Name" -ForegroundColor Green
    }
    catch {
        [void]$failures.Add("$Name : $($_.Exception.Message)")
        Write-Host "  FAIL  $Name" -ForegroundColor Red
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Because)
    if (-not $Condition) { throw $Because }
}

function Assert-False {
    param([bool]$Condition, [string]$Because)
    if ($Condition) { throw $Because }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Because)
    if ($Expected -ne $Actual) { throw "$Because (expected '$Expected', got '$Actual')" }
}

<#
    An entry as a plain object, from a JSON string.
#>
function Entry([string]$Json) {
    return (ConvertTo-PlainObject ($Json | ConvertFrom-Json))
}

Write-Host 'the names'

Test-It 'a bare dll name is fine' {
    Assert-True (Test-BareFileName 'YourMod.dll') 'a dll name should be accepted'
    Assert-True (Test-BareFileName 'Your.Mod.dll') 'dots in a name should be accepted'
}

Test-It 'a name with a path in it is not' {
    Assert-False (Test-BareFileName '../evil.dll') 'a parent reference should be refused'
    Assert-False (Test-BareFileName 'sub/evil.dll') 'a folder should be refused'
    Assert-False (Test-BareFileName 'sub\evil.dll') 'a folder should be refused'
    Assert-False (Test-BareFileName 'evil.txt') 'anything but a dll should be refused'
    Assert-False (Test-BareFileName '') 'an empty name should be refused'
}

Test-It 'a script name is held to the same rule' {
    Assert-True (Test-BareScriptName 'setup.ps1') 'a script name should be accepted'
    Assert-False (Test-BareScriptName '../setup.ps1') 'a parent reference should be refused'
    Assert-False (Test-BareScriptName 'setup.dll') 'anything but a ps1 should be refused'
}

Test-It 'an account name is a name and not a URL' {
    Assert-True (Test-AccountName 'swyf-modding') 'a normal name should be accepted'
    Assert-False (Test-AccountName 'github.com/owner/repo') 'a URL should be refused'
    Assert-False (Test-AccountName 'owner repo') 'a space should be refused'
}

Test-It 'a version BepInEx can parse is two to four numbers' {
    Assert-True (Test-BepInExVersion '1.2') 'two numbers should be accepted'
    Assert-True (Test-BepInExVersion '1.2.3') 'three numbers should be accepted'
    Assert-True (Test-BepInExVersion '1.2.3.4') 'four numbers should be accepted'
    Assert-False (Test-BepInExVersion '1') 'one number should be refused'
    Assert-False (Test-BepInExVersion '1.2.3+g0a1b2c3') 'build metadata should be refused'
    Assert-False (Test-BepInExVersion '1.2.3-beta') 'a pre-release suffix should be refused'
}

Test-It 'the version is read out of the attribute' {
    Assert-Equal '1.2.3' (Get-BepInPluginVersion 'guid | name | 1.2.3') 'the last part is the version'
    Assert-True ($null -eq (Get-BepInPluginVersion 'guid | name')) 'a short declaration has no version'
}

Write-Host 'the entries'

Test-It 'an entry with a file name that cannot be installed is refused' {
    $entry = Entry '{ "repo": "Thing", "displayName": "Thing", "summary": "A thing.",
        "files": [ { "fileName": "../evil.dll", "folder": "plugins", "expectsPluginAttribute": true } ] }'
    $problems = Test-CatalogueEntry -Entry $entry -Label 'the entry'
    Assert-True ($problems.Count -gt 0) 'the entry should have been refused'
}

Test-It 'an entry with a folder nobody accepts is refused' {
    $entry = Entry '{ "repo": "Thing", "displayName": "Thing", "summary": "A thing.",
        "files": [ { "fileName": "Thing.dll", "folder": "mods", "expectsPluginAttribute": true } ] }'
    $problems = Test-CatalogueEntry -Entry $entry -Label 'the entry'
    Assert-True ($problems.Count -gt 0) 'the entry should have been refused'
}

Test-It 'a pinned entry that does not pin everything is refused' {
    $entry = Entry '{ "repo": "Thing", "displayName": "Thing", "summary": "A thing.",
        "approvedVersion": "v1.0.0",
        "files": [ { "fileName": "Thing.dll", "folder": "plugins", "expectsPluginAttribute": true } ] }'
    $problems = Test-CatalogueEntry -Entry $entry -Label 'the entry'
    Assert-True ($problems.Count -gt 0) 'the entry should have been refused'
}

Test-It 'a pinned entry whose setup script has no hash is refused' {
    $entry = Entry '{ "repo": "Thing", "displayName": "Thing", "summary": "A thing.",
        "approvedVersion": "v1.0.0",
        "files": [ { "fileName": "Thing.dll", "folder": "plugins", "expectsPluginAttribute": true,
                     "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
                     "capabilities": [] } ],
        "postInstall": [ { "script": "setup.ps1", "description": "Does a thing." } ] }'
    $problems = Test-CatalogueEntry -Entry $entry -Label 'the entry'
    Assert-True ($problems.Count -gt 0) 'the entry should have been refused'
}

Test-It 'a field nobody reads is refused' {
    $entry = Entry '{ "repo": "Thing", "displayName": "Thing", "summary": "A thing.",
        "instaled": true,
        "files": [ { "fileName": "Thing.dll", "folder": "plugins", "expectsPluginAttribute": true } ] }'
    $problems = Test-CatalogueEntry -Entry $entry -Label 'the entry'
    Assert-True ($problems.Count -gt 0) 'the entry should have been refused'
}

Test-It 'a capability the scanner does not report is refused' {
    $entry = Entry '{ "repo": "Thing", "displayName": "Thing", "summary": "A thing.",
        "files": [ { "fileName": "Thing.dll", "folder": "plugins", "expectsPluginAttribute": true,
                     "capabilities": [ "telepathy" ] } ] }'
    $problems = Test-CatalogueEntry -Entry $entry -Label 'the entry'
    Assert-True ($problems.Count -gt 0) 'the entry should have been refused'
}

Test-It 'a good entry is not refused' {
    $entry = Entry '{ "owner": "swyf-modding", "repo": "Thing", "displayName": "Thing", "summary": "A thing.",
        "files": [ { "fileName": "Thing.dll", "folder": "plugins", "expectsPluginAttribute": true } ] }'
    $problems = Test-CatalogueEntry -Entry $entry -Label 'the entry'
    Assert-Equal 0 $problems.Count ("the entry should have been accepted: " + ($problems -join '; '))
}

Test-It 'an entry with one file has one file' {
    # A PowerShell function unrolls an array on the way out, and two versions of it do it
    # differently. An entry with a single file that looks like an entry with no files is
    # what that looks like from here, so it is tested rather than assumed.
    $entry = Entry '{ "repo": "Thing", "displayName": "Thing", "summary": "A thing.",
        "files": [ { "fileName": "Thing.dll", "folder": "plugins", "expectsPluginAttribute": true } ] }'
    $files = Get-Field $entry 'files'
    Assert-Equal 1 @($files).Count 'the entry should have one file'
    Assert-Equal 'Thing.dll' (Get-Field $files[0] 'fileName') 'the file should be the one that was named'
}

Test-It 'an entry with one setup step has one setup step' {
    $entry = Entry '{ "repo": "Thing", "displayName": "Thing", "summary": "A thing.",
        "files": [ { "fileName": "Thing.dll", "folder": "plugins", "expectsPluginAttribute": true } ],
        "postInstall": [ { "script": "setup.ps1", "description": "Does a thing." } ] }'
    $steps = Get-Field $entry 'postInstall'
    Assert-Equal 1 @($steps).Count 'the entry should have one setup step'
    Assert-Equal 'setup.ps1' (Get-Field $steps[0] 'script') 'the step should be the one that was named'
}

Write-Host 'the file'

Test-It 'the catalogue that ships with this repository is valid' {
    $catalogue = Read-Catalogue -Path $Catalogue
    $problems = Test-Catalogue -Catalogue $catalogue
    Assert-Equal 0 $problems.Count ("the catalogue should be valid: " + ($problems -join '; '))
}

Test-It 'the catalogue is written back exactly as it is' {
    $catalogue = Read-Catalogue -Path $Catalogue
    $json = ConvertTo-CatalogueJson -Catalogue $catalogue
    $again = ConvertTo-PlainObject ($json | ConvertFrom-Json)
    Assert-Equal $json (ConvertTo-CatalogueJson -Catalogue $again) 'writing it twice should give the same bytes'
}

Test-It 'the catalogue is written in one shape' {
    $catalogue = Read-Catalogue -Path $Catalogue
    $json = ConvertTo-CatalogueJson -Catalogue $catalogue
    Assert-False ($json.Contains("`r")) 'the file should have no carriage returns'
    Assert-True ($json.EndsWith("`n")) 'the file should end with a newline'
    Assert-True ($json.Contains("`n  `"schemaVersion`": 1,")) 'the file should be indented with two spaces'
}

Test-It 'the catalogue keeps its order' {
    $catalogue = Read-Catalogue -Path $Catalogue
    $problems = Test-CatalogueOrder -Catalogue $catalogue
    Assert-Equal 0 $problems.Count ("the catalogue should be alphabetical: " + ($problems -join '; '))
}

Test-It 'a catalogue that lists the same mod twice is refused' {
    $catalogue = Entry '{ "schemaVersion": 1, "mods": [
        { "repo": "Thing", "displayName": "Thing", "summary": "A thing.",
          "files": [ { "fileName": "Thing.dll", "folder": "plugins", "expectsPluginAttribute": true } ] },
        { "repo": "thing", "displayName": "Thing", "summary": "A thing.",
          "files": [ { "fileName": "Thing.dll", "folder": "plugins", "expectsPluginAttribute": true } ] } ] }'
    $problems = Test-Catalogue -Catalogue $catalogue
    Assert-True ($problems.Count -gt 0) 'the catalogue should have been refused'
}

Test-It 'a catalogue with too many mods is refused' {
    $mods = @()
    for ($i = 0; $i -le 64; $i++) {
        $mods += ('{ "repo": "Thing' + $i + '", "displayName": "Thing", "summary": "A thing.", "files": [ { "fileName": "Thing.dll", "folder": "plugins", "expectsPluginAttribute": true } ] }')
    }
    $catalogue = Entry ('{ "schemaVersion": 1, "mods": [' + ($mods -join ',') + '] }')
    $problems = Test-Catalogue -Catalogue $catalogue
    Assert-True ($problems.Count -gt 0) 'the catalogue should have been refused'
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'Everything passed.' -ForegroundColor Green
    exit 0
}

Write-Host 'FAILURES' -ForegroundColor Red
foreach ($failure in $failures) { Write-Host "  - $failure" -ForegroundColor Red }
exit 1
