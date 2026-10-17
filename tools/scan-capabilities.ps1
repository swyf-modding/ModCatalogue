<#
.SYNOPSIS
    Reports what a mod assembly is able to do, by reading its IL.

.DESCRIPTION
    Scanning for suspicious strings does not work. A mod can assemble a command at runtime
    from a StringBuilder and base64 it, and the literal never appears in the file - that is
    exactly what SWYF-ModManager does legitimately, and a scan of its strings returns only
    "powershell.exe" and "*.dll".

    Method references, on the other hand, live in the assembly's metadata. Obfuscating a
    string cannot hide a call to Process.Start, because the callee is a metadata token, not
    text. So this reports capabilities - which host-reaching APIs an assembly references -
    rather than guessing at intent.

    This is NOT a malware scanner and it does not decide whether a mod is safe. Plenty of
    mods legitimately need these capabilities. Its job is to make a capability CHANGE
    between two releases impossible to miss, so a human reads the diff when it matters.

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

# ---------------------------------------------------------------- Mono.Cecil

function Get-Cecil {
    param([string]$Explicit)
    if ($Explicit) { return (Resolve-Path $Explicit).Path }

    $cache = Join-Path ([IO.Path]::GetTempPath()) 'swyf-cecil-0.11.5'
    $dll = Join-Path $cache 'Mono.Cecil.dll'
    if (Test-Path $dll) { return $dll }

    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    $nupkg = Join-Path $cache 'cecil.zip'
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
    if (-not (Test-Path $dll)) { throw 'Could not obtain Mono.Cecil from nuget.org.' }
    return $dll
}

Add-Type -Path (Get-Cecil $Cecil)

# ---------------------------------------------------------------- taxonomy
#
# Each rule is: capability name -> list of substrings matched against
# "<DeclaringType.FullName>::<MethodName>". Deliberately small and high signal:
# a rule nobody can explain is a rule reviewers learn to ignore.

$Rules = [ordered]@{
    'process' = @(
        'System.Diagnostics.Process::Start', 'System.Diagnostics.ProcessStartInfo::'
    )
    'network' = @(
        'System.Net.WebClient::', 'System.Net.HttpWebRequest::', 'System.Net.Http.',
        'System.Net.Sockets.', 'System.Net.Dns::', 'UnityEngine.Networking.UnityWebRequest::',
        'System.Net.WebRequest::'
    )
    'filesystem-write' = @(
        'System.IO.File::Write', 'System.IO.File::Create', 'System.IO.File::Move',
        'System.IO.File::Delete', 'System.IO.File::Copy', 'System.IO.File::Append',
        'System.IO.Directory::CreateDirectory', 'System.IO.Directory::Delete',
        'System.IO.Directory::Move', 'System.IO.FileStream::.ctor'
    )
    'filesystem-read' = @(
        'System.IO.File::Read', 'System.IO.File::Open', 'System.IO.File::Exists',
        'System.IO.Directory::GetFiles', 'System.IO.Directory::Exists',
        'System.IO.Directory::EnumerateFiles'
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

# ---------------------------------------------------------------- scanning

function Get-Sha256($file) {
    (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLowerInvariant()
}

function Scan-Assembly {
    param([string]$File)

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

        if ($pinvokes.Count -gt 0) { $caps['native-interop'] = $caps['native-interop'] }

        $names = @($caps.Keys)
        if ($pinvokes.Count -gt 0 -and $names -notcontains 'native-interop') { $names += 'native-interop' }

        return [pscustomobject]@{
            file         = [IO.Path]::GetFileName($File)
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

if ((Get-Item $resolved).PSIsContainer) {
    Get-ChildItem $resolved -Filter *.dll -Recurse | ForEach-Object { [void]$targets.Add($_.FullName) }
} elseif ($resolved -like '*.zip') {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('swyf-scan-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($resolved, $temp)
    Get-ChildItem $temp -Filter *.dll -Recurse | ForEach-Object { [void]$targets.Add($_.FullName) }
} else {
    [void]$targets.Add($resolved)
}

$results = New-Object System.Collections.ArrayList
foreach ($t in $targets) {
    $r = Scan-Assembly $t
    if ($r) { [void]$results.Add($r) }
}

if ($temp -and (Test-Path $temp)) { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------- output

if ($Json) {
    $results | ConvertTo-Json -Depth 8
    return
}

foreach ($r in $results) {
    Write-Host ""
    Write-Host "$($r.file)" -ForegroundColor Cyan
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
