<#
    The rules of the catalogue, in one place.

    mods.json is read by three parties that have to agree: the tools that write it, the gate that
    checks it, and Switchboard, which refuses the whole file on anything unexpected. The limits
    are Switchboard's own (src/ModCatalogue.cs).

    Dot-source this. It defines functions and constants and does nothing else.
#>

# The numbers Switchboard enforces, and the numbers the README promises.
$CatalogueLimits = [ordered]@{
    SchemaVersion        = 1
    MaxMods              = 64
    MaxFilesPerMod       = 16
    MaxPostInstallSteps  = 4
    MaxRepoLength        = 100
    MaxDisplayNameLength = 80
    MaxSummaryLength     = 500
    MaxFileNameLength    = 100
    MaxScriptNameLength  = 100
    MaxDescriptionLength = 280
    MaxScriptBytes       = 65536
    DefaultOwner         = 'swyf-modding'
    SharedLibrary        = 'ScamWYF.Modding.Core.dll'
}

$CatalogueFolders = @('plugins', 'core')

# The capabilities the scanner can report. A name it cannot produce is a typo that hides a real
# one, so the catalogue may not carry it.
$CatalogueCapabilities = @(
    'base64'
    'binary-serialization'
    'dynamic-code'
    'environment'
    'filesystem-read'
    'filesystem-write'
    'native-interop'
    'network'
    'process'
    'registry'
)

# The fields each level may carry. Switchboard ignores fields it does not know, so one nobody
# reads looks like it is doing something and is not.
$CatalogueFields = [ordered]@{
    Root     = @('schemaVersion', 'mods')
    Mod      = @('owner', 'repo', 'displayName', 'summary', 'approvedVersion', 'files', 'postInstall')
    File     = @('fileName', 'folder', 'expectsPluginAttribute', 'sha256', 'capabilities', 'bepInPlugin')
    PostStep = @('script', 'description', 'sha256')
}

# ---------------------------------------------------------------- helpers

<#
    A path the .NET file APIs can use.

    PowerShell's location and the process's working directory are different things, and .NET uses
    the second. A relative path handed to ReadAllText would resolve against where the process
    started, not against where the script is.
#>
function Resolve-FullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    $base = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath('.')
    return [IO.Path]::GetFullPath([IO.Path]::Combine($base, $Path))
}

<#
    Unpack a release zip, refusing any entry that would land outside the destination.

    Zip-slip is legal in the format, so every entry is checked before anything is written. The
    returned names are relative to the top of the download, because that is where Switchboard
    looks for a file and a setup script: at the top, by bare name.
#>
function Expand-Release {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $root = [IO.Path]::GetFullPath((Resolve-FullPath $Destination))
    if (-not $root.EndsWith([IO.Path]::DirectorySeparatorChar)) { $root += [IO.Path]::DirectorySeparatorChar }
    if (-not (Test-Path $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }

    $names = @()
    $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-FullPath $ZipPath))
    try {
        foreach ($entry in $archive.Entries) {
            # '\' is a separator on Windows and an ordinary character on Linux, so "..\..\x"
            # escapes on one platform and not the other. Both are read as separators here.
            $name = $entry.FullName -replace '\\', '/'
            if ($name.EndsWith('/')) { continue }

            $target = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $name))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                throw "The release contains an entry that would write outside the unpack folder: $($entry.FullName)"
            }

            $directory = [IO.Path]::GetDirectoryName($target)
            if ($directory -and -not (Test-Path $directory)) {
                New-Item -ItemType Directory -Force -Path $directory | Out-Null
            }

            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            $names += $name
        }
    }
    finally { $archive.Dispose() }

    return ,@($names | Sort-Object)
}

<#
    A field's value, or $null when the field is not there.

    The comma keeps an array whole: a function unrolls an array on the way out, and
    Write-Output -NoEnumerate does it differently in 7 than in 5.1, so an entry with one file
    would look like an entry with no files.
#>
function Get-Field {
    param($Object, [string]$Name)

    $value = $null
    if ($null -ne $Object) {
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { $value = $Object[$Name] }
        }
        else {
            $property = $Object.PSObject.Properties[$Name]
            if ($property) { $value = $property.Value }
        }
    }

    return ,$value
}

# The names of an object's fields, or nothing at all when it has none.
function Get-FieldNames {
    param($Object)
    if ($null -eq $Object) { return }

    if ($Object -is [System.Collections.IDictionary]) {
        $names = @($Object.Keys)
    }
    else {
        $names = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    }

    return ,$names
}

# An object with only dictionaries, arrays and scalars in it.
function ConvertTo-PlainObject {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $out = @{}
        foreach ($key in $Value.Keys) { $out[$key] = ConvertTo-PlainObject $Value[$key] }
        return $out
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $out = @{}
        foreach ($property in $Value.PSObject.Properties) { $out[$property.Name] = ConvertTo-PlainObject $property.Value }
        return $out
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = @()
        foreach ($item in $Value) { $list += ,(ConvertTo-PlainObject $item) }
        return ,$list
    }
    return $Value
}

# A list of problems, or nothing when there are none, so a caller can just count them.
function Get-Problems {
    param($Problems)
    if ($null -eq $Problems -or @($Problems).Count -eq 0) { return }
    return ,@($Problems)
}

# True for a list, and false for a string pretending to be one.
function Test-IsList {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return $false }
    if ($Value -is [System.Collections.IDictionary]) { return $false }
    return ($Value -is [System.Collections.IEnumerable])
}

# ---------------------------------------------------------------- names

# A GitHub account or repository name. Nothing else, so a name can never be a URL or a path.
function Test-AccountName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $trimmed = $Name.Trim()
    if ($trimmed.Length -gt $CatalogueLimits.MaxRepoLength) { return $false }
    return ($trimmed -match '^[A-Za-z0-9._-]+$')
}

# A bare file name: no separators, no parent reference, and a .dll suffix. It becomes a file
# under the game folder, so this is enforced rather than advised against.
function Test-BareFileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $trimmed = $Name.Trim()
    if ($trimmed.Length -gt $CatalogueLimits.MaxFileNameLength) { return $false }
    if ($trimmed.IndexOfAny([char[]]@('/', '\')) -ge 0) { return $false }
    if ($trimmed -eq '.' -or $trimmed -eq '..') { return $false }
    if (-not $trimmed.ToLowerInvariant().EndsWith('.dll')) { return $false }
    return $true
}

# The same rule with .ps1 instead of .dll.
function Test-BareScriptName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $trimmed = $Name.Trim()
    if ($trimmed.Length -gt $CatalogueLimits.MaxScriptNameLength) { return $false }
    if ($trimmed.IndexOfAny([char[]]@('/', '\')) -ge 0) { return $false }
    if ($trimmed -eq '.' -or $trimmed -eq '..') { return $false }
    if (-not $trimmed.ToLowerInvariant().EndsWith('.ps1')) { return $false }
    return $true
}

# Two to four dot-separated numbers, which is what BepInEx can parse. A SemVer build-metadata
# version (1.2.3+g0a1b2c3) is valid SemVer, unloadable by BepInEx, and the plugin would install
# and silently do nothing.
function Test-BepInExVersion {
    param([string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
    return ($Version.Trim() -match '^\d+(\.\d+){1,3}$')
}

# The version a [BepInPlugin] declaration carries, which is its last part.
function Get-BepInPluginVersion {
    param([string]$Declaration)
    if ([string]::IsNullOrWhiteSpace($Declaration)) { return $null }
    $parts = $Declaration -split '\|'
    if ($parts.Count -lt 3) { return $null }
    return $parts[$parts.Count - 1].Trim()
}

function Test-Sha256 {
    param([string]$Hash)
    if ([string]::IsNullOrWhiteSpace($Hash)) { return $false }
    return ($Hash.Trim() -match '^[0-9a-f]{64}$')
}

# ---------------------------------------------------------------- the rules

<#
    Everything wrong with one catalogue entry, as a list of sentences.

    The shape only: no network, no release. Whether the entry matches the release it names is a
    different question, answered by the tools that can download it.
#>
function Test-CatalogueEntry {
    param(
        $Entry,
        [int]$Index = 0,
        [string]$Label = ''
    )

    $problems = New-Object System.Collections.ArrayList
    $where = if ($Label) { $Label } else { "entry $($Index + 1)" }

    if ($null -eq $Entry -or $Entry -isnot [System.Collections.IDictionary]) {
        [void]$problems.Add("$where is not an object")
        return (Get-Problems $problems)
    }

    foreach ($name in (Get-FieldNames $Entry)) {
        if ($CatalogueFields.Mod -notcontains $name) {
            [void]$problems.Add("$where has a field nobody reads: $name")
        }
    }

    $owner = Get-Field $Entry 'owner'
    if ($null -ne $owner -and -not (Test-AccountName $owner)) {
        [void]$problems.Add("$where names no valid owner: $owner")
    }

    $repo = Get-Field $Entry 'repo'
    if ($null -eq $repo -or -not (Test-AccountName $repo)) {
        [void]$problems.Add("$where names no valid repository")
    }

    $displayName = Get-Field $Entry 'displayName'
    if ($null -eq $displayName -or [string]::IsNullOrWhiteSpace($displayName)) {
        [void]$problems.Add("$where has no display name")
    }
    elseif ($displayName.Trim().Length -gt $CatalogueLimits.MaxDisplayNameLength) {
        [void]$problems.Add("$where has a display name of $($displayName.Trim().Length) characters, over the $($CatalogueLimits.MaxDisplayNameLength) allowed")
    }

    $summary = Get-Field $Entry 'summary'
    if ($null -eq $summary -or [string]::IsNullOrWhiteSpace($summary)) {
        [void]$problems.Add("$where has no summary")
    }
    elseif ($summary.Trim().Length -gt $CatalogueLimits.MaxSummaryLength) {
        [void]$problems.Add("$where has a summary of $($summary.Trim().Length) characters, over the $($CatalogueLimits.MaxSummaryLength) allowed")
    }

    $approved = Get-Field $Entry 'approvedVersion'
    if ($null -ne $approved -and [string]::IsNullOrWhiteSpace($approved)) {
        [void]$problems.Add("$where pins an empty release")
    }

    $files = Get-Field $Entry 'files'
    if (-not (Test-IsList $files)) {
        [void]$problems.Add("$where names no files")
        $files = @()
    }
    elseif (@($files).Count -lt 1 -or @($files).Count -gt $CatalogueLimits.MaxFilesPerMod) {
        [void]$problems.Add("$where names $(@($files).Count) files, which is not between 1 and $($CatalogueLimits.MaxFilesPerMod)")
    }

    $seenFiles = @{}
    foreach ($file in @($files)) {
        if ($null -eq $file -or $file -isnot [System.Collections.IDictionary]) {
            [void]$problems.Add("$where names a file that is not an object")
            continue
        }

        foreach ($name in (Get-FieldNames $file)) {
            if ($CatalogueFields.File -notcontains $name) {
                [void]$problems.Add("$where names a file with a field nobody reads: $name")
            }
        }

        $fileName = Get-Field $file 'fileName'
        if (-not (Test-BareFileName $fileName)) {
            [void]$problems.Add("$where names a file this switchboard will not install: $fileName")
        }
        else {
            $key = $fileName.Trim().ToLowerInvariant()
            if ($seenFiles.ContainsKey($key)) {
                [void]$problems.Add("$where names $($fileName.Trim()) twice")
            }
            $seenFiles[$key] = $true
        }

        $folder = Get-Field $file 'folder'
        if ($null -eq $folder -or ($CatalogueFolders -notcontains $folder.ToString().Trim().ToLowerInvariant())) {
            [void]$problems.Add("$where puts $fileName somewhere other than plugins or core")
        }

        $expects = Get-Field $file 'expectsPluginAttribute'
        if ($expects -isnot [bool]) {
            [void]$problems.Add("$where does not say whether $fileName is a plugin")
        }

        $hash = Get-Field $file 'sha256'
        if ($null -ne $hash -and -not (Test-Sha256 $hash)) {
            [void]$problems.Add("$where gives $fileName a hash that is not a sha256")
        }

        $capabilities = Get-Field $file 'capabilities'
        if ($null -ne $capabilities) {
            if (-not (Test-IsList $capabilities)) {
                [void]$problems.Add("$where gives $fileName capabilities that are not a list")
            }
            else {
                foreach ($capability in @($capabilities)) {
                    if ($CatalogueCapabilities -notcontains $capability) {
                        [void]$problems.Add("$where gives $fileName a capability the scanner does not report: $capability")
                    }
                }
            }
        }

        $declarations = Get-Field $file 'bepInPlugin'
        if ($null -ne $declarations) {
            if (-not (Test-IsList $declarations)) {
                [void]$problems.Add("$where gives $fileName a [BepInPlugin] declaration that is not a list")
            }
            else {
                foreach ($declaration in @($declarations)) {
                    if ($declaration -isnot [string] -or [string]::IsNullOrWhiteSpace($declaration)) {
                        [void]$problems.Add("$where gives $fileName a [BepInPlugin] declaration that says nothing")
                    }
                }
            }
        }
    }

    $steps = Get-Field $Entry 'postInstall'
    if ($null -ne $steps) {
        if (-not (Test-IsList $steps)) {
            [void]$problems.Add("$where names setup steps that are not a list")
        }
        elseif (@($steps).Count -lt 1 -or @($steps).Count -gt $CatalogueLimits.MaxPostInstallSteps) {
            [void]$problems.Add("$where names $(@($steps).Count) setup steps, which is not between 1 and $($CatalogueLimits.MaxPostInstallSteps)")
        }

        $seenScripts = @{}
        foreach ($step in @($steps)) {
            if ($null -eq $step -or $step -isnot [System.Collections.IDictionary]) {
                [void]$problems.Add("$where names a setup step that is not an object")
                continue
            }

            foreach ($name in (Get-FieldNames $step)) {
                if ($CatalogueFields.PostStep -notcontains $name) {
                    [void]$problems.Add("$where names a setup step with a field nobody reads: $name")
                }
            }

            $script = Get-Field $step 'script'
            if (-not (Test-BareScriptName $script)) {
                [void]$problems.Add("$where names a setup script this switchboard will not run: $script")
            }
            else {
                $key = $script.Trim().ToLowerInvariant()
                if ($seenScripts.ContainsKey($key)) {
                    [void]$problems.Add("$where names the setup script $($script.Trim()) twice")
                }
                $seenScripts[$key] = $true
            }

            $description = Get-Field $step 'description'
            if ($null -eq $description -or [string]::IsNullOrWhiteSpace($description)) {
                [void]$problems.Add("$where has a setup step that says nothing about what it does")
            }
            elseif ($description.Trim().Length -gt $CatalogueLimits.MaxDescriptionLength) {
                [void]$problems.Add("$where has a setup step of $($description.Trim().Length) characters, over the $($CatalogueLimits.MaxDescriptionLength) allowed")
            }

            $hash = Get-Field $step 'sha256'
            if ($null -ne $hash -and -not (Test-Sha256 $hash)) {
                [void]$problems.Add("$where gives the setup script $($step.script) a hash that is not a sha256")
            }
        }
    }

    # A pinned entry has to pin everything it installs. An approvedVersion with a file or a script
    # left unpinned is an entry installed on a promise, not a reviewed release with a gap in it.
    if ($null -ne $approved -and -not [string]::IsNullOrWhiteSpace($approved)) {
        foreach ($file in @($files)) {
            if ($null -eq $file -or $file -isnot [System.Collections.IDictionary]) { continue }
            $fileName = Get-Field $file 'fileName'
            if ($null -eq (Get-Field $file 'sha256')) {
                [void]$problems.Add("$where pins $approved but gives $fileName no hash")
            }
            if ($null -eq (Get-Field $file 'capabilities')) {
                [void]$problems.Add("$where pins $approved but records no capabilities for $fileName")
            }
        }
        foreach ($step in @($steps)) {
            if ($null -eq $step -or $step -isnot [System.Collections.IDictionary]) { continue }
            if ($null -eq (Get-Field $step 'sha256')) {
                [void]$problems.Add("$where pins $approved but gives the setup script $(Get-Field $step 'script') no hash")
            }
        }
    }

    return (Get-Problems $problems)
}

# The shape of the whole file. No release is looked at, so this costs nothing and can run on
# every change.
function Test-Catalogue {
    param($Catalogue)

    $problems = New-Object System.Collections.ArrayList

    if ($null -eq $Catalogue -or $Catalogue -isnot [System.Collections.IDictionary]) {
        [void]$problems.Add('the catalogue is not an object')
        return (Get-Problems $problems)
    }

    foreach ($name in (Get-FieldNames $Catalogue)) {
        if ($CatalogueFields.Root -notcontains $name) {
            [void]$problems.Add("the catalogue has a field nobody reads: $name")
        }
    }

    $schema = Get-Field $Catalogue 'schemaVersion'
    if ($null -eq $schema) {
        [void]$problems.Add('the catalogue names no schema version')
    }
    elseif ([int]$schema -ne $CatalogueLimits.SchemaVersion) {
        [void]$problems.Add("the catalogue uses schema version $schema, which this switchboard does not understand")
    }

    $mods = Get-Field $Catalogue 'mods'
    if (-not (Test-IsList $mods)) {
        [void]$problems.Add('the catalogue names no mods')
        return (Get-Problems $problems)
    }

    $count = @($mods).Count
    if ($count -lt 1) {
        [void]$problems.Add('the catalogue names no mods')
    }
    elseif ($count -gt $CatalogueLimits.MaxMods) {
        [void]$problems.Add("the catalogue names $count mods, which is more than the $($CatalogueLimits.MaxMods) this switchboard will consider")
    }

    $seen = @{}
    $index = 0
    foreach ($mod in @($mods)) {
        $repo = Get-Field $mod 'repo'
        $label = if ($repo) { "the entry for $repo" } else { "entry $($index + 1)" }
        foreach ($problem in (Test-CatalogueEntry -Entry $mod -Index $index -Label $label)) {
            [void]$problems.Add($problem)
        }

        if ($repo) {
            $owner = Get-Field $mod 'owner'
            if ($null -eq $owner -or [string]::IsNullOrWhiteSpace($owner)) { $owner = $CatalogueLimits.DefaultOwner }
            $key = "$($owner.ToLowerInvariant())/$($repo.ToLowerInvariant())"
            if ($seen.ContainsKey($key)) {
                [void]$problems.Add("the catalogue lists $key twice")
            }
            $seen[$key] = $true
        }

        $index++
    }

    return (Get-Problems $problems)
}

# Alphabetical by repository, case-insensitively, so AI-Backend and ai-backend sort together.
function Sort-CatalogueMods {
    param($Mods)
    $list = @($Mods)
    if ($list.Count -le 1) { return ,$list }

    $sorted = $list | Sort-Object -Property @{ Expression = { $repo = Get-Field $_ 'repo'; if ($repo) { $repo.ToLowerInvariant() } else { '' } } }, @{ Expression = { $owner = Get-Field $_ 'owner'; if ($owner) { $owner.ToLowerInvariant() } else { '' } } }
    return ,@($sorted)
}

# The order the file keeps, so a warning can point at the entry that is in the wrong place.
function Test-CatalogueOrder {
    param($Catalogue)
    $mods = Get-Field $Catalogue 'mods'
    if ($null -eq $mods -or @($mods).Count -lt 2) { return }

    $problems = New-Object System.Collections.ArrayList
    $sorted = Sort-CatalogueMods -Mods $mods
    for ($i = 0; $i -lt $mods.Count; $i++) {
        $a = Get-Field $mods[$i] 'repo'
        $b = Get-Field $sorted[$i] 'repo'
        if ($a -ne $b) {
            [void]$problems.Add("the catalogue is not alphabetical: $($mods[$i].repo) is where $($sorted[$i].repo) should be")
            break
        }
    }
    return (Get-Problems $problems)
}

# ---------------------------------------------------------------- writing

function ConvertTo-JsonString {
    param([string]$Text)
    if ($null -eq $Text) { return 'null' }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($char in $Text.ToCharArray()) {
        $code = [int][char]$char
        if ($char -eq '"') { [void]$builder.Append('\"') }
        elseif ($char -eq '\') { [void]$builder.Append('\\') }
        elseif ($code -lt 32 -or $code -eq 127) {
            switch ($char) {
                "`b" { [void]$builder.Append('\b') }
                "`f" { [void]$builder.Append('\f') }
                "`n" { [void]$builder.Append('\n') }
                "`r" { [void]$builder.Append('\r') }
                "`t" { [void]$builder.Append('\t') }
                default { [void]$builder.AppendFormat('\u{0:x4}', $code) }
            }
        }
        else { [void]$builder.Append($char) }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

# A value as JSON, indented two spaces per level.
function ConvertTo-JsonValue {
    param($Value, [int]$Depth = 0)

    $indent = '  ' * $Depth
    $inner = '  ' * ($Depth + 1)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return ([string]$Value)
    }
    if ($Value -is [string]) { return (ConvertTo-JsonString $Value) }

    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @($Value.Keys)
        if ($keys.Count -eq 0) { return '{}' }
        $lines = @()
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $comma = if ($i -lt ($keys.Count - 1)) { ',' } else { '' }
            $child = ConvertTo-JsonValue -Value $Value[$keys[$i]] -Depth ($Depth + 1)
            $lines += $inner + (ConvertTo-JsonString ([string]$keys[$i])) + ': ' + $child + $comma
        }
        return "{`n" + ($lines -join "`n") + "`n$indent}"
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '[]' }
        $lines = @()
        for ($i = 0; $i -lt $items.Count; $i++) {
            $comma = if ($i -lt ($items.Count - 1)) { ',' } else { '' }
            $lines += $inner + (ConvertTo-JsonValue -Value $items[$i] -Depth ($Depth + 1)) + $comma
        }
        return "[`n" + ($lines -join "`n") + "`n$indent]"
    }

    return (ConvertTo-JsonString ([string]$Value))
}

<#
    The catalogue as an ordered object: the fields in the order the README lists them.

    A field the catalogue does not define is kept at the end of its object, so writing the file
    never quietly drops something. The rules refuse such a field, so this is only for a file that
    was already broken.
#>
function ConvertTo-CatalogueModel {
    param($Catalogue)

    $model = [ordered]@{}
    $model['schemaVersion'] = $CatalogueLimits.SchemaVersion

    $entries = @()
    $mods = Get-Field $Catalogue 'mods'
    foreach ($mod in $mods) {
        $entry = [ordered]@{}

        $owner = Get-Field $mod 'owner'
        if ($null -ne $owner) { $entry['owner'] = $owner }
        $entry['repo'] = Get-Field $mod 'repo'
        $entry['displayName'] = Get-Field $mod 'displayName'
        $entry['summary'] = Get-Field $mod 'summary'

        $approved = Get-Field $mod 'approvedVersion'
        if ($null -ne $approved) { $entry['approvedVersion'] = $approved }

        $files = @()
        $modFiles = Get-Field $mod 'files'
        foreach ($file in $modFiles) {
            $item = [ordered]@{}
            $item['fileName'] = Get-Field $file 'fileName'
            $item['folder'] = Get-Field $file 'folder'
            $item['expectsPluginAttribute'] = [bool](Get-Field $file 'expectsPluginAttribute')

            $hash = Get-Field $file 'sha256'
            if ($null -ne $hash) { $item['sha256'] = $hash }

            $capabilities = Get-Field $file 'capabilities'
            if ($null -ne $capabilities) { $item['capabilities'] = @(@($capabilities) | Sort-Object) }

            $declarations = Get-Field $file 'bepInPlugin'
            if ($null -ne $declarations -and @($declarations).Count -gt 0) { $item['bepInPlugin'] = @($declarations) }

            foreach ($name in (Get-FieldNames $file)) {
                if ($CatalogueFields.File -notcontains $name) { $item[$name] = Get-Field $file $name }
            }

            $files += ,$item
        }
        $entry['files'] = $files

        $steps = Get-Field $mod 'postInstall'
        if ($null -ne $steps -and @($steps).Count -gt 0) {
            $list = @()
            foreach ($step in $steps) {
                $item = [ordered]@{}
                $item['script'] = Get-Field $step 'script'
                $item['description'] = Get-Field $step 'description'
                $hash = Get-Field $step 'sha256'
                if ($null -ne $hash) { $item['sha256'] = $hash }
                foreach ($name in (Get-FieldNames $step)) {
                    if ($CatalogueFields.PostStep -notcontains $name) { $item[$name] = Get-Field $step $name }
                }
                $list += ,$item
            }
            $entry['postInstall'] = $list
        }

        foreach ($name in (Get-FieldNames $mod)) {
            if ($CatalogueFields.Mod -notcontains $name) { $entry[$name] = Get-Field $mod $name }
        }

        $entries += ,$entry
    }
    $model['mods'] = $entries

    return $model
}

# The catalogue as it is written to disk: two spaces, LF endings, no BOM, always the same shape,
# so a change to it is a change to the catalogue rather than to the formatting.
function ConvertTo-CatalogueJson {
    param($Catalogue)

    $model = ConvertTo-CatalogueModel -Catalogue $Catalogue
    return ((ConvertTo-JsonValue -Value $model -Depth 0) + "`n")
}

function Read-Catalogue {
    param([Parameter(Mandatory = $true)][string]$Path)

    $text = [IO.File]::ReadAllText((Resolve-FullPath $Path))
    $parsed = $text | ConvertFrom-Json
    return (ConvertTo-PlainObject $parsed)
}

function Save-Catalogue {
    param(
        [Parameter(Mandatory = $true)]$Catalogue,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $json = ConvertTo-CatalogueJson -Catalogue $Catalogue
    $full = Resolve-FullPath $Path
    $directory = [IO.Path]::GetDirectoryName($full)
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    # No BOM: a byte order mark in front of a JSON file is a surprise for whatever reads it.
    [IO.File]::WriteAllText($full, $json, (New-Object System.Text.UTF8Encoding($false)))
}
