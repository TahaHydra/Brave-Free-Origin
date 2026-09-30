<#
.SYNOPSIS
    Validates every file in locales\ against the English catalog embedded in
    Brave-Free-Origin.ps1.

.DESCRIPTION
    Translations are inert data. This is the gate that keeps them that way.
    A locale file may only replace keys English already defines - it can never
    introduce a registry path, policy name, domain, URL or numeric value,
    because those live in the data model, not in the string catalog.

    Checks per locale:
      * valid UTF-8, valid JSON, no BOM
      * meta block present with locale / name / englishName
      * meta.locale matches the file name
      * meta.reviewed is a boolean, meta.translators is an array of strings
      * meta.direction, when present, is "ltr" or "rtl" (Arabic ships "rtl")
      * every value is a string
      * no unknown keys (a typo must fail, not silently do nothing)
      * no duplicate keys, detected by walking the JSON rather than by
        pattern-matching one particular indentation style
      * {0} / {1} placeholders match English exactly
      * {{ }} escaped-brace counts match English
      * no control characters other than tab / CR / LF
      * value length within the runtime cap
      * coverage reported; below -MinCoverage fails

    en-US.json is checked for drift against the embedded catalog instead: it
    is generated, so any difference means someone edited the wrong file.

    Runs on Windows PowerShell 5.1 and on PowerShell 7 with identical results.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\Test-Locales.ps1

.EXAMPLE
    pwsh -File tools\Test-Locales.ps1 -MinCoverage 60
#>
[CmdletBinding()]
param(
    # Left empty on purpose. $PSScriptRoot is not yet populated while param()
    # default expressions are evaluated under Windows PowerShell 5.1, so a
    # default of (Join-Path $PSScriptRoot ...) makes the script unusable
    # without explicit paths. Defaults are resolved in the body instead.
    [string]$ScriptPath,
    [string]$LocaleDir,
    [int]$MinCoverage    = 50,
    [int]$MaxValueLength = 2000
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ScriptPath) { $ScriptPath = Join-Path $repoRoot 'Brave-Free-Origin.ps1' }
if (-not $LocaleDir)  { $LocaleDir  = Join-Path $repoRoot 'locales' }

$script:failures = @()
$script:warnings = @()
function Add-Failure { param([string]$Message) $script:failures += $Message }
function Add-Warning { param([string]$Message) $script:warnings += $Message }

# ---- duplicate-key detection ------------------------------------------------
# ConvertFrom-Json silently keeps the last of a duplicated key, so the raw text
# has to be inspected. A regex over "^\s{4}"key":" only works for one exact
# pretty-printer; this walks the document instead, so any indentation, minified
# input or nesting depth gives the same answer.
function Get-JsonKeyOccurrence {
    param([string]$Raw)

    $found  = New-Object System.Collections.ArrayList
    $frames = New-Object System.Collections.ArrayList
    $i = 0
    $n = $Raw.Length

    function Read-JsonString {
        param([string]$Text, [int]$Start, [ref]$Next)
        # $Start points at the opening quote.
        $sb = New-Object System.Text.StringBuilder
        $j  = $Start + 1
        while ($j -lt $Text.Length) {
            $c = $Text[$j]
            if ($c -eq '\') {
                if ($j + 1 -ge $Text.Length) { break }
                $e = $Text[$j + 1]
                switch ($e) {
                    'u' {
                        if ($j + 5 -lt $Text.Length) {
                            $hex = $Text.Substring($j + 2, 4)
                            $code = 0
                            if ([int]::TryParse($hex, [System.Globalization.NumberStyles]::HexNumber,
                                                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$code)) {
                                [void]$sb.Append([char]$code)
                            }
                            $j += 6
                        } else { $j += 2 }
                    }
                    'n'     { [void]$sb.Append("`n"); $j += 2 }
                    'r'     { [void]$sb.Append("`r"); $j += 2 }
                    't'     { [void]$sb.Append("`t"); $j += 2 }
                    'b'     { [void]$sb.Append([char]8);  $j += 2 }
                    'f'     { [void]$sb.Append([char]12); $j += 2 }
                    default { [void]$sb.Append($e);    $j += 2 }
                }
                continue
            }
            if ($c -eq '"') { $j++; break }
            [void]$sb.Append($c)
            $j++
        }
        $Next.Value = $j
        return $sb.ToString()
    }

    while ($i -lt $n) {
        $c = $Raw[$i]
        if ($c -eq ' ' -or $c -eq "`t" -or $c -eq "`r" -or $c -eq "`n") { $i++; continue }

        if ($c -eq '{' -or $c -eq '[') {
            $name = '$'
            if ($frames.Count -gt 0) {
                $parent = $frames[$frames.Count - 1]
                if ($parent.CurrentKey) { $name = $parent.CurrentKey } else { $name = '[]' }
            }
            [void]$frames.Add([pscustomobject]@{
                Kind = $(if ($c -eq '{') { 'obj' } else { 'arr' })
                Name = $name
                CurrentKey = $null
                ExpectKey  = ($c -eq '{')
            })
            $i++
            continue
        }
        if ($c -eq '}' -or $c -eq ']') {
            if ($frames.Count -gt 0) { $frames.RemoveAt($frames.Count - 1) }
            $i++
            continue
        }
        if ($c -eq ',') {
            if ($frames.Count -gt 0) {
                $top = $frames[$frames.Count - 1]
                if ($top.Kind -eq 'obj') { $top.ExpectKey = $true; $top.CurrentKey = $null }
            }
            $i++
            continue
        }
        if ($c -eq ':') { $i++; continue }
        if ($c -eq '"') {
            $next = 0
            $value = Read-JsonString -Text $Raw -Start $i -Next ([ref]$next)
            if ($frames.Count -gt 0) {
                $top = $frames[$frames.Count - 1]
                if ($top.Kind -eq 'obj' -and $top.ExpectKey) {
                    $top.CurrentKey = $value
                    $top.ExpectKey  = $false
                    $container = (@($frames | ForEach-Object { $_.Name }) -join '/')
                    [void]$found.Add([pscustomobject]@{ Container = $container; Key = $value })
                }
            }
            $i = $next
            continue
        }
        # Number, true, false, null - consume until a structural character.
        while ($i -lt $n -and $Raw[$i] -notmatch '[\{\}\[\],:"\s]') { $i++ }
        if ($i -lt $n -and $Raw[$i] -match '[\{\}\[\],:"\s]') { continue }
    }
    return $found
}

# ---- embedded English catalog ----------------------------------------------
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $ScriptPath).Path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) {
    $parseErrors | ForEach-Object { Write-Host "  parse: $($_.Message)" }
    throw "$ScriptPath does not parse."
}

$english = @{}
$calls = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq 'Add-Strings'
}, $true)
foreach ($call in $calls) {
    $table = $call.CommandElements |
             Where-Object { $_ -is [System.Management.Automation.Language.HashtableAst] } |
             Select-Object -First 1
    if (-not $table) { continue }
    foreach ($pair in $table.KeyValuePairs) {
        $k = $pair.Item1.SafeGetValue()
        if ($english.ContainsKey($k)) { Add-Failure "Duplicate key in embedded catalog: $k" }
        $english[$k] = [string]$pair.Item2.SafeGetValue()
    }
}
if ($english.Count -eq 0) { throw 'No Add-Strings blocks found - catalog extraction failed.' }
Write-Host "Embedded English catalog: $($english.Count) keys."

# Every key the app asks for at runtime must exist in English.
$sourceText = Get-Content $ScriptPath -Raw
$referenced = @{}
foreach ($m in [regex]::Matches($sourceText, "(?:\bT\s+|Set-Loc(?:Tooltip)?\s+\`$[^\s]+\s+|Set-FlowTabTitleKey\s+\`$[^\s]+\s+|(?:Label|Name|Description)Key\s*=\s*)'([a-z][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)+)'")) {
    $referenced[$m.Groups[1].Value] = $true
}
foreach ($key in $referenced.Keys) {
    if (-not $english.ContainsKey($key)) { Add-Failure "Key used in code but missing from the English catalog: $key" }
}

# ---- locale files ------------------------------------------------------------
$placeholder  = [regex]'\{(\d+)\}'
$controlChars = [regex]'[\x00-\x08\x0B\x0C\x0E-\x1F]'

if (-not (Test-Path $LocaleDir)) { throw "Locale directory not found: $LocaleDir" }
$files = @(Get-ChildItem -LiteralPath $LocaleDir -Filter '*.json' -File | Sort-Object Name)
if ($files.Count -eq 0) { Add-Warning 'No locale files found.' }

foreach ($file in $files) {
    $code = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Add-Failure "$code : file has a UTF-8 BOM; save it without one."
    }

    $strict = New-Object System.Text.UTF8Encoding($false, $true)
    try { $raw = $strict.GetString($bytes) }
    catch { Add-Failure "$code : not valid UTF-8."; continue }

    try { $doc = $raw | ConvertFrom-Json }
    catch { Add-Failure "$code : invalid JSON - $($_.Exception.Message)"; continue }

    if (-not $doc.meta)    { Add-Failure "$code : missing meta block."; continue }
    if (-not $doc.strings) { Add-Failure "$code : missing strings block."; continue }
    if ($doc.strings -isnot [System.Management.Automation.PSCustomObject]) {
        Add-Failure "$code : 'strings' must be a JSON object."; continue
    }
    foreach ($field in @('locale', 'name', 'englishName')) {
        if (-not $doc.meta.$field) { Add-Failure "$code : meta.$field is missing." }
        elseif ($doc.meta.$field -isnot [string]) { Add-Failure "$code : meta.$field must be a string." }
    }
    if ($doc.meta.locale -and "$($doc.meta.locale)" -ne $code) {
        Add-Failure "$code : meta.locale is '$($doc.meta.locale)' but the file is named $($file.Name)."
    }
    $metaNames = @($doc.meta.PSObject.Properties.Name)
    if ($metaNames -contains 'direction' -and "$($doc.meta.direction)" -notin @('ltr', 'rtl')) {
        Add-Failure "$code : meta.direction must be 'ltr' or 'rtl'."
    }
    if ($metaNames -contains 'reviewed' -and $doc.meta.reviewed -isnot [bool]) {
        Add-Failure "$code : meta.reviewed must be true or false, not a string."
    }
    if ($metaNames -contains 'appVersion' -and $doc.meta.appVersion -isnot [string]) {
        Add-Failure "$code : meta.appVersion must be a string."
    }
    if ($metaNames -contains 'translators') {
        if ($doc.meta.translators -isnot [System.Array]) {
            Add-Failure "$code : meta.translators must be an array."
        } else {
            foreach ($t in $doc.meta.translators) {
                if ($t -isnot [string]) { Add-Failure "$code : meta.translators must contain strings only." }
            }
        }
    }

    $occurrences = Get-JsonKeyOccurrence -Raw $raw
    $dupes = $occurrences | Group-Object -Property { "$($_.Container)|$($_.Key)" } | Where-Object { $_.Count -gt 1 }
    foreach ($d in $dupes) {
        $parts = $d.Name -split '\|', 2
        Add-Failure "$code : duplicate key '$($parts[1])' inside '$($parts[0])'."
    }

    $props = @($doc.strings.PSObject.Properties)
    $translated = 0
    foreach ($p in $props) {
        $key = $p.Name
        $val = $p.Value

        if (-not $english.ContainsKey($key)) {
            Add-Failure "$code : unknown key '$key' (not in the English catalog)."
            continue
        }
        if ($val -isnot [string]) {
            Add-Failure "$code : '$key' is $(if ($null -eq $val) { 'null' } else { $val.GetType().Name }), expected a string."
            continue
        }
        if ($val.Length -gt $MaxValueLength) {
            Add-Failure "$code : '$key' is $($val.Length) chars, over the $MaxValueLength cap."
        }
        if ($controlChars.IsMatch($val)) {
            Add-Failure "$code : '$key' contains control characters."
        }

        $en = $english[$key]
        $enPh = @($placeholder.Matches($en) | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        $loPh = @($placeholder.Matches($val) | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        if (($enPh -join ',') -ne ($loPh -join ',')) {
            Add-Failure "$code : '$key' placeholder mismatch - English has [$($enPh -join ',')], translation has [$($loPh -join ',')]."
        }
        foreach ($brace in @('\{\{', '\}\}')) {
            $enEsc = ([regex]::Matches($en,  $brace)).Count
            $loEsc = ([regex]::Matches($val, $brace)).Count
            if ($enEsc -ne $loEsc) {
                Add-Failure "$code : '$key' escaped-brace count differs (English $enEsc, translation $loEsc)."
            }
        }
        if ($val -ne $en) { $translated++ }
    }

    $coverage = [math]::Round(100.0 * $props.Count / $english.Count)
    $missing  = $english.Count - $props.Count
    Write-Host ("{0,-8} {1,4} keys  {2,3}% coverage  {3,4} missing  ({4} differ from English)" -f `
        $code, $props.Count, $coverage, $missing, $translated)

    if ($code -eq 'en-US') {
        # Generated file: must be an exact mirror of the embedded catalog.
        $names = @($doc.strings.PSObject.Properties.Name)
        foreach ($key in $english.Keys) {
            if ($names -notcontains $key) {
                Add-Failure "en-US : '$key' is missing. Run tools\Export-EnglishLocale.ps1."
            } elseif ("$($doc.strings.$key)" -ne $english[$key]) {
                Add-Failure "en-US : '$key' differs from the embedded catalog. Run tools\Export-EnglishLocale.ps1."
            }
        }
        continue
    }

    if ($coverage -lt $MinCoverage) {
        Add-Failure "$code : coverage $coverage% is below the $MinCoverage% minimum."
    }
    if (-not $doc.meta.reviewed) {
        Add-Warning "$code : meta.reviewed is false - the UI will show an 'unreviewed' note."
    }
}

if ($script:warnings) {
    Write-Host ''
    Write-Host 'Warnings:'
    $script:warnings | ForEach-Object { Write-Host "  - $_" }
}
if ($script:failures) {
    Write-Host ''
    Write-Host "Failures ($($script:failures.Count)):"
    $script:failures | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
Write-Host ''
Write-Host 'Locale validation OK.'
