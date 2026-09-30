<#
.SYNOPSIS
    Lists the policy names an installed Brave really knows, so the catalog can be checked against the browser instead of
    against itself.

.DESCRIPTION
    Brave (like Chromium) compiles every policy name it knows into chrome.dll as one alphabetically sorted run of
    NUL-terminated strings. This reads that run (read-only; nothing is executed, written or changed in Brave).

    Two uses:

      Snapshot (default)   writes tools\data\brave-policy-names.txt. The sandboxed tests (tools\Test-App.ps1) check
                           every policy of the catalog against that file, so a name Brave dropped or never had fails
                           CI instead of silently doing nothing on users' PCs.
      -Check               compares the catalog in Brave-Free-Origin.ps1 with the installed Brave right now and lists
                           what it no longer knows. Run it after Brave updates, before deciding to refresh the snapshot.

    After a Brave update: run with -Check; fix the catalog; run the snapshot; bump CatalogBrave / CatalogDate in the
    app; run the tests.

.PARAMETER Dll
    chrome.dll to read. Default: the newest one of an installed Brave.

.PARAMETER OutFile
    Snapshot file to write. Default: tools\data\brave-policy-names.txt

.PARAMETER Check
    Compare instead of writing.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\Export-BravePolicyNames.ps1 -Check
#>
[CmdletBinding()]
param(
    [string]$Dll,
    [string]$OutFile,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutFile) { $OutFile = Join-Path $PSScriptRoot 'data\brave-policy-names.txt' }

function Find-BraveDll {
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\Application'),
        (Join-Path $env:ProgramFiles 'BraveSoftware\Brave-Browser\Application'),
        (Join-Path ${env:ProgramFiles(x86)} 'BraveSoftware\Brave-Browser\Application')
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $best = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
            Sort-Object { [version]$_.Name } -Descending |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'chrome.dll') } |
            Select-Object -First 1
        if ($best) { return (Join-Path $best.FullName 'chrome.dll') }
    }
    throw 'No installed Brave (chrome.dll) was found. Pass -Dll.'
}

if (-not $Dll) { $Dll = Find-BraveDll }
$braveVersion = Split-Path -Leaf (Split-Path -Parent $Dll)
Write-Host "Reading $Dll"

# ---- locate a policy name we know is in the table (chunked, so 300+ MB never sits in one string) -------------------
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
$anchorText = "`0HomepageLocation`0"
$chunk = 64MB
$overlap = 256
$anchor = -1
$fs = [System.IO.File]::Open($Dll, 'Open', 'Read', 'ReadWrite')
try {
    $buffer = New-Object byte[] ($chunk + $overlap)
    $position = 0L
    while ($position -lt $fs.Length -and $anchor -lt 0) {
        [void]$fs.Seek($position, 'Begin')
        $read = $fs.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }
        $hit = $latin1.GetString($buffer, 0, $read).IndexOf($anchorText, [System.StringComparison]::Ordinal)
        if ($hit -ge 0) { $anchor = $position + $hit + 1 }
        $position += $chunk
    }
    if ($anchor -lt 0) { throw 'The policy table was not found (is this a Chromium-based chrome.dll?).' }

    # ---- read a window around it and split it into NUL-terminated strings -----------------------------------------------
    $windowStart = [Math]::Max(0L, $anchor - 200000)
    $window = New-Object byte[] 400000
    [void]$fs.Seek($windowStart, 'Begin')
    $got = $fs.Read($window, 0, $window.Length)
} finally {
    $fs.Dispose()
}
$text = $latin1.GetString($window, 0, $got)
$strings = New-Object System.Collections.ArrayList
foreach ($m in [regex]::Matches($text, '(?<=\x00)([\x20-\x7e]{2,200})(?=\x00)')) {
    [void]$strings.Add([pscustomobject]@{ Offset = $windowStart + $m.Groups[1].Index; Text = $m.Groups[1].Value })
}
$idx = -1
for ($i = 0; $i -lt $strings.Count; $i++) { if ($strings[$i].Offset -eq $anchor) { $idx = $i; break } }
if ($idx -lt 0) { throw 'Could not line the anchor up with the string table.' }

# The table is the maximal alphabetically sorted, tightly packed run around the anchor.
$lo = $idx
while ($lo -gt 0 -and [string]::CompareOrdinal($strings[$lo - 1].Text, $strings[$lo].Text) -le 0 -and ($strings[$lo].Offset - $strings[$lo - 1].Offset) -lt 200) { $lo-- }
$hi = $idx
while ($hi + 1 -lt $strings.Count -and [string]::CompareOrdinal($strings[$hi].Text, $strings[$hi + 1].Text) -le 0 -and ($strings[$hi + 1].Offset - $strings[$hi].Offset) -lt 200) { $hi++ }
$names = @($strings[$lo..$hi] | ForEach-Object { $_.Text } | Select-Object -Unique)
if ($names.Count -lt 300) { throw "Only $($names.Count) names were found; the layout of this Brave is different. Not writing anything." }
Write-Host ("Brave {0} knows {1} policy names ({2} ... {3})" -f $braveVersion, $names.Count, $names[0], $names[-1])

# ---- what the app offers ----------------------------------------------------------------------------------------------
$appText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'Brave-Free-Origin.ps1'))
$catalog = @([regex]::Matches($appText, "(?m)^\s+'\w+\|(\w+)\|(?:DWORD|STRING)\|") | ForEach-Object { $_.Groups[1].Value })
$overrideBlock = [regex]::Match($appText, '\$script:OverridePolicyNames = @\((.*?)\)', 'Singleline').Groups[1].Value
$overrides = @([regex]::Matches($overrideBlock, "'(\w+)'") | ForEach-Object { $_.Groups[1].Value }) + @('RestoreOnStartupURLs')
$offered = @($catalog + $overrides | Select-Object -Unique)
$unknown = @($offered | Where-Object { $names -notcontains $_ })

if ($Check) {
    Write-Host ("The app offers {0} policy names." -f $offered.Count)
    if ($unknown.Count -eq 0) { Write-Host 'Every one of them is known to this Brave.'; return }
    Write-Host ("{0} of them are NOT known to Brave {1} (a policy Brave does not know is ignored):" -f $unknown.Count, $braveVersion)
    $unknown | ForEach-Object { Write-Host "  - $_" }
    exit 1
}

$dir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
$header = @(
    "# Policy names compiled into chrome.dll of Brave $braveVersion.",
    '# Generated by tools\Export-BravePolicyNames.ps1 - do not edit by hand.',
    '# tools\Test-App.ps1 checks every policy of the catalog against this list, so a name that Brave does not know',
    '# (removed upstream, renamed, or a typo) fails the tests instead of silently doing nothing.',
    "# Names: $($names.Count)"
)
[System.IO.File]::WriteAllText($OutFile, (($header + $names) -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Wrote $OutFile"
if ($unknown.Count -gt 0) {
    Write-Host ("Note: {0} name(s) offered by the app are not in this list: {1}" -f $unknown.Count, ($unknown -join ', '))
}
