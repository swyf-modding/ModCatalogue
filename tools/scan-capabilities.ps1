<#
.SYNOPSIS
    Reports what a mod assembly is able to do, by reading its IL.

.DESCRIPTION
    Scanning for strings does not work: a command can be built at runtime and base64'd, and the
    literal never appears in the file. Method references cannot be hidden that way - the callee
    is a metadata token, not text - so this reports which host-reaching APIs an assembly
    references, rather than guessing at intent.

    It also reports where each assembly sits in the download, because Switchboard installs only
    what is at the top of the unpacked zip.

    This is not a malware scanner and does not decide whether a mod is safe. Its job is to make
    a capability change between two releases impossible to miss.

.EXAMPLE
    ./scan-capabilities.ps1 -Path ./SwyfModManager.dll
    ./scan-capabilities.ps1 -Path ./release.zip -Json
#>
[CmdletBinding()]
param(
    # A .dll, a .zip containing dlls, or a directory.
    [Parameter(Mandatory = $true)][string]$Path,
    # Path to Mono.Cecil.dll. Downloaded from nuget.org when omitted.
    [string]$Cecil,
    # Emit JSON only, for CI.
    [switch]$Json,
    # Include the calling method for every matched API.
    [switch]$Detail
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'catalogue-rules.ps1')

# ---------------------------------------------------------------- Mono.Cecil

# Mono.Cecil 0.11.5, lib/netstandard2.0/Mono.Cecil.dll. Pinned because this script loads it as
# code: Add-Type runs it inside the maintainer's session. A cache under a world-writable temp
# directory - /tmp on Linux and macOS - is something another local user can populate first, so the
# cached copy is verified on every load, not only when it is first downloaded.
$CecilSha256 = '9c2908709da6761e9b5b9d4d46102d65851145bac987787d6c5a05ffe5689487'

function Get-FileSha256($path) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
}

function Get-Cecil {
    param([string]$Explicit)
    if ($Explicit) { return (Resolve-Path $Explicit).Path }

    # Per-user rather than the shared temp root, so the ordinary case is not a world-writable path.
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA }
            elseif ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME }
            elseif ($env:HOME) { Join-Path $env:HOME '.cache' }
            else { [IO.Path]::GetTempPath() }

    $cache = Join-Path $base 'swyf-modding/cecil-0.11.5'
    $dll = Join-Path $cache 'Mono.Cecil.dll'

    if (Test-Path $dll) {
        if ((Get-FileSha256 $dll) -eq $CecilSha256) { return $dll }
        Write-Warning "Cached Mono.Cecil did not match its pinned hash; discarding and downloading again."
        Remove-Item $dll -Force
    }

    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    $nupkg = Join-Path $cache ('cecil-' + [Guid]::NewGuid().ToString('N') + '.zip')
    try {
        Invoke-WebRequest -Uri 'https://www.nuget.org/api/v2/package/Mono.Cecil/0.11.5' -OutFile $nupkg -UseBasicParsing
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($nupkg)
        try {
            foreach ($e in $zip.Entries) {
                if ($e.FullName -eq 'lib/netstandard2.0/Mono.Cecil.dll') {
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dll, $true)
                }
            }
        } finally { $zip.Dispose() }
    } finally {
        if (Test-Path $nupkg) { Remove-Item $nupkg -Force -ErrorAction SilentlyContinue }
    }

    if (-not (Test-Path $dll)) { throw 'Could not obtain Mono.Cecil from nuget.org.' }

    $actual = Get-FileSha256 $dll
    if ($actual -ne $CecilSha256) {
        Remove-Item $dll -Force -ErrorAction SilentlyContinue
        throw "Mono.Cecil downloaded from nuget.org has sha256 $actual, not the pinned $CecilSha256. Refusing to load it."
    }

    return $dll
}

Add-Type -Path (Get-Cecil $Cecil)

# ---------------------------------------------------------------- taxonomy
#
# Each rule is: capability -> substrings matched against "<DeclaringType.FullName>::<MethodName>".

$Rules = [ordered]@{
    'process' = @(
        'System.Diagnostics.Process::Start', 'System.Diagnostics.ProcessStartInfo::'
    )
    'network' = @(
        'System.Net.WebClient::', 'System.Net.HttpWebRequest::', 'System.Net.Http.',
        'System.Net.Sockets.', 'System.Net.Dns::', 'UnityEngine.Networking.UnityWebRequest',
        'System.Net.WebRequest::', 'System.Net.FtpWebRequest::', 'System.Net.WebSockets.',
        'UnityEngine.WWW::'
    )
    # File::Open is also a read, and counting an ambiguous call as both is the conservative
    # answer: over-reporting costs a glance, under-reporting hides a change.
    'filesystem-write' = @(
        'System.IO.File::Write', 'System.IO.File::Create', 'System.IO.File::Move',
        'System.IO.File::Delete', 'System.IO.File::Copy', 'System.IO.File::Append',
        'System.IO.File::Open', 'System.IO.File::Replace', 'System.IO.File::SetAttributes',
        'System.IO.Directory::CreateDirectory', 'System.IO.Directory::Delete',
        'System.IO.Directory::Move', 'System.IO.FileStream::.ctor',
        'System.IO.FileInfo::Create', 'System.IO.FileInfo::Delete', 'System.IO.FileInfo::MoveTo',
        'System.IO.FileInfo::CopyTo', 'System.IO.FileInfo::OpenWrite', 'System.IO.FileInfo::Replace',
        'System.IO.FileInfo::AppendText', 'System.IO.FileInfo::CreateText',
        'System.IO.DirectoryInfo::Create', 'System.IO.DirectoryInfo::Delete',
        'System.IO.DirectoryInfo::MoveTo',
        'System.IO.StreamWriter::.ctor', 'System.IO.BinaryWriter::.ctor'
    )
    'filesystem-read' = @(
        'System.IO.File::Read', 'System.IO.File::Open', 'System.IO.File::Exists',
        'System.IO.Directory::GetFiles', 'System.IO.Directory::Exists',
        'System.IO.Directory::EnumerateFiles', 'System.IO.Directory::GetDirectories',
        'System.IO.FileInfo::OpenRead', 'System.IO.FileInfo::OpenText',
        'System.IO.FileInfo::get_Exists', 'System.IO.DirectoryInfo::GetFiles',
        'System.IO.DirectoryInfo::EnumerateFiles', 'System.IO.DirectoryInfo::get_Exists',
        'System.IO.StreamReader::.ctor', 'System.IO.BinaryReader::.ctor'
    )
    'native-interop' = @(
        'System.Runtime.InteropServices.Marshal::'
    )
    'dynamic-code' = @(
        'System.Reflection.Assembly::Load', 'System.Reflection.Assembly::UnsafeLoad',
        'System.AppDomain::Load', 'System.AppDomain::CreateInstance',
        'System.Reflection.Emit.', 'System.Activator::CreateInstance',
        'System.Reflection.MethodBase::Invoke'
    )
    'base64' = @(
        'System.Convert::ToBase64String', 'System.Convert::FromBase64String'
    )
    'registry' = @(
        'Microsoft.Win32.Registry'
    )
    'environment' = @(
        'System.Environment::GetEnvironmentVariable', 'System.Environment::SetEnvironmentVariable',
        'System.Environment::GetFolderPath', 'System.Environment::ExpandEnvironmentVariables'
    )
    'binary-serialization' = @(
        'System.Runtime.Serialization.Formatters.Binary.BinaryFormatter::'
    )
}

# The capability names are the catalogue's business: it may not name one that does not exist.
# A name here that the catalogue does not know would be a capability the gate could not check.
foreach ($capability in $Rules.Keys) {
    if ($CatalogueCapabilities -notcontains $capability) {
        throw "The scanner reports a capability the catalogue does not know: $capability"
    }
}

# ---------------------------------------------------------------- scanning

function Get-Sha256($file) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant()
}

function Scan-Assembly {
    param([string]$File, [string]$RelativePath)

    try { $asm = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($File) }
    catch { return $null }   # not a managed assembly

    try {
        $caps = [ordered]@{}
        $pinvokes = New-Object System.Collections.ArrayList
        $plugins = New-Object System.Collections.ArrayList

        foreach ($c in $asm.CustomAttributes) {
            if ($c.AttributeType.FullName -eq 'BepInEx.BepInPlugin' -and $c.ConstructorArguments.Count -ge 3) {
                [void]$plugins.Add(($c.ConstructorArguments | ForEach-Object { [string]$_.Value }) -join ' | ')
            }
        }

        foreach ($t in $asm.MainModule.GetTypes()) {
            foreach ($c in $t.CustomAttributes) {
                if ($c.AttributeType.FullName -eq 'BepInEx.BepInPlugin' -and $c.ConstructorArguments.Count -ge 3) {
                    [void]$plugins.Add(($c.ConstructorArguments | ForEach-Object { [string]$_.Value }) -join ' | ')
                }
            }

            foreach ($m in $t.Methods) {
                if ($m.IsPInvokeImpl -and $m.PInvokeInfo) {
                    [void]$pinvokes.Add("$($m.PInvokeInfo.Module.Name)!$($m.PInvokeInfo.EntryPoint)")
                }
                if (-not $m.HasBody) { continue }
                foreach ($ins in $m.Body.Instructions) {
                    $op = $ins.Operand
                    if (-not ($op -is [Mono.Cecil.MethodReference])) { continue }
                    $sig = "$($op.DeclaringType.FullName)::$($op.Name)"
                    foreach ($cap in $Rules.Keys) {
                        foreach ($needle in $Rules[$cap]) {
                            if ($sig.StartsWith($needle, [StringComparison]::Ordinal) -or $sig.Contains($needle)) {
                                if (-not $caps[$cap]) { $caps[$cap] = [ordered]@{} }
                                if (-not $caps[$cap][$sig]) { $caps[$cap][$sig] = New-Object 'System.Collections.Generic.HashSet[string]' }
                                [void]$caps[$cap][$sig].Add("$($t.FullName)::$($m.Name)")
                                break
                            }
                        }
                    }
                }
            }
        }

        # A P/Invoke is native interop whether or not the code also reaches Marshal directly, so
        # the capability is there either way.
        if ($pinvokes.Count -gt 0 -and -not $caps.Contains('native-interop')) {
            $caps['native-interop'] = [ordered]@{}
        }

        $names = @($caps.Keys)

        # Where the file sits in the download. Switchboard installs what is at the top of the
        # unpacked zip, so an assembly in a folder cannot be installed and cannot be named.
        $atRoot = ($RelativePath -notmatch '[\\/]')

        return [pscustomobject]@{
            file         = [IO.Path]::GetFileName($File)
            path         = $RelativePath
            atRoot       = $atRoot
            assembly     = $asm.Name.Name
            version      = $asm.Name.Version.ToString()
            sha256       = Get-Sha256 $File
            bepInPlugin  = @($plugins | Sort-Object -Unique)
            pinvoke      = @($pinvokes | Sort-Object -Unique)
            capabilities = @($names | Sort-Object)
            detail       = $caps
        }
    }
    finally { $asm.Dispose() }
}

# ---------------------------------------------------------------- input

$targets = New-Object System.Collections.ArrayList
$temp = $null
$resolved = (Resolve-Path $Path).Path
$root = $null

if ((Get-Item $resolved).PSIsContainer) {
    $root = $resolved
    Get-ChildItem $resolved -Filter *.dll -Recurse | ForEach-Object { [void]$targets.Add($_.FullName) }
} elseif ($resolved -like '*.zip') {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('swyf-scan-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($resolved, $temp)
    $root = $temp
    Get-ChildItem $temp -Filter *.dll -Recurse | ForEach-Object { [void]$targets.Add($_.FullName) }
} else {
    [void]$targets.Add($resolved)
}

$results = New-Object System.Collections.ArrayList
foreach ($t in $targets) {
    # The path is relative to the download's root, so a file in a folder is visible as one.
    $relative = [IO.Path]::GetFileName($t)
    if ($root) {
        $relative = $t.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $relative = $relative -replace '\\', '/'
    }
    $r = Scan-Assembly -File $t -RelativePath $relative
    if ($r) { [void]$results.Add($r) }
}

if ($temp -and (Test-Path $temp)) { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }

# The same order every time, so two scans of the same release produce the same file.
$results = @($results | Sort-Object -Property path)

# ---------------------------------------------------------------- output

if ($Json) {
    $results | ConvertTo-Json -Depth 8
    return
}

foreach ($r in $results) {
    Write-Host ""
    Write-Host "$($r.file)" -ForegroundColor Cyan
    if (-not $r.atRoot) { Write-Host "  in a folder: $($r.path) - switchboard installs only what is at the top of the download" -ForegroundColor Yellow }
    Write-Host "  assembly  : $($r.assembly) $($r.version)"
    Write-Host "  sha256    : $($r.sha256)"
    foreach ($p in $r.bepInPlugin) { Write-Host "  plugin    : $p" }
    foreach ($p in $r.pinvoke) { Write-Host "  p/invoke  : $p" -ForegroundColor Yellow }
    if ($r.capabilities.Count -eq 0) {
        Write-Host "  capabilities: none - touches nothing outside the game process" -ForegroundColor Green
    } else {
        Write-Host "  capabilities: $($r.capabilities -join ', ')" -ForegroundColor Yellow
        if ($Detail) {
            foreach ($cap in $r.detail.Keys) {
                Write-Host "    [$cap]"
                foreach ($sig in $r.detail[$cap].Keys) {
                    Write-Host "      $sig"
                    foreach ($from in $r.detail[$cap][$sig]) { Write-Host "          from $from" }
                }
            }
        }
    }
}
Write-Host ""
