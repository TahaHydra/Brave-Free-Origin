<#
.SYNOPSIS
    Builds the portable release zip (Brave-Free-Origin.zip) and its SHA256SUMS.txt.

.DESCRIPTION
    This is the one place that decides what ships. CI and the release workflow
    both call it, so what you test is what users download.

    Shipped:    the launcher, the app, the locales, the docs a user may want offline,
                the images those docs show, LICENSE.
    Not shipped: tools\ (maintainer scripts), install\ (the online one-liner, served
                separately), .github\, anything git-ignored.

    Entry names use forward slashes, so the zip opens correctly with Windows
    Explorer, PowerShell 5.1 and 7, 7-Zip and non-Windows tools alike (the
    Compress-Archive cmdlet in Windows PowerShell 5.1 writes backslashes).

.PARAMETER OutFile
    Zip to create. Default: Brave-Free-Origin.zip in the repo root.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\Build-Package.ps1
#>
[CmdletBinding()]
param(
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutFile) { $OutFile = Join-Path $repoRoot 'Brave-Free-Origin.zip' }
$OutFile = [System.IO.Path]::GetFullPath($OutFile)

$files = @(
    'Brave-Free-Origin.bat'
    'Brave-Free-Origin.ps1'
    'README.md'
    'README.zh-CN.md'
    'TRANSLATING.md'
    'CHANGELOG.md'
    'LICENSE'
)
$folders = @('locales', 'images', 'docs')

$entries = New-Object System.Collections.ArrayList
foreach ($f in $files) {
    $p = Join-Path $repoRoot $f
    if (-not (Test-Path -LiteralPath $p)) { throw "Missing file to package: $f" }
    [void]$entries.Add([pscustomobject]@{ Path = $p; Name = $f })
}
foreach ($d in $folders) {
    $root = Join-Path $repoRoot $d
    if (-not (Test-Path -LiteralPath $root)) { throw "Missing folder to package: $d" }
    $prefix = $root.TrimEnd('\') + '\'
    foreach ($file in (Get-ChildItem -LiteralPath $root -Recurse -File)) {
        [void]$entries.Add([pscustomobject]@{ Path = $file.FullName; Name = ($d + '/' + $file.FullName.Substring($prefix.Length).Replace('\', '/')) })
    }
}

# ---- what must be inside ----------------------------------------------------------------------------
$required = @(
    'Brave-Free-Origin.bat', 'Brave-Free-Origin.ps1', 'README.md', 'CHANGELOG.md', 'LICENSE',
    'locales/en-US.json', 'locales/fr-FR.json', 'locales/es-ES.json', 'locales/hi-IN.json',
    'locales/ar.json', 'locales/zh-CN.json', 'locales/zh-TW.json', 'docs/POLICIES.md', 'images/screenshot.png'
)
foreach ($need in $required) {
    if (-not ($entries | Where-Object { $_.Name -eq $need })) { throw "$need is missing from the package." }
}
foreach ($e in $entries) {
    if ($e.Name -match '^(tools|install|\.github|\.git)/') { throw "$($e.Name) must not be shipped." }
}

# ---- write --------------------------------------------------------------------------------------------
if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }
$zip = [System.IO.Compression.ZipFile]::Open($OutFile, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($e in ($entries | Sort-Object Name)) {
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $e.Path, $e.Name, [System.IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $zip.Dispose()
}

# ---- verify what was written -----------------------------------------------------------------------
$check = [System.IO.Compression.ZipFile]::OpenRead($OutFile)
try {
    $names = @($check.Entries | ForEach-Object { $_.FullName })
} finally {
    $check.Dispose()
}
foreach ($need in $required) {
    if ($names -notcontains $need) { throw "$need did not make it into the zip." }
}
if ($names | Where-Object { $_ -match '\\' }) { throw 'The zip contains backslashes in entry names.' }

$hash = (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash.ToLowerInvariant()
$sums = Join-Path (Split-Path -Parent $OutFile) 'SHA256SUMS.txt'
[System.IO.File]::WriteAllText($sums, ("{0} *{1}`n" -f $hash, (Split-Path -Leaf $OutFile)), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ("Built {0}: {1} files, {2:N0} KB" -f $OutFile, $names.Count, ((Get-Item -LiteralPath $OutFile).Length / 1KB))
Write-Host "SHA-256 $hash"
