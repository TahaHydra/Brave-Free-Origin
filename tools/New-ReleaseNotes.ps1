<#
.SYNOPSIS
    Builds the text of a GitHub release from CHANGELOG.md: install lines first, the short summary of the version,
    and everything else folded away so the release page stays short.

.DESCRIPTION
    The release workflow calls this; run it by hand to see what a release page will look like.

    The section of CHANGELOG.md for the version is split at its first "### " heading:
      - the paragraph(s) before it are shown (keep them to a sentence or two);
      - the "### " sections after it go into a collapsed "Everything that changed" block;
      - a collapsed "Older versions" block says where earlier releases went (they are hidden, not deleted).
    GitHub renders <details> in release notes, so readers can expand what they want.

.PARAMETER Version
    For example 2.0.1 (with or without a leading v).

.PARAMETER ChangelogPath
    Default: CHANGELOG.md next to this script's folder.

.PARAMETER OutFile
    Where to write the notes (UTF-8, no BOM). Default: release-notes.md in the current folder.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\New-ReleaseNotes.ps1 -Version 2.0.1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$ChangelogPath,
    [string]$OutFile,
    [string]$Repo = 'TahaHydra/Brave-Free-Origin'
)

$ErrorActionPreference = 'Stop'
$Version = $Version.TrimStart('v', 'V')
if (-not $ChangelogPath) { $ChangelogPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'CHANGELOG.md' }
if (-not $OutFile) { $OutFile = Join-Path (Get-Location).Path 'release-notes.md' }

$utf8 = New-Object System.Text.UTF8Encoding($false)
$text = [System.IO.File]::ReadAllText($ChangelogPath, $utf8) -replace "`r`n", "`n"
$pattern = '(?ms)^##\s+\[?v?' + [regex]::Escape($Version) + '\]?[^\n]*\n(.*?)(?=^##\s|\z)'
$m = [regex]::Match($text, $pattern)
if (-not $m.Success) { throw "CHANGELOG.md has no section for $Version." }
$section = $m.Groups[1].Value.Trim()

# The summary is what comes before the first "### " heading; the rest is folded.
$split = [regex]::Match($section, '(?m)^###\s')
if ($split.Success) {
    $summary = $section.Substring(0, $split.Index).Trim()
    $details = $section.Substring($split.Index).Trim()
} else {
    $summary = $section
    $details = ''
}

$out = New-Object System.Collections.Generic.List[string]
$out.Add('## Install')
$out.Add('')
$out.Add('- **One line** (Windows PowerShell): `irm https://xhydra.fr/bfo | iex`')
$out.Add('- **Portable:** download `Brave-Free-Origin.zip` below, extract it and double-click `Brave-Free-Origin.bat`. Its SHA-256 is in `SHA256SUMS.txt`.')
$out.Add('')
$out.Add("## What is new in $Version")
$out.Add('')
$out.Add($summary)
$out.Add('')
if ($details) {
    $out.Add('<details>')
    $out.Add('<summary>Everything that changed (click to open)</summary>')
    $out.Add('')
    $out.Add($details)
    $out.Add('')
    $out.Add('</details>')
    $out.Add('')
}
$out.Add('<details>')
$out.Add('<summary>Older versions</summary>')
$out.Add('')
$out.Add("Earlier releases are hidden from this page to keep it short. Their source code is on the [Tags](https://github.com/$Repo/tags) page, and what changed in each one is in [CHANGELOG.md](https://github.com/$Repo/blob/main/CHANGELOG.md).")
$out.Add('')
$out.Add('</details>')

[System.IO.File]::WriteAllText($OutFile, (($out -join "`n") + "`n"), $utf8)
"Wrote $OutFile ($((Get-Item -LiteralPath $OutFile).Length) bytes) for $Version"
