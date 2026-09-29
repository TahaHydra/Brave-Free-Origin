# ============================================================================
#  Brave Free Origin - GUI edition for Windows
#  Applies Brave Browser group policies via the registry with a checkbox UI.
#  Source policies researched from brave/brave-core and Chromium enterprise docs.
#
#  This file is deliberately pure ASCII. Windows PowerShell 5.1 decodes a
#  BOM-less .ps1 using the system ANSI code page, so any literal non-ASCII text
#  here would mojibake on machines with a different code page. Translations
#  live in locales\*.json and are read with an explicit UTF-8 decoder.
#
#  Layout of this file (search for the region names):
#    Bootstrap        parameters, elevation, error handling, logging, sandbox
#    i18n runtime     locale loading, fonts, right-to-left support
#    English catalog  every user-visible string (single source of truth)
#    Catalog data     policies, presets, hosts groups, search engines
#    Core             registry, backups, hosts file, tasks/services, planning
#    Scriptlets       optional expert tool for Brave's built-in filter lists
#    UI               window, pages, dialogs
#    Startup          locale bootstrap, first load, message loop / self-test
# ============================================================================

[CmdletBinding()]
param(
    # Force a UI language, e.g. -Lang fr-FR. Falls back to the saved setting,
    # then the Windows UI culture, then English.
    [string]$Lang,

    # Resolved before elevation and forwarded across the UAC boundary, so an
    # elevated administrator account still reads and writes the original
    # user's preference file instead of its own.
    [string]$BfoSettingsPath,

    # Maintainer hook (see tools\Test-App.ps1). Path to a script that is run
    # inside the finished app instead of showing the window. It also switches
    # the app into a sandbox: no HKLM, no hosts file, no scheduled tasks and no
    # services are touched, and no UAC prompt is shown.
    [string]$SelfTest
)

#region Bootstrap -------------------------------------------------------------
$ErrorActionPreference = 'Stop'

$script:AppVersion       = '1.13'
$script:CatalogBrave     = '154.1.96.59'   # Brave build the policy catalog was verified against
$script:CatalogBraveMajor = 154
$script:CatalogDate      = '2026-09-29'
$script:SelfTestMode     = -not [string]::IsNullOrWhiteSpace($SelfTest)
$script:ProjectUrl       = 'https://github.com/TahaHydra/Brave-Free-Origin'

if (-not $BfoSettingsPath) {
    $BfoSettingsPath = Join-Path $env:LOCALAPPDATA 'Brave-Free-Origin\settings.json'
}
$script:SettingsPath = $BfoSettingsPath
$script:AppDataDir   = Split-Path -Parent $BfoSettingsPath
$script:LogDir       = Join-Path $script:AppDataDir 'logs'
$script:LogFile      = Join-Path $script:LogDir ('bfo-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))

function Test-IsAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Elevation. Policies live under HKLM, so the app needs administrator rights.
# The relaunch is hidden (the GUI is the only window the user should see) and
# a refused UAC prompt is explained instead of surfacing as a red PowerShell
# error and a misleading launcher message.
if (-not $script:SelfTestMode -and -not (Test-IsAdministrator)) {
    $relaunchArgs = @(
        '-NoLogo', '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-WindowStyle', 'Hidden'
        '-File', ('"{0}"' -f $PSCommandPath)
        '-BfoSettingsPath', ('"{0}"' -f $BfoSettingsPath)
    )
    if ($Lang) { $relaunchArgs += @('-Lang', ('"{0}"' -f $Lang)) }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $relaunchArgs -ErrorAction Stop | Out-Null
        exit 0
    } catch {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(
            "Brave Free Origin needs administrator permission to change Brave's machine-wide policies.`r`n`r`nStart it again and choose Yes on the Windows prompt.",
            'Brave Free Origin',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information)
        exit 2
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

# ---- Sandbox ---------------------------------------------------------------
# In self-test mode every machine-level side effect is redirected, so the whole
# apply / verify / restore pipeline can be exercised without administrator
# rights and without touching a real Brave install.
$script:SandboxRegistryRoot = 'HKCU:\Software\Brave-Free-Origin-SelfTest\Policies\BraveSoftware'
$script:SandboxHostsFile    = Join-Path ([System.IO.Path]::GetTempPath()) 'bfo-selftest-hosts.txt'

function Get-PolicyHivePath {
    param([string]$ChannelKey)   # 'Brave', 'Brave-Beta', 'Brave-Nightly', 'Brave-Dev'
    if ($script:SelfTestMode) { return "$($script:SandboxRegistryRoot)\$ChannelKey" }
    return "HKLM:\Software\Policies\BraveSoftware\$ChannelKey"
}

# ---- Logging and error reporting -------------------------------------------
$script:LogBox      = $null
$script:StatusLabel = $null
$script:Form        = $null

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    if ($script:LogBox) {
        try {
            $script:LogBox.AppendText("$line`r`n")
            $script:LogBox.SelectionStart = $script:LogBox.Text.Length
            $script:LogBox.ScrollToCaret()
        } catch { }
    }
    if ($script:StatusLabel) {
        try { $script:StatusLabel.Text = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message } catch { }
    }
    # A log file is what makes a hidden-console GUI supportable: a user can
    # attach it to an issue. Failing to write it must never break the app.
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        [System.IO.File]::AppendAllText($script:LogFile, "$line`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Remove-OldLogs {
    try {
        Get-ChildItem -LiteralPath $script:LogDir -Filter 'bfo-*.log' -File -ErrorAction Stop |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 7 | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Format-ErrorRecord {
    param($ErrorRecord)
    $text = "$($ErrorRecord.Exception.Message)"
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.PositionMessage) {
        $text += "`r`n" + $ErrorRecord.InvocationInfo.PositionMessage.Trim()
    }
    if ($ErrorRecord.ScriptStackTrace) { $text += "`r`n" + $ErrorRecord.ScriptStackTrace }
    return $text
}

function Show-FatalError {
    param($ErrorRecord)
    $detail = Format-ErrorRecord $ErrorRecord
    try { Write-Log "FATAL: $detail" 'ERR' } catch { }
    if ($script:SelfTestMode) { [Console]::Error.WriteLine("FATAL: $detail"); return }
    try {
        [void][System.Windows.Forms.MessageBox]::Show(
            "Brave Free Origin could not start.`r`n`r`n$($ErrorRecord.Exception.Message)`r`n`r`nDetails were saved to:`r`n$($script:LogFile)",
            'Brave Free Origin',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error)
    } catch { }
}

# Anything that escapes to script scope is a startup failure. The elevated
# console is hidden, so without this the user would see nothing at all.
trap { Show-FatalError $_; exit 1 }

Remove-OldLogs
Write-Log ("Starting Brave Free Origin v{0} (PowerShell {1}, self-test: {2})" -f $script:AppVersion, $PSVersionTable.PSVersion, $script:SelfTestMode)
#endregion


#region i18n runtime ----------------------------------------------------------
# Localization engine.
#
# Design rules (see TRANSLATING.md):
#   * This .ps1 stays pure ASCII. Windows PowerShell 5.1 decodes a BOM-less
#     script with the system ANSI code page, so literal non-Latin text here
#     would mojibake on any machine whose code page is not the translator's.
#   * The English catalog below is the single runtime source of truth. The app
#     is fully usable with no locales\ folder at all.
#   * Translations are inert JSON data. They are never executed, they can only
#     replace keys that already exist in English, and they can never supply a
#     registry path, policy name, domain, URL or numeric value.
$script:EnglishStrings  = @{}
$script:LocaleStrings   = @{}
$script:CurrentLocale   = 'en-US'
$script:IsRtl           = $false
$script:I18nBindings    = New-Object System.Collections.ArrayList
$script:LocFontBindings = New-Object System.Collections.ArrayList
$script:LocaleDir       = Join-Path $PSScriptRoot 'locales'
$script:MaxLocaleValue  = 2000
$script:RtlLanguages    = @('ar', 'he', 'fa', 'ur')

# Re-entrant guard for "the code is changing controls, not the user".
# WinForms raises SelectedIndexChanged / CheckedChanged for programmatic
# writes exactly as it does for clicks, so every bulk update (preset, import,
# load current state, language switch) has to mute the handlers or the app
# would conclude the user hand-picked a Custom loadout. Depth-counted because
# these operations nest: a language switch relabels ComboBoxes, which
# reselects, which would otherwise clear the flag too early.
$script:SuppressSelectionEvents = $false
$script:SuppressDepth           = 0

function Push-SuppressSelectionEvents {
    $script:SuppressDepth++
    $script:SuppressSelectionEvents = $true
}

function Pop-SuppressSelectionEvents {
    if ($script:SuppressDepth -gt 0) { $script:SuppressDepth-- }
    if ($script:SuppressDepth -le 0) {
        $script:SuppressDepth = 0
        $script:SuppressSelectionEvents = $false
    }
}

function Add-Strings {
    param([hashtable]$Map)
    foreach ($k in $Map.Keys) { $script:EnglishStrings[$k] = $Map[$k] }
}

function T {
    param(
        [Parameter(Mandatory)][string]$Key,
        # Deliberately NOT named $Args: that would shadow the automatic
        # variable inside a simple function.
        [object[]]$FormatArgs
    )
    if ($script:LocaleStrings.ContainsKey($Key)) {
        $text = $script:LocaleStrings[$Key]
    } elseif ($script:EnglishStrings.ContainsKey($Key)) {
        $text = $script:EnglishStrings[$Key]
    } else {
        # Loud on purpose: a missing key should be obvious during development.
        return "!!$Key!!"
    }
    if ($FormatArgs -and $FormatArgs.Count -gt 0) {
        try { return ($text -f $FormatArgs) } catch { return $text }
    }
    return $text
}

# English text regardless of the active language. Reports and the log stay
# English so a translated install still produces bug reports the maintainer
# can read.
function TEn {
    param([Parameter(Mandatory)][string]$Key, [object[]]$FormatArgs)
    if (-not $script:EnglishStrings.ContainsKey($Key)) { return "!!$Key!!" }
    $text = $script:EnglishStrings[$Key]
    if ($FormatArgs -and $FormatArgs.Count -gt 0) {
        try { return ($text -f $FormatArgs) } catch { return $text }
    }
    return $text
}

# ---- Locale files -----------------------------------------------------------
function Test-IsRtlCode {
    param([string]$Code)
    if ([string]::IsNullOrWhiteSpace($Code)) { return $false }
    return ($script:RtlLanguages -contains (($Code -split '-')[0]).ToLowerInvariant())
}

function Get-AvailableLocales {
    $list = @([pscustomobject]@{
        Code = 'en-US'; Name = 'English'; EnglishName = 'English'; Path = $null; Reviewed = $true; Rtl = $false
    })
    if (-not (Test-Path -LiteralPath $script:LocaleDir)) { return $list }
    $found = @()
    foreach ($file in (Get-ChildItem -LiteralPath $script:LocaleDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $code = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($code -eq 'en-US') { continue }
        $meta = $null
        try {
            $probe = Import-LocaleFile -Path $file.FullName
            if ($probe) { $meta = $probe.Meta }
        } catch { continue }
        if (-not $meta) { continue }
        $display = $code
        if ($meta.name) { $display = "$($meta.name)" }
        $english = $display
        if ($meta.englishName) { $english = "$($meta.englishName)" }
        $rtl = (Test-IsRtlCode $code)
        if ($meta.direction) { $rtl = ("$($meta.direction)".ToLowerInvariant() -eq 'rtl') }
        $found += [pscustomobject]@{
            Code        = $code
            Name        = $display
            EnglishName = $english
            Path        = $file.FullName
            Reviewed    = [bool]$meta.reviewed
            Rtl         = $rtl
        }
    }
    # English first (it is the default), then the rest alphabetically by their
    # English name so the order does not depend on the script they are written in.
    return @($list) + @($found | Sort-Object EnglishName)
}

function Import-LocaleFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    # Explicit UTF-8 decode. Get-Content -Encoding UTF8 behaves differently
    # between Windows PowerShell 5.1 and PowerShell 7, this does not.
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $raw  = [System.IO.File]::ReadAllText($Path, $utf8)
    $obj  = $raw | ConvertFrom-Json
    if (-not $obj -or -not $obj.strings) { return $null }

    if ($obj.strings -isnot [System.Management.Automation.PSCustomObject]) { return $null }

    $map = @{}
    $rejected = 0
    foreach ($p in $obj.strings.PSObject.Properties) {
        # Structural boundary: a locale may only override keys English already
        # defines. Unknown keys cannot introduce new behavior or new data.
        if (-not $script:EnglishStrings.ContainsKey($p.Name)) { $rejected++; continue }
        if ($p.Value -isnot [string]) { $rejected++; continue }
        if ($p.Value.Length -gt $script:MaxLocaleValue) { $rejected++; continue }
        if ($p.Value -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { $rejected++; continue }
        # A translation that drops or invents a {0} would make -f throw or
        # print a raw placeholder at the user. Reject that one key and keep its
        # English text; never fail a whole locale over a single bad string.
        if (-not (Test-LocalePlaceholderParity -English $script:EnglishStrings[$p.Name] -Candidate $p.Value)) {
            $rejected++; continue
        }
        $map[$p.Name] = $p.Value
    }
    return @{ Meta = $obj.meta; Strings = $map; Rejected = $rejected }
}

# {0}/{1} must appear in both, and {{ }} escapes must balance, or the runtime
# -f would either throw or emit literal braces into the UI.
function Test-LocalePlaceholderParity {
    param([string]$English, [string]$Candidate)
    $rx = [regex]'\{(\d+)\}'
    $en = @($rx.Matches($English)   | ForEach-Object { $_.Groups[1].Value } | Sort-Object) -join ','
    $lo = @($rx.Matches($Candidate) | ForEach-Object { $_.Groups[1].Value } | Sort-Object) -join ','
    if ($en -ne $lo) { return $false }
    if (([regex]::Matches($English, '\{\{')).Count -ne ([regex]::Matches($Candidate, '\{\{')).Count) { return $false }
    if (([regex]::Matches($English, '\}\}')).Count -ne ([regex]::Matches($Candidate, '\}\}')).Count) { return $false }
    return $true
}

function Set-BfoLocale {
    param([string]$Code)

    if (-not $Code -or $Code -eq 'en-US') {
        $script:LocaleStrings = @{}
        $script:CurrentLocale = 'en-US'
        $script:IsRtl         = $false
        Reset-FontPlan
        return $true
    }

    $path = Join-Path $script:LocaleDir ("{0}.json" -f $Code)
    try {
        $loaded = Import-LocaleFile -Path $path
    } catch {
        Write-Log "Locale '$Code' could not be parsed, staying on English: $_" 'WARN'
        return $false
    }
    if (-not $loaded) {
        Write-Log "Locale '$Code' not found or empty, staying on English." 'WARN'
        return $false
    }

    $script:LocaleStrings = $loaded.Strings
    $script:CurrentLocale = $Code
    $script:IsRtl         = (Test-IsRtlCode $Code)
    if ($loaded.Meta -and $loaded.Meta.direction) { $script:IsRtl = ("$($loaded.Meta.direction)".ToLowerInvariant() -eq 'rtl') }
    Reset-FontPlan
    $coverage = if ($script:EnglishStrings.Count -gt 0) {
        [math]::Round(100.0 * $loaded.Strings.Count / $script:EnglishStrings.Count)
    } else { 0 }
    Write-Log "Locale '$Code' loaded: $($loaded.Strings.Count) strings ($coverage% coverage), $($loaded.Rejected) rejected." 'OK'
    return $true
}

# Coarse script tag for a culture name. Only Chinese actually needs this:
# Simplified and Traditional are different writing systems, so silently
# handing a zh-TW / zh-HK / zh-MO / zh-Hant user the Simplified catalog is
# worse than leaving them in English. Every other language we ship has a
# single script, so $null (= "no script constraint") is correct.
function Get-LocaleScriptTag {
    param([string]$Code)
    if ([string]::IsNullOrWhiteSpace($Code)) { return $null }
    $parts = @($Code -split '-' | Where-Object { $_ })
    if ($parts.Count -eq 0) { return $null }
    if ($parts[0].ToLowerInvariant() -ne 'zh') { return $null }
    for ($i = 1; $i -lt $parts.Count; $i++) {
        switch ($parts[$i].ToLowerInvariant()) {
            'hans' { return 'Hans' }
            'hant' { return 'Hant' }
            'cn'   { return 'Hans' }
            'sg'   { return 'Hans' }
            'my'   { return 'Hans' }
            'tw'   { return 'Hant' }
            'hk'   { return 'Hant' }
            'mo'   { return 'Hant' }
        }
    }
    # Bare 'zh' carries no script information at all. Simplified is both the
    # larger population and the first Chinese catalog we shipped, so prefer it.
    return 'Hans'
}

# Startup precedence: -Lang, then the persisted BFO setting, then the Windows
# UI culture, then a same-language / same-script file, then English. English is
# the default, so a PC in a language we do not ship simply gets English.
function Resolve-StartupLocale {
    param([string]$Requested, [string]$Saved, [string]$UiCulture)
    if ([string]::IsNullOrWhiteSpace($UiCulture)) { $UiCulture = [System.Globalization.CultureInfo]::CurrentUICulture.Name }
    $codes = @((Get-AvailableLocales).Code)
    foreach ($candidate in @($Requested, $Saved, $UiCulture)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $exact = @($codes | Where-Object { $_ -eq $candidate })
        if ($exact.Count -gt 0) { return $exact[0] }

        $lang       = ($candidate -split '-')[0]
        $wantScript = Get-LocaleScriptTag -Code $candidate
        $near = @($codes | Where-Object {
            (($_ -split '-')[0]) -eq $lang -and (Get-LocaleScriptTag -Code $_) -eq $wantScript
        })
        if ($near.Count -gt 0) { return $near[0] }
    }
    return 'en-US'
}

# ---- Fonts ------------------------------------------------------------------
# Segoe UI covers Latin, Cyrillic, Greek and Arabic. It has no CJK or Indic
# coverage, so those locales need a family of their own, and none of them has
# a "Semibold" family - bold has to be requested as a style. A font plan is
# resolved once per language switch and Font objects are cached, because every
# `New-Object Font` allocates a GDI handle that would otherwise pile up.
$script:InstalledFonts = $null
$script:FontPlan       = $null
$script:FontCache      = @{}

function Test-FontInstalled {
    param([string]$Family)
    if (-not $script:InstalledFonts) {
        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($f in [System.Drawing.FontFamily]::Families) { [void]$set.Add($f.Name) }
        $script:InstalledFonts = $set
    }
    return $script:InstalledFonts.Contains($Family)
}

function Reset-FontPlan { $script:FontPlan = $null }

function Get-FontPlan {
    if ($script:FontPlan) { return $script:FontPlan }
    $candidates = @()
    $boldStyle  = $true
    # switch runs every matching branch unless told to stop, hence the breaks.
    switch -Wildcard ($script:CurrentLocale) {
        'zh-TW' { $candidates = @('Microsoft JhengHei UI', 'Microsoft JhengHei'); break }
        'zh-*'  { $candidates = @('Microsoft YaHei UI', 'Microsoft YaHei'); break }
        'hi*'   { $candidates = @('Nirmala UI'); break }
        default { $boldStyle = $false }
    }
    $body = 'Segoe UI'
    foreach ($c in $candidates) { if (Test-FontInstalled $c) { $body = $c; break } }
    $semi = 'Segoe UI Semibold'
    if ($boldStyle -or -not (Test-FontInstalled 'Segoe UI Semibold')) { $semi = $body; $boldStyle = $true }
    $script:FontPlan = [pscustomobject]@{ Body = $body; Semibold = $semi; SemiIsBold = $boldStyle }
    return $script:FontPlan
}

function Get-BfoUiFont {
    param([single]$Size = 9, [switch]$Semibold, [switch]$Mono)
    if ($Mono) { $family = 'Consolas'; $style = [System.Drawing.FontStyle]::Regular }
    else {
        $plan   = Get-FontPlan
        $family = if ($Semibold) { $plan.Semibold } else { $plan.Body }
        $style  = if ($Semibold -and $plan.SemiIsBold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    }
    $key = '{0}|{1}|{2}' -f $family, $Size, $style
    if (-not $script:FontCache.ContainsKey($key)) {
        try { $script:FontCache[$key] = New-Object System.Drawing.Font($family, $Size, $style, [System.Drawing.GraphicsUnit]::Point) }
        catch { $script:FontCache[$key] = New-Object System.Drawing.Font('Segoe UI', $Size, $style, [System.Drawing.GraphicsUnit]::Point) }
    }
    return $script:FontCache[$key]
}

# ---- Message boxes ----------------------------------------------------------
# One entry point so every dialog is owned by the main window, and so a
# right-to-left language gets a right-to-left dialog.
function Show-Message {
    param(
        [string]$Text,
        [string]$Title,
        [string]$Buttons = 'OK',
        [string]$Icon = 'Information',
        [string]$Default = 'Button1'
    )
    if (-not $Title) { $Title = T 'msg.title.app' }
    # Self-test: never block on a click. Dialogs are recorded and answered from a
    # queue, or with the affirmative default when the queue is empty.
    if ($script:SelfTestMode) {
        $script:SelfTestDialogs += , @($Title, $Text)
        if ($script:SelfTestAnswers -and $script:SelfTestAnswers.Count -gt 0) { return $script:SelfTestAnswers.Dequeue() }
        if ($Buttons -like 'YesNo*') { return 'Yes' }
        return 'OK'
    }
    $options = 0
    if ($script:IsRtl) {
        $options = [int]([System.Windows.Forms.MessageBoxOptions]::RtlReading -bor [System.Windows.Forms.MessageBoxOptions]::RightAlign)
    }
    $owner = $script:Form
    if ($owner -and $owner.IsHandleCreated) {
        return [System.Windows.Forms.MessageBox]::Show($owner, $Text, $Title, $Buttons, $Icon, $Default, $options)
    }
    return [System.Windows.Forms.MessageBox]::Show($Text, $Title, $Buttons, $Icon, $Default, $options)
}
$script:SelfTestAnswers = New-Object System.Collections.Queue
$script:SelfTestDialogs = @()

# Wraps an event handler body: a failure becomes a logged, explained error
# instead of a silent no-op in a window nobody can see the console of.
function Invoke-Guarded {
    param([string]$Context, [scriptblock]$Action)
    try { & $Action }
    catch {
        $detail = Format-ErrorRecord $_
        Write-Log "$Context failed: $detail" 'ERR'
        try {
            [void](Show-Message -Text ((T 'msg.error.body' @($Context, $_.Exception.Message, $script:LogFile))) -Title (T 'msg.title.error') -Icon 'Error')
        } catch { }
    }
}

[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    Write-Log ("UI thread exception: " + $e.Exception.Message) 'ERR'
})

# ---- Control bindings -------------------------------------------------------
# Every localized control registers itself once, so switching language is a
# single pass instead of 120 hand-maintained assignments.
function Set-Loc {
    param(
        $Control,
        [string]$Key,
        [string]$Property = 'Text',
        [object[]]$FormatArgs,
        # Re-evaluated on every language switch, for arguments that are
        # themselves translated (a group name inside a counted label).
        [scriptblock]$ArgsScript
    )
    if ($ArgsScript) { $FormatArgs = @(& $ArgsScript) }
    $Control.$Property = T $Key $FormatArgs
    [void]$script:I18nBindings.Add([pscustomobject]@{
        Kind = 'Property'; Control = $Control; Property = $Property
        Key  = $Key;       Args    = $FormatArgs; ArgsScript = $ArgsScript
    })
    return $Control
}

function Set-LocTooltip {
    param($Control, [string]$Key, [object[]]$FormatArgs)
    if ($script:ToolTip) { $script:ToolTip.SetToolTip($Control, (T $Key $FormatArgs)) }
    [void]$script:I18nBindings.Add([pscustomobject]@{
        Kind = 'Tooltip'; Control = $Control; Key = $Key; Args = $FormatArgs
    })
}

# Fonts are re-resolved on every language switch, not only at build time:
# registering the *intent* (size + weight) rather than a Font object lets one
# pass rebuild every localized control for the active locale.
function Set-LocFont {
    param($Control, [single]$Size = 9, [switch]$Semibold)
    [void]$script:LocFontBindings.Add([pscustomobject]@{
        Control = $Control; Size = $Size; Semibold = [bool]$Semibold
    })
    $Control.Font = Get-BfoUiFont -Size $Size -Semibold:$Semibold
    return $Control
}

function Update-LocalizedFonts {
    foreach ($binding in $script:LocFontBindings) {
        try { $binding.Control.Font = Get-BfoUiFont -Size $binding.Size -Semibold:$binding.Semibold }
        catch { }
    }
}

# ---- Persisted UI settings --------------------------------------------------
# Stored per-user under LOCALAPPDATA, not beside the script: the script folder
# may be read-only (Program Files) or shared, and the repo should stay clean.
# The path is resolved BEFORE elevation and forwarded across the UAC relaunch
# so an elevated admin account still reads the original user's preference.
function Get-BfoSettings {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @{} }
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $obj = [System.IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json
        $map = @{}
        foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = $p.Value }
        return $map
    } catch {
        Write-Log "Settings file could not be read and was ignored: $_" 'WARN'
        return @{}
    }
}

function Save-BfoSettings {
    param([string]$Path, [hashtable]$Settings)
    if (-not $Path) { return }
    try {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $json = ([pscustomobject]$Settings | ConvertTo-Json -Depth 4)
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($Path, $json, $utf8)
    } catch {
        Write-Log "Settings could not be saved: $_" 'WARN'
    }
}

function Set-BfoSetting {
    param([string]$Name, $Value)
    $settings = Get-BfoSettings -Path $script:SettingsPath
    $settings[$Name] = $Value
    Save-BfoSettings -Path $script:SettingsPath -Settings $settings
}
#endregion


#region English string catalog ------------------------------------------------
# Runtime source of truth for every user-visible string.
# locales\en-US.json is GENERATED from these blocks (tools\Export-EnglishLocale.ps1)
# and exists only as a reference for translators - it is never loaded.
#
# Writing rules: sentence case; say what happens to the person, not how the
# program works; a control keeps the same name everywhere it appears; errors say
# what went wrong and what to do next. Pure ASCII only (double a quote to write it).

# ---- Application chrome ------------------------------------------------------
Add-Strings @{
    'app.name'                = 'Brave Free Origin'
    'app.title'               = 'Brave Free Origin v{0}'
    'header.braveDetected'    = 'Brave {0}  -  {1}'
    'header.braveNotFound'    = 'Brave was not found on this PC'
    'header.compat.newer'     = 'Your Brave (version {0}) is newer than the one this list was checked against ({1}). A few settings may differ. Nothing breaks, and everything is reversible.'
    'header.compat.older'     = 'Your Brave (version {0}) is much older than the one this list was checked against ({1}). Some settings may not exist yet in your version and will simply be ignored.'
    'header.help'             = 'How this works, what each status means, and how to undo'
    'header.language'         = 'Language:'
    'header.scope.machine'    = 'installed for all users'
    'header.scope.user'       = 'installed for this user'
    'header.subtitle'         = 'Turn off the extras you do not want in Brave. Every change is reversible.'
    'header.unreviewedLocale' = 'community translation, unreviewed'
}

# ---- Presets -----------------------------------------------------------------
# Preset ids (Minimal, Origin, ...) are stable and never translated.
Add-Strings @{
    'mode.info'                         = '{0}  -  {1}  -  {2} settings ticked.  {3}'
    'preset.CurrentState.description'   = 'What is set on this PC right now. Pick a preset above or tick rows below; nothing changes until you press Apply.'
    'preset.CurrentState.name'          = 'Current settings'
    'preset.CurrentState.risk'          = 'No changes yet'
    'preset.Custom.description'         = 'Your own mix. Tick what you want on the pages below.'
    'preset.Custom.name'                = 'Custom'
    'preset.Custom.risk'                = 'Depends on your picks'
    'preset.MaxPerformance.description' = 'Privacy + Boost, plus a blank new tab and home page, a fresh start on every launch (no session restore) and a smaller disk cache. The plainest, fastest Brave.'
    'preset.MaxPerformance.name'        = 'Max Performance'
    'preset.MaxPerformance.risk'        = 'Medium risk'
    'preset.MaxPrivacy.description'     = 'Recommended plus strict privacy: no sign-in, sync or imports, no autofill or password prompts, HTTPS only, and site data is forgotten when a tab closes. Expect signed-out sites and extra clicks.'
    'preset.MaxPrivacy.name'            = 'Max Privacy'
    'preset.MaxPrivacy.risk'            = 'High risk'
    'preset.Minimal.description'        = 'Switches off Brave''s six loudest extras: Rewards, Wallet, VPN, Leo AI, News and Talk. Nothing else changes.'
    'preset.Minimal.name'               = 'Quick Debloat'
    'preset.Minimal.risk'               = 'Low risk'
    'preset.None.description'           = 'Stock Brave. Nothing is ticked, so Apply removes everything this tool set and hands control back to Brave.'
    'preset.None.name'                  = 'Stock / None'
    'preset.None.risk'                  = 'No changes'
    'preset.Origin.description'         = 'The free, local version of Brave Origin''s idea: no Leo, Rewards, Wallet, VPN, News, Talk, Tor, Wayback Machine, Playlist, Speedreader, Email Aliases or usage analytics, with Shields kept strong.'
    'preset.Origin.name'                = 'Origin Mode'
    'preset.Origin.risk'                = 'Low risk'
    'preset.Performance.description'    = 'Origin Mode and Recommended together, plus Memory Saver, Battery Saver, no background running, no Cast and no Live Caption download. A lighter browser for gaming, streaming or low-power laptops.'
    'preset.Performance.name'           = 'Privacy + Boost'
    'preset.Performance.risk'           = 'Medium risk'
    'preset.Recommended.description'    = 'Quick Debloat plus telemetry off, Chromium''s AI and promo features off, and Brave''s protections locked on. Passwords, autofill, sync, updates and session restore are left alone.'
    'preset.Recommended.name'           = 'Recommended'
    'preset.Recommended.risk'           = 'Low risk'
}

# ---- Navigation and pages ----------------------------------------------------
Add-Strings @{
    'nav.group.advanced'                = 'Advanced'
    'nav.group.settings'                = 'Settings'
    'page.aiGenAi.intro'                = 'Brave''s own AI plus the Google-based AI features that ship with Chromium. Ticking keeps them off.'
    'page.aiGenAi.title'                = 'AI features'
    'page.autofillPasswords.intro'      = 'Convenience features that store personal data. Turning them off is stricter, but less convenient.'
    'page.autofillPasswords.title'      = 'Passwords and autofill'
    'page.braveFeatures.intro'          = 'Features Brave adds on top of the browser. Tick one to switch it off for good.'
    'page.braveFeatures.title'          = 'Brave extras'
    'page.hosts.intro'                  = 'A second line of defence: block Brave''s telemetry domains at the Windows level. This page has its own Apply button and never runs from the main one.'
    'page.hosts.title'                  = 'Hosts blocklist'
    'page.overrides.intro'              = 'Choose the address-bar search engine and what opens on launch and on new tabs. Each section only applies when its box is ticked.'
    'page.overrides.title'              = 'Search engine and startup'
    'page.performanceStartup.intro'     = 'Memory, battery, disk and what opens when Brave starts.'
    'page.performanceStartup.title'     = 'Performance and startup'
    'page.privacyTelemetry.intro'       = 'Usage statistics, crash reports and remote experiments. Ticking stops the data from being sent.'
    'page.privacyTelemetry.title'       = 'Telemetry and reports'
    'page.safetyUpdates.intro'          = 'Safe Browsing details and the prompts Brave shows about itself.'
    'page.safetyUpdates.title'          = 'Safety and prompts'
    'page.scriptlets.intro'             = 'Optional expert tool: view Brave''s built-in adblock scriptlet rules from component filter lists. Editing is manual-only, never part of presets, and never triggered by Apply to Brave.'
    'page.scriptlets.title'             = 'Scriptlets (expert)'
    'page.searchSuggestions.intro'      = 'What the address bar and text boxes send to web services while you type.'
    'page.searchSuggestions.title'      = 'Search and suggestions'
    'page.shieldsProtection.intro'      = 'Brave''s built-in tracking protection. Most of it is already on; ticking locks it so nothing can weaken it later.'
    'page.shieldsProtection.title'      = 'Shields and tracking'
    'page.signinImport.intro'           = 'Account, sync and first-run import features. Mostly for people who want a strictly local browser.'
    'page.signinImport.title'           = 'Sign-in, sync and import'
    'page.uiBloatExtras.intro'          = 'Small interface features you can remove.'
    'page.uiBloatExtras.title'          = 'Interface clutter'
    'page.updater.intro'                = 'Advanced. Only for people who update Brave by hand. Presets never change this page.'
    'page.updater.title'                = 'Updater tasks and services'
    'page.webServicesBackground.intro'  = 'What Brave does in the background and on the network.'
    'page.webServicesBackground.title'  = 'Network and background'
}

# ---- Lists: columns, risk, status, tooltips -----------------------------------
Add-Strings @{
    'grid.col.policy'  = 'Policy'
    'grid.col.name'   = 'Name'
    'grid.col.domains' = 'Domains'
    'grid.col.risk'    = 'Risk'
    'grid.col.setting' = 'Setting'
    'grid.col.status'  = 'Status'
    'grid.col.value'   = 'Value'
    'grid.col.what'    = 'What changes'
    'risk.high'        = 'High'
    'risk.low'         = 'Low'
    'risk.medium'      = 'Medium'
    'risk.safe'        = 'Safe'
    'state.active'     = 'Active'
    'state.blocked'    = 'Blocked'
    'state.disabled'   = 'Disabled'
    'state.enabled'    = 'Enabled'
    'state.missing'    = 'Not installed'
    'state.notBlocked' = 'Not blocked'
    'state.notSet'     = 'Not set'
    'state.unknown'    = 'Not read yet'
    'state.willApply'  = 'Will apply'
    'state.willBlock'  = 'Will block'
    'state.willChange' = 'Will change'
    'state.willDisable' = 'Will disable'
    'state.willEnable' = 'Will enable'
    'state.willRemove' = 'Will remove'
    'state.willUnblock' = 'Will unblock'
    'tip.domains'      = 'Domains: {0}'
    'tip.hosts'        = 'Ticked groups are added to the Windows hosts file when you press Apply hosts blocks on this page. Unticked groups are removed.'
    'tip.lock'         = 'Brave already behaves this way by default. Ticking only makes it mandatory, so nothing can change it later.'
    'tip.pattern'      = 'Task name pattern: {0}'
    'tip.policy'       = 'Policy: {0} = {1}  ({2})'
    'tip.risk'         = 'Risk: {0}'
    'tip.service'      = 'Windows service: {0}'
    'tip.status'       = 'Active: already applied. Will apply / change / remove: waiting for you to press Apply. Not set: Brave decides.'
    'tip.ticked.Off'   = 'When ticked: this feature is switched off.'
    'tip.ticked.On'    = 'When ticked: this protection is kept on and locked.'
    'tip.ticked.Set'   = 'When ticked: this value is enforced and locked.'
    'tip.unticked'     = 'When unticked: Brave decides again (this tool removes its policy when you press Apply).'
    'tip.updater'      = 'Turning this off stops Brave from updating itself. Only do it if you update Brave by hand.'
}

# ---- Filter --------------------------------------------------------------------
Add-Strings @{
    'filter.clear'        = 'Clear the search'
    'filter.matches'      = '{0} of {1} settings shown'
    'filter.noMatches'    = 'No settings match this search.'
    'filter.placeholder'  = 'Search settings...'
    'filter.help'        = 'Search every setting: a name, a word from its description, a policy name...'
    'filter.selectedOnly' = 'Ticked only'
    'filter.technical'    = 'Show technical details'
    'policyTab.selectAll' = 'Tick all'
    'policyTab.selectNone' = 'Untick all'
}

# ---- Action bar, tools, status -----------------------------------------------------
Add-Strings @{
    'action.apply'       = 'Apply to Brave'
    'action.backup'      = 'Back up first'
    'action.fullRestore' = 'Restore stock...'
    'action.preview'     = 'Preview changes'
    'bar.none'           = 'No changes pending'
    'bar.pending'        = '{0} pending:  {1} to apply,  {2} to change,  {3} to remove'
    'bar.problem'        = 'Check the Search engine and startup page'
    'status.hideLog'     = 'Hide log'
    'status.showLog'     = 'Show log'
    'tools.backups'      = 'Open backups folder'
    'tools.button'       = 'Tools  v'
    'tools.help'         = 'How this works...'
    'tools.load'         = 'Load current state'
    'tools.log'          = 'Show or hide the log'
    'util.close'         = 'Close'
    'util.export'        = 'Export config...'
    'util.import'        = 'Import config...'
    'util.openPolicy'    = 'Open brave://policy'
    'util.verify'        = 'Verify'
}

# ---- Updater page ---------------------------------------------------------------------
Add-Strings @{
    'log.updater.missing'              = 'That updater item is not installed on this PC, so there is nothing to change.'
    'log.updater.reading'              = 'Reading updater tasks and services...'
    'service.brave.description'                 = 'The main background service of Brave''s updater.'
    'service.brave.title'                       = 'Brave Update Service'
    'service.bravem.description'                = 'The on-demand helper of Brave''s updater.'
    'service.bravem.title'                      = 'Brave Update Service (on demand)'
    'task.core.description'                     = 'Brave''s updater wakes up on a schedule to look for a new version. Turning it off means no automatic updates.'
    'task.core.title'                           = 'Stop the updater''s scheduled check'
    'task.ua.description'                       = 'The scheduled task that actually checks for and downloads new Brave versions.'
    'task.ua.title'                             = 'Stop the updater''s version check'
    'updater.checkNow'                          = 'Check for updates now'
    'updater.rescan'                            = 'Re-scan'
    'updater.warning'                           = 'Turning these off stops Brave from updating itself, so it will no longer get security fixes unless you update it by hand (Brave menu > About Brave). Only do this if you know why. Presets never touch this page.'
}

# ---- Hosts blocklist -------------------------------------------------------------------
Add-Strings @{
    'hosts.components.description'   = 'The servers Brave''s Shields filter lists, extensions and Tor come from. Blocking them freezes ad blocking, Widevine and extension updates. Experts only - never needed for privacy.'
    'hosts.components.name'          = 'Component and extension updates'
    'hosts.news.description'         = 'The servers behind the News feed and its images. Block them only if News is switched off - it stops working if you turn it back on.'
    'hosts.news.name'                = 'Brave News servers'
    'hosts.p3a.description'          = 'The servers that receive Brave''s anonymous usage analytics (P3A). Pure telemetry, never needed by a feature.'
    'hosts.p3a.name'                 = 'Brave usage analytics (P3A)'
    'hosts.rewards.description'      = 'Servers for Brave Rewards. Block them only if you do not use Rewards - it stops working if you turn it back on.'
    'hosts.rewards.name'             = 'Brave Rewards servers'
    'hosts.stats.description'        = 'The server behind Brave''s anonymous daily usage ping. Pure telemetry.'
    'hosts.stats.name'               = 'Brave usage ping'
    'hosts.variations.description'   = 'The server that sends Brave remote experiments and kill switches. Matches the Max Privacy setting that turns experiments off.'
    'hosts.variations.name'          = 'Brave experiments (Variations)'
    'hosts.webDiscovery.description' = 'Servers for the Web Discovery Project. It is opt-in and off by default; blocking them is a safety net.'
    'hosts.webDiscovery.name'        = 'Web Discovery Project'
    'hostsTab.apply'                 = 'Apply hosts blocks'
    'hostsTab.load'                  = 'Load current state'
    'hostsTab.open'                  = 'Open hosts file'
    'hostsTab.preview'               = 'Preview hosts'
    'hostsTab.remove'                = 'Remove hosts block'
    'hostsTab.warn'                  = 'Independent of the Apply to Brave button: use the buttons below to write or remove the hosts block. Only the Brave Free Origin block is edited; a backup is saved first.'
}

# ---- Search engine, new tab and startup ---------------------------------------------------
Add-Strings @{
    'destination.blank'           = 'Blank page (about:blank)'
    'destination.braveSearchHome' = 'Brave Search homepage'
    'destination.custom'          = 'Custom URL...'
    'destination.duckduckgoHome'  = 'DuckDuckGo homepage'
    'destination.googleHome'      = 'Google homepage'
    'destination.matchSearch'     = 'Match the search engine I picked above'
    'destination.ntpDefault'      = 'Default new tab page (do not override)'
    'engine.bing'                 = 'Bing'
    'engine.brave'                = 'Brave Search'
    'engine.custom'               = 'Custom...'
    'engine.duckduckgo'           = 'DuckDuckGo'
    'engine.ecosia'               = 'Ecosia'
    'engine.google'               = 'Google'
    'engine.kagi'                 = 'Kagi (paid)'
    'engine.mojeek'               = 'Mojeek'
    'engine.qwant'                = 'Qwant'
    'engine.startpage'            = 'Startpage'
    'engine.yandex'               = 'Yandex'
    'err.ntp.badUrl'              = 'The New Tab address is not a valid web address. Use a full address such as https://example.com, or about:blank.'
    'err.ntp.empty'               = 'The New Tab override has no address. Pick a destination or type a custom URL.'
    'err.search.badUrl'           = 'The custom search address is not a valid web address. It should look like https://example.com/search?q={{searchTerms}}.'
    'err.search.empty'            = 'The custom search address is empty. Type an address that contains {{searchTerms}}.'
    'err.search.placeholder'      = 'The custom search address must contain {{searchTerms}} where the query goes.'
    'err.search.unknown'          = 'Pick a search engine first.'
    'err.startup.badUrl'          = 'The startup page "{0}" is not a valid web address.'
    'err.startup.empty'           = 'The startup override needs at least one page address.'
    'err.startup.unknown'         = 'Pick a startup behavior first.'
    'ext.bitwarden'               = 'Install Bitwarden (password manager)'
    'ext.intro'                   = 'Brave Shields is already a native ad and tracker blocker (same filter-list lineage as uBlock Origin, but built in, so slightly faster). Nothing is force-installed - that would show a "Managed by your organization" banner and lock the extension on. These buttons just open the install pages in Brave.'
    'ext.section'                 = 'Extensions and shortcuts (optional, manual install)'
    'ext.shields'                 = 'Open Brave Shields settings'
    'ext.uboLite'                 = 'Install uBlock Origin Lite (MV3)'
    'ext.warn'                    = 'Caution: uBlock Origin on top of Shields blocks the same things twice, wastes CPU per tab and can break sites Shields handles fine. If you add it, set Shields to Standard rather than Aggressive.'
    'searchTab.chkNtp'            = 'Override the New Tab page (writes the NewTabPageLocation policy)'
    'searchTab.chkSearch'         = 'Force this search engine (writes the DefaultSearchProvider* policies)'
    'searchTab.chkStartup'        = 'Override startup behavior (writes RestoreOnStartup and RestoreOnStartupURLs)'
    'searchTab.conflictNote'      = 'These choices win over the matching settings on the other pages (New Tab page, Home page and startup). Untick a box and press Apply to remove its override and hand control back to Brave.'
    'searchTab.customLabel'       = 'Custom URL:'
    'searchTab.engineLabel'       = 'Engine:'
    'searchTab.modeLabel'         = 'Mode:'
    'searchTab.ntpCustomLabel'    = 'Custom URL:'
    'searchTab.ntpOpenLabel'      = 'Open:'
    'searchTab.searchHelp'        = 'A custom address must contain {{searchTerms}} where the query goes. Example: https://my-searx/search?q={{searchTerms}}'
    'searchTab.secNtp'            = 'New Tab page'
    'searchTab.secSearch'         = 'Default search engine (address bar)'
    'searchTab.secStartup'        = 'On startup (what opens when you launch Brave)'
    'searchTab.startupHelp'       = 'For "specific page or set", separate several addresses with a comma. Each opens in its own tab.'
    'searchTab.urlLabel'          = 'URL(s):'
    'startupMode.blankPage'       = 'Open a blank page'
    'startupMode.newTab'          = 'Open the New Tab page'
    'startupMode.restoreSession'  = 'Restore my last session'
    'startupMode.specificPages'   = 'Open a specific page or set'
}


# ---- Policy titles and descriptions -----------------------------------------------
# Keyed on the registry value name, which is never translated. The title states
# the RESULT of ticking the box; the description says what the feature is and
# what changes. Rows marked "locks" in the table already match Brave's default:
# ticking them only makes the behaviour mandatory.

# -- Brave extras
Add-Strings @{
    'policy.BraveAIChatEnabled.description'   = 'Removes Leo, Brave''s built-in AI chat, from the sidebar, the address bar and the right-click menu.'
    'policy.BraveAIChatEnabled.title'         = 'Turn off Leo AI assistant'
    'policy.BraveNewsDisabled.description'    = 'Removes the news feed from the New Tab page and its related settings.'
    'policy.BraveNewsDisabled.title'          = 'Turn off Brave News'
    'policy.BravePlaylistEnabled.description' = 'Removes Playlist, which saves videos and audio from web pages so you can play them later or offline.'
    'policy.BravePlaylistEnabled.title'       = 'Turn off Playlist'
    'policy.BraveRewardsDisabled.description' = 'Removes Brave Rewards (BAT tokens for viewing ads), its ads, tips and buttons. It cannot be switched back on in Settings.'
    'policy.BraveRewardsDisabled.title'       = 'Turn off Brave Rewards'
    'policy.BraveSpeedreaderEnabled.description' = 'Removes the reading-mode button that turns cluttered articles into a clean view.'
    'policy.BraveSpeedreaderEnabled.title'    = 'Turn off Speedreader'
    'policy.BraveTalkDisabled.description'    = 'Removes the Brave Talk video-call button and its promotions from the browser.'
    'policy.BraveTalkDisabled.title'          = 'Turn off Brave Talk'
    'policy.BraveVPNDisabled.description'     = 'Removes the paid Brave VPN button, menu entries and upsell. Other VPNs are not affected.'
    'policy.BraveVPNDisabled.title'           = 'Turn off Brave VPN'
    'policy.BraveWalletDisabled.description'  = 'Removes the built-in crypto wallet (Ethereum, Solana, Bitcoin and more), its toolbar button and Web3 features such as .eth and .sol addresses.'
    'policy.BraveWalletDisabled.title'        = 'Turn off Brave Wallet'
    'policy.BraveWaybackMachineEnabled.description' = 'Stops Brave from offering an archived copy from the Internet Archive when a page is missing, and hides its icon and settings.'
    'policy.BraveWaybackMachineEnabled.title' = 'Turn off Wayback Machine prompts'
    'policy.EmailAliasesEnabled.description'  = 'Removes Email Aliases, the feature that creates disposable addresses for sign-ups, together with its buttons.'
    'policy.EmailAliasesEnabled.title'        = 'Turn off Email Aliases'
    'policy.PsstEnabled.description'          = 'Stops Brave from suggesting and adjusting site-specific privacy settings on its own.'
    'policy.PsstEnabled.title'                = 'Turn off Privacy Settings Tuning'
    'policy.TorDisabled.description'          = 'Removes "New Private Window with Tor". Tor inside Brave is weaker than the official Tor Browser, so you may not miss it.'
    'policy.TorDisabled.title'                = 'Turn off Tor private windows'
}

# -- Shields and tracking
Add-Strings @{
    'policy.BraveDeAmpEnabled.description'    = 'Opens the publisher''s real page instead of Google''s AMP copy, which limits tracking. Brave does this by default; ticking locks it on.'
    'policy.BraveDeAmpEnabled.title'          = 'Skip Google AMP pages'
    'policy.BraveDebouncingEnabled.description' = 'Sends you straight to your destination when a link goes through a known tracking redirect. On by default; ticking locks it on. Rarely, a redirect-based login can behave differently.'
    'policy.BraveDebouncingEnabled.title'     = 'Skip tracker redirects'
    'policy.BraveGlobalPrivacyControlEnabled.description' = 'Tells websites you do not want your data sold or shared (Global Privacy Control). On by default; ticking locks it on.'
    'policy.BraveGlobalPrivacyControlEnabled.title' = 'Always send "Do Not Sell" (GPC)'
    'policy.BraveReduceLanguageEnabled.description' = 'Limits what sites can learn from your language settings, which makes fingerprinting harder. On by default; ticking locks it on. A few multilingual sites may pick a default language.'
    'policy.BraveReduceLanguageEnabled.title' = 'Hide language details from sites'
    'policy.BraveTrackingQueryParametersFilteringEnabled.description' = 'Removes known tracking codes (such as fbclid) from links when Shields is on. On by default; ticking locks it on. Rarely, a link that needs such a code stops working.'
    'policy.BraveTrackingQueryParametersFilteringEnabled.title' = 'Strip tracking codes from links'
    'policy.DefaultBraveAdblockSetting.description' = 'Sets Shields'' default to "Block ads and trackers" and stops the global default being changed to "Allow". Brave already blocks by default; ticking locks it.'
    'policy.DefaultBraveAdblockSetting.title' = 'Keep ad blocking on'
    'policy.DefaultBraveFingerprintingV2Setting.description' = 'Locks fingerprinting protection to Standard, which makes it harder for sites to recognise your browser by its unique traits. Brave''s default; a few captchas and web apps may misbehave.'
    'policy.DefaultBraveFingerprintingV2Setting.title' = 'Keep fingerprint protection on'
    'policy.DefaultBraveHttpsUpgradeSetting.description' = 'Upgrades every link to HTTPS and shows a warning page instead of opening a site that has no HTTPS. Old routers, NAS boxes and local http:// pages need extra clicks or will not open.'
    'policy.DefaultBraveHttpsUpgradeSetting.title' = 'Require HTTPS (Strict)'
    'policy.DefaultBraveReferrersSetting.description' = 'Limits the "Referer" header to your site''s origin for cross-site requests, so other sites do not see the full address you came from. Brave does this by default; ticking locks it.'
    'policy.DefaultBraveReferrersSetting.title' = 'Limit the referrer sent to sites'
    'policy.DefaultBraveRemember1PStorageSetting.description' = 'Deletes a site''s cookies and storage when you close its tab, so you are signed out of sites all the time and lose saved site settings. Brave normally keeps them.'
    'policy.DefaultBraveRemember1PStorageSetting.title' = 'Forget site data when a tab closes'
}

# -- Telemetry and reports
Add-Strings @{
    'policy.BraveP3AEnabled.description'      = 'P3A sends anonymous, privacy-preserving answers about how Brave features are used. Ticking turns it off and it cannot be switched back on in Settings.'
    'policy.BraveP3AEnabled.title'            = 'Turn off usage analytics (P3A)'
    'policy.BraveStatsPingEnabled.description' = 'Stops the small daily ping that lets Brave count active users.'
    'policy.BraveStatsPingEnabled.title'      = 'Turn off the usage ping'
    'policy.BraveWebDiscoveryEnabled.description' = 'The Web Discovery Project anonymously shares data to help build Brave Search. It is opt-in and off by default; ticking makes sure it stays off.'
    'policy.BraveWebDiscoveryEnabled.title'   = 'Keep Web Discovery off'
    'policy.ChromeVariations.description'     = 'Variations let Brave switch features on or off remotely (experiments, staged rollouts, kill switches). Ticking blocks all of them, so you only get built-in defaults - which can delay remote fixes.'
    'policy.ChromeVariations.title'           = 'Turn off remote experiments'
    'policy.MetricsReportingEnabled.description' = 'Stops Chromium''s usage statistics and crash reports from being sent. Brave then gets no crash data from you, which can slow down bug fixes.'
    'policy.MetricsReportingEnabled.title'    = 'Turn off crash and usage reports'
    'policy.UrlKeyedAnonymizedDataCollectionEnabled.description' = 'Prevents the addresses of pages you visit from being sent to Google to "make searches and browsing better". It is opt-in; ticking makes sure it cannot be enabled.'
    'policy.UrlKeyedAnonymizedDataCollectionEnabled.title' = 'Stop "make searches better" sharing'
    'policy.UserFeedbackAllowed.description'  = 'Removes the "Send feedback" option that can attach diagnostics to a report.'
    'policy.UserFeedbackAllowed.title'        = 'Turn off "Send feedback"'
    'policy.WebRtcEventLogCollectionAllowed.description' = 'Stops services such as Google Meet from collecting WebRTC diagnostic logs from your browser. Brave already blocks this; ticking locks it.'
    'policy.WebRtcEventLogCollectionAllowed.title' = 'Block WebRTC log uploads'
}

# -- Passwords and autofill
Add-Strings @{
    'policy.AutofillAddressEnabled.description' = 'Brave stops suggesting, saving and filling addresses and contact details. Entries you already saved are kept but no longer offered.'
    'policy.AutofillAddressEnabled.title'     = 'Turn off address autofill'
    'policy.AutofillCreditCardEnabled.description' = 'Brave stops suggesting, saving and filling payment cards, so you type card numbers by hand.'
    'policy.AutofillCreditCardEnabled.title'  = 'Turn off card autofill'
    'policy.PasswordLeakDetectionEnabled.description' = 'Stops the breach check that sends a hashed copy of credentials to a Google service. Brave already has it off; ticking locks it off.'
    'policy.PasswordLeakDetectionEnabled.title' = 'Turn off password leak checks'
    'policy.PasswordManagerEnabled.description' = 'Brave stops asking to save new passwords. Passwords you already saved still fill in. You will need another password manager for new logins.'
    'policy.PasswordManagerEnabled.title'     = 'Stop offering to save passwords'
    'policy.PaymentMethodQueryEnabled.description' = 'Stops websites from checking (through the Payment Request API) whether you have a saved payment method. Some checkouts lose their one-click card option.'
    'policy.PaymentMethodQueryEnabled.title'  = 'Hide saved cards from websites'
}

# -- Search and suggestions
Add-Strings @{
    'policy.AlternateErrorPagesEnabled.description' = 'Stops asking a web service for suggestions when a page cannot be found. Brave already has this off; ticking locks it.'
    'policy.AlternateErrorPagesEnabled.title' = 'Turn off error-page suggestions'
    'policy.SearchSuggestEnabled.description' = 'Stops the address bar from sending what you type to your search engine to fetch suggestions. Brave already has this off; ticking locks it. History and bookmark suggestions still work.'
    'policy.SearchSuggestEnabled.title'       = 'Turn off search suggestions'
    'policy.SpellCheckServiceEnabled.description' = 'Stops sending the text you type to a Google web service for smarter spell checking. Local spell checking keeps working.'
    'policy.SpellCheckServiceEnabled.title'   = 'Turn off cloud spellcheck'
    'policy.SpellcheckEnabled.description'    = 'Disables all spell checking, local and cloud. No red underlines or suggestions anywhere, and it cannot be turned back on in Settings.'
    'policy.SpellcheckEnabled.title'          = 'Turn off spellcheck completely'
    'policy.TranslateEnabled.description'     = 'Removes Brave''s built-in "Translate this page" offer. Pages in other languages stay untranslated.'
    'policy.TranslateEnabled.title'           = 'Turn off page translation'
}

# -- Safety and prompts
Add-Strings @{
    'policy.ComponentUpdatesEnabled.description' = 'Stops Brave from updating its internal components (such as Widevine, and probably ad-block filter lists) between browser releases. Streaming and blocking data can go stale or break. Experts only.'
    'policy.ComponentUpdatesEnabled.title'    = 'Stop background component updates'
    'policy.DefaultBrowserSettingEnabled.description' = 'Stops Brave from checking whether it is your default browser and asking you to change it. Set your default in Windows Settings instead.'
    'policy.DefaultBrowserSettingEnabled.title' = 'Stop "make Brave default" prompts'
    'policy.PromotionsEnabled.description'    = 'Stops Brave from opening full-tab promotional content and welcome pages.'
    'policy.PromotionsEnabled.title'          = 'Hide promo and welcome tabs'
    'policy.SafeBrowsingDeepScanningEnabled.description' = 'Stops suspicious downloads from being uploaded to Google for a malware scan. Brave already has this off; ticking locks it.'
    'policy.SafeBrowsingDeepScanningEnabled.title' = 'Block download deep-scan uploads'
    'policy.SafeBrowsingExtendedReportingEnabled.description' = 'Stops sending system information and page content to Google when a threat is detected. Brave already has this off; ticking locks it.'
    'policy.SafeBrowsingExtendedReportingEnabled.title' = 'Never send extra Safe Browsing reports'
    'policy.SafeBrowsingProtectionLevel.description' = 'Keeps Safe Browsing (dangerous-site and download warnings) on Standard and blocks "Enhanced" (shares more data with Google) and "Off".'
    'policy.SafeBrowsingProtectionLevel.title' = 'Keep Safe Browsing on Standard'
    'policy.SafeBrowsingSurveysEnabled.description' = 'Prevents Safe Browsing satisfaction surveys from appearing.'
    'policy.SafeBrowsingSurveysEnabled.title' = 'Stop Safe Browsing surveys'
}

# -- AI features
Add-Strings @{
    'policy.AIModeSettings.description'       = 'Blocks Google''s AI Mode shortcuts in the address bar and New Tab search box. Only relevant when Google is your search engine.'
    'policy.AIModeSettings.title'             = 'Turn off Google AI Mode shortcuts'
    'policy.AutofillPredictionSettings.description' = 'Stops Chromium from using generative AI to understand forms and fill more fields.'
    'policy.AutofillPredictionSettings.title' = 'Turn off AI-enhanced autofill'
    'policy.BraveLocalAIEnabled.description'  = 'Hides Brave''s on-device AI features (such as history embeddings) and stops the AI model component from being installed.'
    'policy.BraveLocalAIEnabled.title'        = 'Turn off Brave''s on-device AI'
    'policy.CreateThemesSettings.description' = 'Blocks the feature that generates custom themes and wallpapers with AI.'
    'policy.CreateThemesSettings.title'       = 'Turn off AI-generated themes'
    'policy.DevToolsGenAiSettings.description' = 'DevTools'' Console Insights and AI assistance send errors, code and network details to a Google AI model. Ticking turns them off; developers lose the AI hints.'
    'policy.DevToolsGenAiSettings.title'      = 'Turn off AI helpers in DevTools'
    'policy.GenAILocalFoundationalModelSettings.description' = 'Stops Chromium''s large on-device AI model from being downloaded, and deletes it if it is already there.'
    'policy.GenAILocalFoundationalModelSettings.title' = 'Do not download the on-device AI model'
    'policy.GeminiSettings.description'       = 'Blocks the Gemini app integration in the browser.'
    'policy.GeminiSettings.title'             = 'Turn off Gemini integration'
    'policy.HelpMeWriteSettings.description'  = 'Blocks "Help me write", Google''s AI writing helper for text boxes on the web.'
    'policy.HelpMeWriteSettings.title'        = 'Turn off "Help me write"'
    'policy.HistorySearchSettings.description' = 'Blocks Google''s AI history search, which answers questions using the content of pages in your history.'
    'policy.HistorySearchSettings.title'      = 'Turn off AI history search'
    'policy.SearchContentSharingSettings.description' = 'Stops the browser from sharing page or file content with Google AI Mode and Lens. This one policy replaces the older Lens policies.'
    'policy.SearchContentSharingSettings.title' = 'Stop sharing page content with Google AI'
    'policy.TabCompareSettings.description'   = 'Blocks the AI tool that compares information across your open tabs.'
    'policy.TabCompareSettings.title'         = 'Turn off AI tab comparison'
    'policy.ThirdPartyAiChatSettings.description' = 'Blocks AI chat shortcuts from third-party search engines in the address bar and New Tab search box.'
    'policy.ThirdPartyAiChatSettings.title'   = 'Turn off third-party AI chat shortcuts'
}

# -- Sign-in, sync and import
Add-Strings @{
    'policy.BrowserSignin.description'        = 'Prevents signing in to the browser with an account. Brave has no Google-account sign-in, so this is mostly a safety lock.'
    'policy.BrowserSignin.title'              = 'Block browser sign-in'
    'policy.ImportAutofillFormData.description' = 'Stops form-autofill data from being imported from your previous browser on first run; the import box starts unticked.'
    'policy.ImportAutofillFormData.title'     = 'Do not import form data'
    'policy.ImportBookmarks.description'      = 'Stops bookmarks from being imported from your previous browser on first run; the import box starts unticked.'
    'policy.ImportBookmarks.title'            = 'Do not import bookmarks'
    'policy.ImportHistory.description'        = 'Stops browsing history from being imported from your previous browser on first run; the import box starts unticked.'
    'policy.ImportHistory.title'              = 'Do not import history'
    'policy.ImportSavedPasswords.description' = 'Blocks importing saved passwords from another browser, on first run and also manually from Settings.'
    'policy.ImportSavedPasswords.title'       = 'Block importing saved passwords'
    'policy.ImportSearchEngine.description'   = 'Stops the search engine from being imported from your previous browser on first run; the import box starts unticked.'
    'policy.ImportSearchEngine.title'         = 'Do not import search engines'
    'policy.SyncDisabled.description'         = 'Turns off syncing of bookmarks, passwords, history and settings between your devices, and it cannot be turned back on in Settings.'
    'policy.SyncDisabled.title'               = 'Turn off Brave Sync'
}

# -- Network and background
Add-Strings @{
    'policy.BackgroundModeEnabled.description' = 'Stops Brave from staying alive in the system tray after you close the last window, which would keep extensions and notifications running.'
    'policy.BackgroundModeEnabled.title'      = 'Do not run Brave in the background'
    'policy.BuiltInDnsClientEnabled.description' = 'Makes Brave ask Windows for DNS lookups instead of using its own DNS client. The built-in client is still used when secure DNS is on.'
    'policy.BuiltInDnsClientEnabled.title'    = 'Use Windows for DNS lookups'
    'policy.DnsOverHttpsMode.description'     = 'Encrypts DNS lookups (DNS-over-HTTPS) when your provider supports it, and falls back to normal DNS if not. You cannot switch it off or pick a custom provider.'
    'policy.DnsOverHttpsMode.title'           = 'Use secure DNS when available'
    'policy.EnableMediaRouter.description'    = 'Removes Google Cast (sending tabs to TVs and speakers) and stops Brave scanning your network for Cast devices.'
    'policy.EnableMediaRouter.title'          = 'Turn off Google Cast'
    'policy.NetworkPredictionOptions.description' = 'Stops DNS prefetching, pre-connecting and pre-rendering of pages the browser guesses you will open. Brave already has this off; ticking locks it. Some pages may load slightly slower.'
    'policy.NetworkPredictionOptions.title'   = 'Turn off page preloading'
    'policy.QuicAllowed.description'          = 'Allows QUIC, the faster HTTP/3 web protocol. It is allowed by default, so ticking only locks it on. A few corporate firewalls block QUIC.'
    'policy.QuicAllowed.title'                = 'Always allow QUIC (HTTP/3)'
}

# -- Performance and startup
Add-Strings @{
    'policy.BatterySaverModeAvailability.description' = 'Reduces animations and background work when a laptop is unplugged and the battery is low. Users cannot turn Battery Saver off.'
    'policy.BatterySaverModeAvailability.title' = 'Use Battery Saver on low battery'
    'policy.BrowserLabsEnabled.description'   = 'Hides the Labs (experiments) button from the toolbar. Brave already does not show it; ticking locks it.'
    'policy.BrowserLabsEnabled.title'         = 'Hide the Labs button'
    'policy.DiskCacheSize.description'        = 'Caps how much disk space the page cache may use (250 MB). The limit is a hint, not exact, and heavy browsing re-downloads more files.'
    'policy.DiskCacheSize.title'              = 'Limit the disk cache to 250 MB'
    'policy.HardwareAccelerationModeEnabled.choice.disable' = 'Off'
    'policy.HardwareAccelerationModeEnabled.choice.enable'  = 'On'
    'policy.HardwareAccelerationModeEnabled.description' = 'Lets Brave use your graphics card to draw pages and decode video. On is Brave''s default. Pick Off only to work around GPU driver glitches, artifacts or crashes - video and scrolling get slower.'
    'policy.HardwareAccelerationModeEnabled.title' = 'Set GPU hardware acceleration'
    'policy.HighEfficiencyModeEnabled.description' = 'Puts tabs you have not used for a while to sleep so their memory can be reused. They reload when you return to them.'
    'policy.HighEfficiencyModeEnabled.title'  = 'Turn on Memory Saver'
    'policy.HomepageIsNewTabPage.description' = 'Separates the Home page from the New Tab page, so the Home button opens its own address. Only matters when the Home button is shown.'
    'policy.HomepageIsNewTabPage.title'       = 'Home page is not the New Tab page'
    'policy.HomepageLocation.description'     = 'Makes the Home button open a blank page and stops it being changed.'
    'policy.HomepageLocation.title'           = 'Set the Home page to blank'
    'policy.NTPCustomBackgroundEnabled.description' = 'Users can no longer set their own New Tab background, and a custom background already set is permanently deleted - removing this policy later does not bring it back.'
    'policy.NTPCustomBackgroundEnabled.title' = 'Block custom New Tab backgrounds'
    'policy.NewTabPageLocation.description'   = 'Every new tab opens an empty page instead of Brave''s New Tab page (top sites, background, News). No favorites or search box on new tabs.'
    'policy.NewTabPageLocation.title'         = 'Make new tabs blank'
    'policy.RestoreOnStartup.description'     = 'Brave normally continues where you left off. Ticking makes it always open the New Tab page instead, and you lose your tabs after a restart or crash.'
    'policy.RestoreOnStartup.title'           = 'Start on the New Tab page'
    'policy.ShowHomeButton.description'       = 'Removes the Home button from the toolbar. Brave hides it by default; ticking locks it hidden.'
    'policy.ShowHomeButton.title'             = 'Hide the Home button'
}

# -- Interface clutter
Add-Strings @{
    'policy.AccessibilityImageLabelsEnabled.description' = 'For screen-reader users: stops unlabeled images from being sent to a Google service to get automatic descriptions. Screen-reader users lose those descriptions.'
    'policy.AccessibilityImageLabelsEnabled.title' = 'Turn off Google image descriptions'
    'policy.AutoplayAllowed.description'      = 'Stops videos and audio from starting on their own. Sites need a click to play, so some previews and players wait for you.'
    'policy.AutoplayAllowed.title'            = 'Block media autoplay'
    'policy.BookmarkBarEnabled.description'   = 'Hides the bookmarks bar under the address bar, and it cannot be shown again in Settings.'
    'policy.BookmarkBarEnabled.title'         = 'Hide the bookmarks bar'
    'policy.LiveCaptionEnabled.description'   = 'Turns off Live Caption, which creates on-device captions for audio and video and needs a speech-model download. Deaf and hard-of-hearing users lose automatic captions.'
    'policy.LiveCaptionEnabled.title'         = 'Turn off Live Caption'
    'policy.PromptForDownloadLocation.description' = 'Downloads start at once into your Downloads folder instead of asking where to save each file. Unwanted downloads are less obvious.'
    'policy.PromptForDownloadLocation.title'  = 'Save downloads without asking'
}

# ---- Scriptlet manager -------------------------------------------------------
Add-Strings @{
    'scriptlet.advancedMode'    = 'Advanced edit mode (allow list.txt modifications)'
    'scriptlet.affectDupes'     = 'Affect duplicate raw rules in the same file'
    'scriptlet.autoPath'        = 'Auto path'
    'scriptlet.backupAll'       = 'Backup all lists'
    'scriptlet.browse'          = 'Browse...'
    'scriptlet.checkFiltered'   = 'Check filtered'
    'scriptlet.clearChecks'     = 'Clear checks'
    'scriptlet.col.arguments'   = 'Arguments'
    'scriptlet.col.domain'      = 'Domain'
    'scriptlet.col.line'        = 'Line'
    'scriptlet.col.pick'        = 'Pick / status'
    'scriptlet.col.rawRule'     = 'Raw rule'
    'scriptlet.col.scriptlet'   = 'Scriptlet'
    'scriptlet.col.source'      = 'Source / version'
    'scriptlet.disableChecked'  = 'Disable checked'
    'scriptlet.disabledOnly'    = 'Show disabled by this app only'
    'scriptlet.enableChecked'   = 'Enable checked'
    'scriptlet.exportCsv'       = 'Export visible CSV'
    'scriptlet.exportPrefs'     = 'Export disabled prefs'
    'scriptlet.filter'          = 'Filter'
    'scriptlet.importPrefs'     = 'Import + reapply prefs'
    'scriptlet.openFolder'      = 'Open folder'
    'scriptlet.restoreAll'      = 'Restore all backups'
    'scriptlet.restoreSelected' = 'Restore selected file'
    'scriptlet.risk'            = 'Risk: disabling scriptlets can break adblocking, anti-annoyance fixes, cookie banners, video sites, or site compatibility. Brave updates may replace component versions; export disabled preferences and reapply after updates if needed.'
    'scriptlet.rootLabel'       = 'Brave User Data folder:'
    'scriptlet.renderDone'      = ' Render completed in {0}s.'
    'scriptlet.scan'            = 'Scan'
    'scriptlet.scanDone'        = ' Scan completed in {0}s.'
    'scriptlet.searchLabel'     = 'Search/filter:'
    'scriptlet.state.disabled'  = 'Disabled'
    'scriptlet.state.enabled'   = 'Enabled'
    'scriptlet.statusFinding'   = 'Finding Brave scriptlet list files...'
    'scriptlet.statusFound'     = 'Found {0} list file(s). Scanning in chunks...'
    'scriptlet.statusIdle'      = 'Scan a Brave User Data folder to list internal scriptlet rules.'
    'scriptlet.statusRender0'   = 'Rendering 0 / {0} visible scriptlet row(s)...'
    'scriptlet.statusRenderN'   = 'Rendering {0} scriptlet row(s)...'
    'scriptlet.statusRendering' = 'Rendering {0} / {1} visible scriptlet row(s)... {2}s'
    'scriptlet.statusScanning'  = 'Scanning file {0} / {1}: {2}. Found {3} rule(s). {4}%. {5}s'
    'scriptlet.statusShowing'   = 'Showing {0} / {1}. Enabled: {2}. Disabled: {3}. Checked: {4}.'
    'scriptlet.statusStarting'  = 'starting...'
    'scriptlet.tipAffectDupes'  = 'Brave lists can contain the same scriptlet rule multiple times. Leave this on unless you only want the exact selected line.'
    'scriptlet.tipCheckFiltered' = 'Checks every row matching the active search/show filters, including rows not currently painted in the table.'
    'scriptlet.viewSelected'    = 'View selected'
}


# ---- Added in 1.13: site permissions, a few extra policies, corrected hosts groups ----
Add-Strings @{
    'page.sitePermissions.intro'   = 'Decide for every site at once instead of being asked. Ticking blocks the permission by default; sites that need it stop working.'
    'page.sitePermissions.title'   = 'Site permissions'
    'policy.BlockExternalExtensions.description' = 'Stops other programs on this PC from adding browser extensions to Brave behind your back (through the registry or extension files). Apps that bundle a companion extension can no longer install it on their own - add it from the store instead.'
    'policy.BlockExternalExtensions.title' = 'Block extensions added by other programs'
    'policy.DNSInterceptionChecksEnabled.description' = 'Brave normally sends a few test DNS lookups at startup and when your network changes, to spot ISPs that redirect unknown names. Ticking skips them. On such networks, a single word typed in the address bar may act oddly.'
    'policy.DNSInterceptionChecksEnabled.title' = 'Skip the DNS hijack test at startup'
    'policy.DefaultIdleDetectionSetting.description' = 'Sites can ask to know when you step away from the computer. Ticking answers "no" for every site without asking. Chat and team apps can no longer show an automatic "away" status.'
    'policy.DefaultIdleDetectionSetting.title' = 'Block sites from seeing when you are idle'
    'policy.DefaultLocalFontsSetting.description' = 'Your installed fonts are a fingerprinting signal. Ticking stops sites from asking to see them. Online design tools cannot use your installed fonts.'
    'policy.DefaultLocalFontsSetting.title' = 'Block sites from listing your fonts'
    'policy.DefaultSensorsSetting.description' = 'Sites can read device motion, orientation and light sensors, which helps them fingerprint you. Ticking denies that by default. Some maps, 360 viewers and web games that react to tilt stop responding to motion.'
    'policy.DefaultSensorsSetting.title' = 'Block sites from reading motion sensors'
    'policy.DefaultSerialGuardSetting.description' = 'Websites can normally ask to open serial (COM) ports, for 3D printers or microcontrollers. Ticking answers "no" without asking. Web serial consoles and hardware flashers stop working.'
    'policy.DefaultSerialGuardSetting.title' = 'Block sites from using serial ports'
    'policy.DefaultWebBluetoothGuardSetting.description' = 'Websites can normally ask to connect to nearby Bluetooth gadgets. Ticking answers "no" without asking. Web tools for Bluetooth hardware stop working; regular Windows Bluetooth (headphones, mice) is not affected.'
    'policy.DefaultWebBluetoothGuardSetting.title' = 'Block sites from using Bluetooth devices'
    'policy.DefaultWebHidGuardSetting.description' = 'Websites can normally ask to talk to game controllers, keyboards and macro pads directly. Ticking answers "no" without asking. Web configurators for such devices stop working.'
    'policy.DefaultWebHidGuardSetting.title' = 'Block sites from using HID input devices'
    'policy.DefaultWebUsbGuardSetting.description' = 'Websites can normally ask to talk to USB gadgets. Ticking answers "no" without asking. Web tools that flash or configure USB hardware stop working.'
    'policy.DefaultWebUsbGuardSetting.title' = 'Block sites from using USB devices'
    'policy.DefaultWindowManagementSetting.description' = 'Sites can ask about your screens and place windows across them. Ticking answers "no" without asking. Presentation and multi-monitor web apps lose that ability.'
    'policy.DefaultWindowManagementSetting.title' = 'Block sites from seeing your monitors'
    'policy.DesktopSharingHubEnabled.description' = 'Removes the Share menu from the address bar and the page right-click menu.'
    'policy.DesktopSharingHubEnabled.title'   = 'Remove the Share button'
    'policy.QRCodeGeneratorEnabled.description' = 'Removes "Create QR code for this page" from the address bar and the right-click menu.'
    'policy.QRCodeGeneratorEnabled.title'     = 'Remove "Create QR code"'
    'policy.WebRtcIPHandling.description'     = 'Websites can normally learn your device''s local network address through WebRTC. Ticking limits WebRTC to your public address only, which some video-call and peer-to-peer sites do not like.'
    'policy.WebRtcIPHandling.title'           = 'Hide your local network address (WebRTC)'
    'hosts.ads.description'          = 'Servers for Brave Ads. Block them only if Rewards is switched off - Ads stop working if you turn Rewards back on.'
    'hosts.ads.name'                 = 'Brave Ads servers'
    'hosts.crash.description'        = 'The server that receives Brave crash reports. Reports are only sent if you agreed to them; blocking it is a safety net.'
    'hosts.crash.name'               = 'Brave crash reports'
}


# ---- Reports (bodies stay English on purpose - they get pasted into bug reports) --
Add-Strings @{
    'report.close'          = 'Close'
    'report.copy'           = 'Copy'
    'report.hostsTitle'     = 'Hosts preview'
    'report.previewTitle'   = 'Preview apply changes'
    'report.save'           = 'Save report'
    'report.scriptletTitle' = 'Scriptlet details'
    'report.verifyTitle'    = 'Verify - registry vs selections'
}

# ---- File dialogs ------------------------------------------------------------
# Only the human-readable half of a filter is translatable. The *.txt / *.json
# glob is concatenated in code, so a translation can never produce a filter
# string that Windows refuses to parse.
Add-Strings @{
    'dialog.browseUserData'        = 'Select Brave User Data folder'
    'dialog.filter.config'         = 'JSON config'
    'dialog.filter.csv'            = 'CSV'
    'dialog.filter.scriptletPrefs' = 'Scriptlet preferences'
    'dialog.filter.textReport'     = 'Text report'
}

# ---- Help --------------------------------------------------------------------
Add-Strings @{
    'help.compat.body'    = "This list of settings was checked against Brave {0} (Chromium {1}) on {2}. Brave changes its policies over time, so on a newer Brave a few settings may be renamed or gone, and on an older one some may not exist yet. Brave simply ignores policies it does not know, so nothing breaks - open brave://policy to see which ones your version accepts.`r`n`r`nYour Brave: {3}. Everything this app does is reversible."
    'help.compat.title'   = 'Brave versions'
    'help.footer'         = 'Brave Free Origin v{0}  -  {1}  -  log file: {2}'
    'help.managed.body'   = "Brave shows this whenever any machine policy is active. It is a Chromium transparency feature and cannot be hidden safely. It disappears when you remove the policies (Stock / None, then Apply, or Restore stock)."
    'help.managed.title'  = 'The "Managed by your organization" note'
    'help.openLog'        = 'Open the log file'
    'help.reportIssue'    = 'Report a problem'
    'help.status.body'    = "Active: already applied.`r`nWill apply, Will change, Will remove: waiting for you to press Apply.`r`nNot set: Brave decides.`r`n`r`nRisk says what you could lose. Safe and Low are fine for everyone; Medium and High change how Brave behaves, so read the description first. Rows marked as locks only make Brave's own default mandatory."
    'help.status.title'   = 'What the Status and Risk columns mean'
    'help.tick.body'      = "Tick a setting to make this app enforce it. Untick it to hand control back to Brave: the policy is removed when you press Apply. Nothing is written until you press Apply, and Preview changes shows exactly what would happen first."
    'help.tick.title'     = 'Ticking a setting'
    'help.title'          = 'How Brave Free Origin works'
    'help.undo.body'      = "Pick Stock / None and press Apply, or use Restore stock. A backup of your policies is saved to:`r`n{0}`r`nbefore every Apply. Restore stock also removes the hosts block and turns the updater tasks and services back on if they were disabled."
    'help.undo.title'     = 'Undoing everything'
    'help.what.body'      = "Brave Free Origin switches off Brave features you do not want. It uses Brave's official group policies - the same mechanism companies use to manage browsers - written to the Windows registry. It never modifies Brave's program files (only the optional expert Scriptlets page edits filter-list files, and only when you ask, with a backup), and it works for every Brave channel installed on this PC."
    'help.what.title'     = 'What this app does'
    'header.alsoInstalled' = 'Also installed: {0}'
    'header.policiesShared' = 'Policies apply to every Brave channel on this PC (Stable, Beta, Nightly and Dev share one policy location).'
}

# ---- Result and follow-up dialogs ---------------------------------------------
Add-Strings @{
    'result.backup'    = 'Backup saved: {0}'
    'result.counts'    = 'Added {0}, changed {1}, removed {2}, already correct {3}.'
    'result.done'      = 'Changes applied'
    'result.failures'  = '{0} change(s) could not be made:'
    'result.partial'   = 'Applied with problems'
    'result.restart'   = 'Fully close and reopen Brave for the changes to take effect. Then open brave://policy or press Verify to check.'
    'result.system'    = '{0} updater change(s) made.'
    'result.verify'    = 'Verify'
}

# ---- Dialogs -----------------------------------------------------------------
Add-Strings @{
    'msg.apply.nothing'               = 'There is nothing to change. Tick or untick settings first, or pick a preset.'
    'msg.backup.failed'               = "The policy backup could not be saved:`r`n{0}`r`n`r`nApply anyway?"
    'msg.braveMissing'                = 'Brave was not found on this PC.'
    'msg.config.badJson'              = 'That file is not a valid config: {0}'
    'msg.config.imported'             = "Config loaded into the pages.`r`nPress 'Apply to Brave' (and Apply hosts blocks on the Hosts page if needed) to commit."
    'msg.error.body'                  = "{0} did not work.`r`n`r`n{1}`r`n`r`nDetails were saved to:`r`n{2}"
    'msg.failed'                      = 'Failed: {0}'
    'msg.hosts.applied'               = "Hosts file updated. {0} domain(s) blocked.`r`nDNS cache flushed."
    'msg.hosts.confirmApply'          = "About to add {0} entries to:`r`n{1}`r`n`r`nA timestamped backup will be saved first. Continue?"
    'msg.hosts.confirmRemove'         = "Remove the Brave-Free-Origin block from the hosts file?`r`n(Your other hosts entries are not touched.)"
    'msg.hosts.noGroups'              = 'No groups are ticked. This will remove the existing hosts block (if any). Continue?'
    'msg.hosts.removed'               = 'Hosts block removed.'
    'msg.language.switched'           = 'Language switched to {0}.'
    'msg.openBrave.copied'            = "Brave could not be started from here.`r`n`r`nThe address was copied to the clipboard:`r`n{0}`r`n`r`nPaste it into Brave's address bar."
    'msg.restore.confirm'             = "This restores stock Brave.`r`n`r`nIt removes the policies this tool set, clears the Brave-Free-Origin hosts block and turns Brave's updater tasks and services back on if they are disabled.`r`n`r`nContinue?"
    'msg.restore.confirmForeign'      = "This restores stock Brave.`r`n`r`nBrave's policy key also holds {0} other value(s) this tool did not create, for example: {1}.`r`n`r`nYes: remove only this tool's settings (recommended)`r`nNo: remove everything, including those {0}`r`nCancel: do nothing"
    'msg.restore.done'                = 'Stock Brave restored. Restart Brave to see stock behavior.'
    'msg.restore.partial'             = '{0} step(s) could not be completed:'
    'msg.title.app'                   = 'Brave Free Origin'
    'msg.title.done'                  = 'Done'
    'msg.title.error'                 = 'Something went wrong'
    'msg.title.fullRestore'           = 'Restore stock Brave'
    'msg.title.hosts'                 = 'Hosts blocklist'
    'msg.title.importError'           = 'Import error'
    'msg.title.imported'              = 'Imported'
    'msg.title.info'                  = 'Info'
    'msg.title.scriptlet'             = 'Scriptlet manager'
    'msg.title.updater'               = 'Turn off Brave updates?'
    'msg.updater.confirm'             = "You are about to turn off part of Brave's updater.`r`n`r`nBrave will stop installing security fixes by itself, and you will have to update it by hand (Brave menu > About Brave) to stay safe.`r`n`r`nContinue?"
    'msg.scriptlet.backupDone'        = 'Backups checked/created for {0} list file(s).'
    'msg.scriptlet.backupFailed'      = "Backup failed:`r`n{0}"
    'msg.scriptlet.braveRunning'      = "Brave is currently running ({0} process(es)).`r`n`r`nClose Brave first if you want the safest patch. Continue anyway?"
    'msg.scriptlet.confirmDisable'    = "Disable {0} checked/selected scriptlet rule(s)?`r`n`r`nThis comments rules with: {1}`r`nBackups are created as list.txt.bfo-backup before the first edit."
    'msg.scriptlet.confirmReapply'    = "Reapply disabled scriptlet preferences to the current component lists under:`r`n{0}`r`n`r`nThis comments active rules whose raw text matches the preference file. Continue?"
    'msg.scriptlet.confirmRestoreAll' = "Restore every list.txt.bfo-backup under:`r`n{0}`r`n`r`nThis discards all BFO scriptlet edits in backed-up lists. Continue?"
    'msg.scriptlet.confirmRestoreSel' = "Restore {0} selected list file(s) from .bfo-backup?`r`nThis discards BFO scriptlet edits in those file(s)."
    'msg.scriptlet.disableFailed'     = "Disable failed:`r`n{0}"
    'msg.scriptlet.enableFailed'      = "Enable failed:`r`n{0}"
    'msg.scriptlet.exportFailed'      = "Export failed:`r`n{0}"
    'msg.scriptlet.folderMissing'     = 'Folder not found. Use Browse to choose the correct Brave User Data folder.'
    'msg.scriptlet.locked'            = "Editing Brave's internal filter-list files is disabled.`r`n`r`nTick 'Advanced edit mode' on the Scriptlets page first."
    'msg.scriptlet.noFiles'           = "No Brave filter-list files were found in:`r`n{0}`r`n`r`nUse Browse if your Brave User Data folder lives somewhere else."
    'msg.scriptlet.noRules'           = "No Brave scriptlet rules were found in:`r`n{0}`r`n`r`nUse Browse if your Brave User Data folder lives somewhere else."
    'msg.scriptlet.noRulesLoaded'     = 'Scan first; there are no scriptlet rules loaded.'
    'msg.scriptlet.nothingVisible'    = 'Nothing visible to export. Scan or change the filter first.'
    'msg.scriptlet.reapplyFailed'     = "Reapply failed:`r`n{0}"
    'msg.scriptlet.restoreAllFailed'  = "Restore all failed:`r`n{0}"
    'msg.scriptlet.restoreFailed'     = "Restore failed:`r`n{0}"
    'msg.scriptlet.restoreSelectFile' = 'Select a rule from the file you want to restore.'
    'msg.scriptlet.scanFailed'        = "Could not scan scriptlets:`r`n{0}`r`n`r`nUse Browse to point Brave-Free-Origin at the correct Brave User Data folder."
    'msg.scriptlet.scanFirst'         = 'Scan first; no scriptlet list files are loaded.'
    'msg.scriptlet.selectFirst'       = 'Check or select one or more scriptlet rules first.'
    'msg.scriptlet.selectOne'         = 'Select a scriptlet rule first.'
}

#endregion


#region Catalog data ----------------------------------------------------------
# Verified against Brave 154.1.96.59 (Chromium 154.0.8037.58, brave-core 1.96.x):
# every policy below is compiled into that build's policy table. Human-readable
# text lives in the string catalog under 'policy.<Name>.title' / '.description',
# keyed on the registry value name, which is never translated.
#
# One line per policy:  Page | Name | Type | Value | Kind | Risk | Lock | Presets
#   Kind   Off = turns a feature off, On = keeps a protection on, Set = sets a value
#   Risk   safe | low | medium | high  (what an everyday user could lose)
#   Lock   1 = Brave already behaves this way; ticking only makes it mandatory
#   Presets  Q Quick Debloat, O Origin Mode, R Recommended, B Privacy + Boost,
#            X Max Performance, P Max Privacy
$script:PolicyPageOrder = @(
    'braveFeatures', 'shieldsProtection', 'privacyTelemetry', 'sitePermissions', 'autofillPasswords', 'searchSuggestions',
    'safetyUpdates', 'aiGenAi', 'signinImport', 'webServicesBackground', 'performanceStartup', 'uiBloatExtras'
)

$script:PolicyTable = @(
    # -- Brave extras ---------------------------------------------------------
    'braveFeatures|BraveRewardsDisabled|DWORD|1|Off|low|0|QORBXP'
    'braveFeatures|BraveWalletDisabled|DWORD|1|Off|low|0|QORBXP'
    'braveFeatures|BraveVPNDisabled|DWORD|1|Off|low|0|QORBXP'
    'braveFeatures|BraveAIChatEnabled|DWORD|0|Off|low|0|QORBXP'
    'braveFeatures|BraveNewsDisabled|DWORD|1|Off|low|0|QORBXP'
    'braveFeatures|BraveTalkDisabled|DWORD|1|Off|low|0|QORBXP'
    'braveFeatures|TorDisabled|DWORD|1|Off|low|0|OBX'
    'braveFeatures|BraveWaybackMachineEnabled|DWORD|0|Off|safe|0|OBX'
    'braveFeatures|BravePlaylistEnabled|DWORD|0|Off|low|0|OBX'
    'braveFeatures|BraveSpeedreaderEnabled|DWORD|0|Off|low|0|OBX'
    'braveFeatures|EmailAliasesEnabled|DWORD|0|Off|low|0|OBX'
    'braveFeatures|PsstEnabled|DWORD|0|Off|low|0|OBX'
    # -- Shields and tracking protection ----------------------------------------
    'shieldsProtection|DefaultBraveAdblockSetting|DWORD|2|On|low|1|RBXP'
    'shieldsProtection|DefaultBraveFingerprintingV2Setting|DWORD|3|On|low|1|RBXP'
    'shieldsProtection|DefaultBraveReferrersSetting|DWORD|2|On|low|1|RBXP'
    'shieldsProtection|BraveTrackingQueryParametersFilteringEnabled|DWORD|1|On|low|1|RBXP'
    'shieldsProtection|BraveDeAmpEnabled|DWORD|1|On|low|1|RBXP'
    'shieldsProtection|BraveDebouncingEnabled|DWORD|1|On|low|1|RBXP'
    'shieldsProtection|BraveGlobalPrivacyControlEnabled|DWORD|1|On|safe|1|RBXP'
    'shieldsProtection|BraveReduceLanguageEnabled|DWORD|1|On|low|1|RBXP'
    'shieldsProtection|DefaultBraveHttpsUpgradeSetting|DWORD|2|Set|medium|0|P'
    'shieldsProtection|DefaultBraveRemember1PStorageSetting|DWORD|2|Set|high|0|P'
    # -- Telemetry and reports -----------------------------------------------------
    'privacyTelemetry|BraveP3AEnabled|DWORD|0|Off|safe|0|ORBXP'
    'privacyTelemetry|BraveStatsPingEnabled|DWORD|0|Off|safe|0|ORBXP'
    'privacyTelemetry|BraveWebDiscoveryEnabled|DWORD|0|Off|safe|1|ORBXP'
    'privacyTelemetry|MetricsReportingEnabled|DWORD|0|Off|low|0|RBXP'
    'privacyTelemetry|UserFeedbackAllowed|DWORD|0|Off|safe|0|RBXP'
    'privacyTelemetry|UrlKeyedAnonymizedDataCollectionEnabled|DWORD|0|Off|safe|1|RBXP'
    'privacyTelemetry|WebRtcEventLogCollectionAllowed|DWORD|0|Off|safe|1|RBXP'
    'privacyTelemetry|ChromeVariations|DWORD|2|Set|medium|0|P'
    'privacyTelemetry|WebRtcIPHandling|STRING|default_public_interface_only|Set|medium|0|P'
    # -- Site permissions (all blocked by default, for every site) ---------------------
    'sitePermissions|DefaultWebUsbGuardSetting|DWORD|2|Off|low|0|P'
    'sitePermissions|DefaultWebBluetoothGuardSetting|DWORD|2|Off|low|0|P'
    'sitePermissions|DefaultSerialGuardSetting|DWORD|2|Off|low|0|P'
    'sitePermissions|DefaultWebHidGuardSetting|DWORD|2|Off|low|0|P'
    'sitePermissions|DefaultSensorsSetting|DWORD|2|Off|low|0|P'
    'sitePermissions|DefaultIdleDetectionSetting|DWORD|2|Off|safe|0|P'
    'sitePermissions|DefaultLocalFontsSetting|DWORD|2|Off|low|0|P'
    'sitePermissions|DefaultWindowManagementSetting|DWORD|2|Off|low|0|P'
    # -- Passwords and autofill --------------------------------------------------------
    'autofillPasswords|PasswordManagerEnabled|DWORD|0|Off|medium|0|P'
    'autofillPasswords|PasswordLeakDetectionEnabled|DWORD|0|Off|safe|1|RBXP'
    'autofillPasswords|AutofillAddressEnabled|DWORD|0|Off|low|0|P'
    'autofillPasswords|AutofillCreditCardEnabled|DWORD|0|Off|low|0|P'
    'autofillPasswords|PaymentMethodQueryEnabled|DWORD|0|Off|low|0|P'
    # -- Search and suggestions -------------------------------------------------------
    'searchSuggestions|SearchSuggestEnabled|DWORD|0|Off|low|1|P'
    'searchSuggestions|SpellCheckServiceEnabled|DWORD|0|Off|low|1|RBXP'
    'searchSuggestions|SpellcheckEnabled|DWORD|0|Off|medium|0|-'
    'searchSuggestions|TranslateEnabled|DWORD|0|Off|low|0|P'
    'searchSuggestions|AlternateErrorPagesEnabled|DWORD|0|Off|safe|1|RBXP'
    # -- Safety and prompts ---------------------------------------------------------------
    'safetyUpdates|SafeBrowsingProtectionLevel|DWORD|1|Set|low|1|P'
    'safetyUpdates|SafeBrowsingExtendedReportingEnabled|DWORD|0|Off|safe|1|RBXP'
    'safetyUpdates|SafeBrowsingDeepScanningEnabled|DWORD|0|Off|safe|1|RBXP'
    'safetyUpdates|SafeBrowsingSurveysEnabled|DWORD|0|Off|safe|1|RBXP'
    'safetyUpdates|DefaultBrowserSettingEnabled|DWORD|0|Off|safe|0|RBXP'
    'safetyUpdates|BlockExternalExtensions|DWORD|1|On|low|0|RBXP'
    'safetyUpdates|PromotionsEnabled|DWORD|0|Off|safe|0|RBXP'
    'safetyUpdates|ComponentUpdatesEnabled|DWORD|0|Off|high|0|-'
    # -- AI features -------------------------------------------------------------------------
    'aiGenAi|BraveLocalAIEnabled|DWORD|0|Off|low|0|ORBXP'
    'aiGenAi|HelpMeWriteSettings|DWORD|2|Off|safe|1|RBXP'
    'aiGenAi|CreateThemesSettings|DWORD|2|Off|safe|1|RBXP'
    'aiGenAi|HistorySearchSettings|DWORD|2|Off|safe|1|RBXP'
    'aiGenAi|DevToolsGenAiSettings|DWORD|2|Off|low|1|RBXP'
    'aiGenAi|GeminiSettings|DWORD|1|Off|safe|1|RBXP'
    'aiGenAi|AIModeSettings|DWORD|1|Off|safe|1|RBXP'
    'aiGenAi|ThirdPartyAiChatSettings|DWORD|1|Off|safe|1|RBXP'
    'aiGenAi|SearchContentSharingSettings|DWORD|1|Off|safe|1|RBXP'
    'aiGenAi|GenAILocalFoundationalModelSettings|DWORD|1|Off|safe|1|RBXP'
    'aiGenAi|TabCompareSettings|DWORD|2|Off|safe|1|RBXP'
    'aiGenAi|AutofillPredictionSettings|DWORD|2|Off|safe|1|RBXP'
    # -- Sign-in, sync and import ---------------------------------------------------------
    'signinImport|BrowserSignin|DWORD|0|Off|safe|1|P'
    'signinImport|SyncDisabled|DWORD|1|Off|medium|0|P'
    'signinImport|ImportAutofillFormData|DWORD|0|Off|low|0|P'
    'signinImport|ImportBookmarks|DWORD|0|Off|low|0|P'
    'signinImport|ImportHistory|DWORD|0|Off|low|0|P'
    'signinImport|ImportSavedPasswords|DWORD|0|Off|medium|0|P'
    'signinImport|ImportSearchEngine|DWORD|0|Off|low|0|P'
    # -- Network and background -----------------------------------------------------------
    'webServicesBackground|BackgroundModeEnabled|DWORD|0|Off|low|0|BX'
    'webServicesBackground|EnableMediaRouter|DWORD|0|Off|low|0|BX'
    'webServicesBackground|DNSInterceptionChecksEnabled|DWORD|0|Off|low|0|BXP'
    'webServicesBackground|NetworkPredictionOptions|DWORD|2|Off|low|1|P'
    'webServicesBackground|DnsOverHttpsMode|STRING|automatic|Set|low|0|P'
    'webServicesBackground|BuiltInDnsClientEnabled|DWORD|0|Set|low|0|-'
    'webServicesBackground|QuicAllowed|DWORD|1|On|safe|1|-'
    # -- Performance and startup -----------------------------------------------------------
    'performanceStartup|HighEfficiencyModeEnabled|DWORD|1|On|low|0|BX'
    'performanceStartup|BatterySaverModeAvailability|DWORD|1|On|low|0|BX'
    'performanceStartup|HardwareAccelerationModeEnabled|DWORD|1|Set|low|1|-'
    'performanceStartup|DiskCacheSize|DWORD|262144000|Set|low|0|X'
    'performanceStartup|RestoreOnStartup|DWORD|5|Set|medium|0|X'
    'performanceStartup|NewTabPageLocation|STRING|about:blank|Set|medium|0|X'
    'performanceStartup|HomepageIsNewTabPage|DWORD|0|Set|safe|0|X'
    'performanceStartup|HomepageLocation|STRING|about:blank|Set|safe|0|X'
    'performanceStartup|ShowHomeButton|DWORD|0|Off|safe|1|-'
    'performanceStartup|BrowserLabsEnabled|DWORD|0|Off|safe|1|-'
    'performanceStartup|NTPCustomBackgroundEnabled|DWORD|0|Off|medium|0|-'
    # -- Interface clutter ------------------------------------------------------------------
    'uiBloatExtras|LiveCaptionEnabled|DWORD|0|Off|low|0|BX'
    'uiBloatExtras|AccessibilityImageLabelsEnabled|DWORD|0|Off|low|1|P'
    'uiBloatExtras|AutoplayAllowed|DWORD|0|Off|low|0|P'
    'uiBloatExtras|DesktopSharingHubEnabled|DWORD|0|Off|safe|0|X'
    'uiBloatExtras|QRCodeGeneratorEnabled|DWORD|0|Off|safe|0|X'
    'uiBloatExtras|PromptForDownloadLocation|DWORD|0|Off|low|0|-'
    'uiBloatExtras|BookmarkBarEnabled|DWORD|0|Off|low|0|-'
)

# Policies that offer a choice instead of a fixed value. The first entry is the
# default the table row starts with; ids are stable, labels are translated.
$script:PolicyChoices = @{
    'HardwareAccelerationModeEnabled' = ([ordered]@{ 'enable' = 1; 'disable' = 0 })
}

# ---- Updater scheduled tasks and Windows services (manual page, never in presets) ----
# Pattern and name lists live in the Core region; the strings are
# task.<id>.title / service.<id>.title and their .description.

# ---- Hosts blocklist groups (DNS-level, separate Apply on its own page) --------------
# Verified against brave-core v1.96.59 and the shipped chrome.dll. A hosts entry
# matches one exact name (no wildcards), so it is only a second line of defence
# behind the policies above. Presets only pre-tick a group when the feature it
# belongs to is also switched off by that preset. 'components' carries the
# servers Brave's Shields filter lists, extensions and Tor come from: blocking
# them silently freezes ad blocking, so no preset ever pre-ticks it.
$script:HostsBlocks = @(
    @{ Id = 'p3a';          Risk = 'safe';   Domains = @('collector.bsg.brave.com', 'star-randsrv.bsg.brave.com') }
    @{ Id = 'stats';        Risk = 'safe';   Domains = @('usage-ping.brave.com') }
    @{ Id = 'crash';        Risk = 'safe';   Domains = @('cr.brave.com') }
    @{ Id = 'webDiscovery'; Risk = 'safe';   Domains = @('collector.wdp.brave.com', 'quorum.wdp.brave.com', 'patterns.wdp.brave.com', 'star.wdp.brave.com') }
    @{ Id = 'rewards';      Risk = 'low';    Domains = @('api.rewards.brave.com', 'rewards.brave.com', 'grant.rewards.brave.com') }
    @{ Id = 'ads';          Risk = 'low';    Domains = @('anonymous.ads.brave.com', 'mywallet.ads.brave.com', 'geo.ads.brave.com', 'static.ads.brave.com', 'ohttp.ads.brave.com', 'search.anonymous.ads.brave.com') }
    @{ Id = 'news';         Risk = 'low';    Domains = @('brave-today-cdn.brave.com', 'pcdn.brave.com') }
    @{ Id = 'variations';   Risk = 'medium'; Domains = @('variations.brave.com') }
    @{ Id = 'components';   Risk = 'high';   Domains = @('go-updater.brave.com', 'componentupdater.brave.com', 'extensionupdater.brave.com', 'crxdownload.brave.com', 'brave-core-ext.s3.brave.com', 'redirector.brave.com', 'tor.bravesoftware.com') }
)
$script:PresetHosts = @{
    Minimal        = @('rewards', 'ads', 'news')
    Origin         = @('p3a', 'stats', 'webDiscovery', 'rewards', 'ads', 'news')
    Recommended    = @('p3a', 'stats', 'crash', 'webDiscovery', 'rewards', 'ads', 'news')
    Performance    = @('p3a', 'stats', 'crash', 'webDiscovery', 'rewards', 'ads', 'news')
    MaxPerformance = @('p3a', 'stats', 'crash', 'webDiscovery', 'rewards', 'ads', 'news')
    MaxPrivacy     = @('p3a', 'stats', 'crash', 'webDiscovery', 'rewards', 'ads', 'news', 'variations')
}

# ---- Search engines (opt-in override on the Search & startup page) -----------------------
# {searchTerms} is the standard Chromium placeholder Brave fills in. Brand names
# are not translated; only the "Custom..." entry has a real label.
$script:SearchEngines = [ordered]@{
    'brave'       = @{ LabelKey = 'engine.brave';      ProviderName = 'Brave Search'; URL = 'https://search.brave.com/search?q={searchTerms}';       Suggest = 'https://search.brave.com/api/suggest?q={searchTerms}';                    Keyword = 'brave';     Home = 'https://search.brave.com' }
    'duckduckgo'  = @{ LabelKey = 'engine.duckduckgo'; ProviderName = 'DuckDuckGo';   URL = 'https://duckduckgo.com/?q={searchTerms}';               Suggest = 'https://duckduckgo.com/ac/?q={searchTerms}&type=list';                    Keyword = 'ddg';       Home = 'https://duckduckgo.com' }
    'startpage'   = @{ LabelKey = 'engine.startpage';  ProviderName = 'Startpage';    URL = 'https://www.startpage.com/sp/search?query={searchTerms}'; Suggest = '';                                                                       Keyword = 'startpage'; Home = 'https://www.startpage.com' }
    'qwant'       = @{ LabelKey = 'engine.qwant';      ProviderName = 'Qwant';        URL = 'https://www.qwant.com/?q={searchTerms}';                 Suggest = 'https://api.qwant.com/v3/suggest/?q={searchTerms}&client=opensearch';     Keyword = 'qwant';     Home = 'https://www.qwant.com' }
    'ecosia'      = @{ LabelKey = 'engine.ecosia';     ProviderName = 'Ecosia';       URL = 'https://www.ecosia.org/search?q={searchTerms}';          Suggest = 'https://ac.ecosia.org/autocomplete?q={searchTerms}&type=list';            Keyword = 'ecosia';    Home = 'https://www.ecosia.org' }
    'mojeek'      = @{ LabelKey = 'engine.mojeek';     ProviderName = 'Mojeek';       URL = 'https://www.mojeek.com/search?q={searchTerms}';          Suggest = '';                                                                       Keyword = 'mojeek';    Home = 'https://www.mojeek.com' }
    'kagi'        = @{ LabelKey = 'engine.kagi';       ProviderName = 'Kagi (paid)';  URL = 'https://kagi.com/search?q={searchTerms}';                Suggest = 'https://kagisuggest.com/api/autosuggest?q={searchTerms}';                 Keyword = 'kagi';      Home = 'https://kagi.com' }
    'google'      = @{ LabelKey = 'engine.google';     ProviderName = 'Google';       URL = 'https://www.google.com/search?q={searchTerms}';          Suggest = 'https://www.google.com/complete/search?output=chrome&q={searchTerms}';    Keyword = 'google';    Home = 'https://www.google.com' }
    'bing'        = @{ LabelKey = 'engine.bing';       ProviderName = 'Bing';         URL = 'https://www.bing.com/search?q={searchTerms}';            Suggest = 'https://www.bing.com/osjson.aspx?query={searchTerms}';                    Keyword = 'bing';      Home = 'https://www.bing.com' }
    'yandex'      = @{ LabelKey = 'engine.yandex';     ProviderName = 'Yandex';       URL = 'https://yandex.com/search/?text={searchTerms}';          Suggest = 'https://suggest.yandex.com/suggest-ff.cgi?part={searchTerms}';            Keyword = 'yandex';    Home = 'https://yandex.com' }
    'custom'      = @{ LabelKey = 'engine.custom';     ProviderName = 'Custom...';    URL = '';                                                       Suggest = '';                                                                       Keyword = 'custom';    Home = ''; IsCustom = $true }
}

# Destination presets for "new tab" and "startup specific page". '__SEARCH__'
# resolves at apply time to the chosen engine's home URL.
$script:DestinationOptions = [ordered]@{
    'blank'           = @{ LabelKey = 'destination.blank';           Value = 'about:blank' }
    'ntpDefault'      = @{ LabelKey = 'destination.ntpDefault';      Value = '__SKIP__' }
    'matchSearch'     = @{ LabelKey = 'destination.matchSearch';     Value = '__SEARCH__' }
    'braveSearchHome' = @{ LabelKey = 'destination.braveSearchHome'; Value = 'https://search.brave.com' }
    'duckduckgoHome'  = @{ LabelKey = 'destination.duckduckgoHome';  Value = 'https://duckduckgo.com' }
    'googleHome'      = @{ LabelKey = 'destination.googleHome';      Value = 'https://www.google.com' }
    'custom'          = @{ LabelKey = 'destination.custom';          Value = '__CUSTOM__' }
}

# Startup behavior modes (RestoreOnStartup values: 1 last session, 4 list of URLs, 5 New Tab page).
$script:StartupModes = [ordered]@{
    'newTab'         = @{ LabelKey = 'startupMode.newTab';         Code = 5; UsesURL = $false }
    'restoreSession' = @{ LabelKey = 'startupMode.restoreSession'; Code = 1; UsesURL = $false }
    'blankPage'      = @{ LabelKey = 'startupMode.blankPage';      Code = 4; UsesURL = $true; FixedURL = 'about:blank' }
    'specificPages'  = @{ LabelKey = 'startupMode.specificPages';  Code = 4; UsesURL = $true; FixedURL = $null }
}

# ---- Stable id arrays that back the ComboBoxes ---------------------------------------------
# Item order in each ComboBox matches these arrays; the link is SelectedIndex.
$script:SearchEngineIds       = @($script:SearchEngines.Keys)
$script:SearchEngineLabelKeys = @($script:SearchEngineIds | ForEach-Object { $script:SearchEngines[$_].LabelKey })
# 'ntpDefault' stays in the data model so Load current state can match it, but it
# is never offered in the new-tab dropdown.
$script:DestinationIds        = @($script:DestinationOptions.Keys | Where-Object { $_ -ne 'ntpDefault' })
$script:DestinationLabelKeys  = @($script:DestinationIds | ForEach-Object { $script:DestinationOptions[$_].LabelKey })
$script:StartupModeIds        = @($script:StartupModes.Keys)
$script:StartupModeLabelKeys  = @($script:StartupModeIds | ForEach-Object { $script:StartupModes[$_].LabelKey })

# ---- Legacy config migration (v1.5-v1.11 exports stored English display labels) ------------
$script:LegacyHostsIds = @{
    'Brave P3A telemetry' = 'p3a'; 'Brave Variations' = 'variations'; 'Brave Stats ping' = 'stats'
    'Brave Rewards / BAT' = 'rewards'; 'Brave News CDN' = 'news'; 'Component Updates' = 'components'; 'Web Discovery' = 'webDiscovery'
}
$script:LegacySearchEngineIds = @{
    'Brave Search' = 'brave'; 'DuckDuckGo' = 'duckduckgo'; 'Startpage' = 'startpage'; 'Qwant' = 'qwant'; 'Ecosia' = 'ecosia'
    'Mojeek' = 'mojeek'; 'Kagi (paid)' = 'kagi'; 'Google' = 'google'; 'Bing' = 'bing'; 'Yandex' = 'yandex'; 'Custom...' = 'custom'
}
$script:LegacyDestinationIds = @{
    'Blank page (about:blank)' = 'blank'; 'Default new tab page (do not override)' = 'ntpDefault'
    'Match the search engine I picked above' = 'matchSearch'; 'Brave Search homepage' = 'braveSearchHome'
    'DuckDuckGo homepage' = 'duckduckgoHome'; 'Google homepage' = 'googleHome'; 'Custom URL...' = 'custom'
}
$script:LegacyStartupModeIds = @{
    'Open the new tab page' = 'newTab'; 'Restore my last session' = 'restoreSession'
    'Open a blank page' = 'blankPage'; 'Open a specific page or set' = 'specificPages'
}
#endregion


#region Core: Brave installs, registry, backups ---------------------------------
# Brave reads ONE policy key, for every channel and edition (Stable, Beta,
# Nightly, Dev and Brave Origin): brave-core defines a single policy key and the
# shipped chrome.dll contains exactly one. Versions 1.5 to 1.12 of this tool also
# wrote ...\Brave-Beta, ...\Brave-Nightly and ...\Brave-Dev, which Brave never
# reads; those legacy keys are only ever cleaned up (see Invoke-FullRestore).
$script:PolicyKeyPath    = Get-PolicyHivePath 'Brave'
$script:LegacyPolicyKeys = @('Brave-Beta', 'Brave-Nightly', 'Brave-Dev')

# Where each channel lives on disk. A policy applies to all of them at once.
$script:BraveInstalls = [ordered]@{
    'Stable'  = @{ Dir = 'Brave-Browser' }
    'Beta'    = @{ Dir = 'Brave-Browser-Beta' }
    'Nightly' = @{ Dir = 'Brave-Browser-Nightly' }
    'Dev'     = @{ Dir = 'Brave-Browser-Dev' }
}
foreach ($installName in @($script:BraveInstalls.Keys)) {
    $c = $script:BraveInstalls[$installName]
    $c.UserDataRoot  = Join-Path $env:LOCALAPPDATA ("BraveSoftware\{0}\User Data" -f $c.Dir)
    $c.InstallProbes = @(
        (Join-Path $env:ProgramFiles ("BraveSoftware\{0}\Application\brave.exe" -f $c.Dir)),
        (Join-Path ${env:ProgramFiles(x86)} ("BraveSoftware\{0}\Application\brave.exe" -f $c.Dir)),
        (Join-Path $env:LOCALAPPDATA ("BraveSoftware\{0}\Application\brave.exe" -f $c.Dir))
    )
}

# Finds brave.exe for one channel. The probes cover the standard per-machine and
# per-user locations; Stable additionally honours the "App Paths" registration
# so a custom install folder is still found.
function Get-BraveExecutable {
    param([string]$Channel = 'Stable')
    if (-not $script:BraveInstalls.Contains($Channel)) { return $null }
    foreach ($probe in $script:BraveInstalls[$Channel].InstallProbes) {
        if ($probe -and (Test-Path -LiteralPath $probe)) { return $probe }
    }
    if ($Channel -eq 'Stable') {
        foreach ($hive in @('HKCU:', 'HKLM:')) {
            try {
                $key = Get-Item -LiteralPath "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\brave.exe" -ErrorAction Stop
                $value = $key.GetValue('')
                if ($value -and (Test-Path -LiteralPath $value) -and $value -notmatch 'Brave-Browser-(Beta|Nightly|Dev)') { return $value }
            } catch { }
        }
    }
    return $null
}

function Get-DetectedChannels {
    return @($script:BraveInstalls.Keys | Where-Object { Get-BraveExecutable -Channel $_ })
}

# The install the app talks about and opens: Stable first, then the others.
function Get-PrimaryChannel {
    $found = @(Get-DetectedChannels)
    if ($found.Count -gt 0) { return $found[0] }
    return 'Stable'
}

function Get-BraveInfo {
    param([string]$Channel = 'Stable')
    $exe = Get-BraveExecutable -Channel $Channel
    $info = [pscustomobject]@{ Channel = $Channel; Exe = $exe; Version = ''; Major = 0; Scope = ''; Installed = [bool]$exe }
    if ($exe) {
        try { $info.Version = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion } catch { $info.Version = '' }
        if ($info.Version -match '^(\d+)\.') { $info.Major = [int]$Matches[1] }
        $info.Scope = if ($exe.StartsWith($env:LOCALAPPDATA, [System.StringComparison]::OrdinalIgnoreCase)) { 'user' } else { 'machine' }
    }
    return $info
}

# ---- Registry ----------------------------------------------------------------
# One pass over a policy key: every value with its registry type, plus the
# subkeys (RestoreOnStartupURLs, 3rdparty, ExtensionInstallForcelist...).
function Read-PolicySnapshot {
    param([string]$Path)
    $snap = [pscustomobject]@{
        Path = $Path; Exists = $false
        Values = @{}; Kinds = @{}; SubKeys = @(); Urls = @()
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $snap }
    $snap.Exists = $true
    $key = Get-Item -LiteralPath $Path
    foreach ($name in $key.GetValueNames()) {
        $snap.Values[$name] = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $snap.Kinds[$name]  = $key.GetValueKind($name).ToString()
    }
    $snap.SubKeys = @($key.GetSubKeyNames())
    if ($snap.SubKeys -contains 'RestoreOnStartupURLs') {
        $sub = Get-Item -LiteralPath (Join-Path $Path 'RestoreOnStartupURLs')
        $numbered = @()
        foreach ($n in $sub.GetValueNames()) {
            if ($n -match '^\d+$') { $numbered += [pscustomobject]@{ Index = [int]$n; Value = [string]$sub.GetValue($n) } }
        }
        $snap.Urls = @($numbered | Sort-Object Index | ForEach-Object { $_.Value })
    }
    return $snap
}

function Set-PolicyRegistryValue {
    param([string]$Path, [string]$Name, [string]$Type, $Value)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    $kind = if ($Type -eq 'DWORD') { 'DWord' } else { 'String' }
    if ($kind -eq 'DWord') { $Value = [int]$Value }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $kind -Force | Out-Null
}

function Remove-PolicyRegistryValue {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $key = Get-Item -LiteralPath $Path
    if ($key.GetValueNames() -notcontains $Name) { return $false }
    Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
    return $true
}

# ---- Backups -------------------------------------------------------------------
# [Environment]::GetFolderPath knows where Documents really is; the folder is
# redirected to OneDrive on many PCs, so USERPROFILE\Documents can be a stray.
function Get-BackupDirectory {
    $docs = [Environment]::GetFolderPath('MyDocuments')
    if (-not $docs) { $docs = Join-Path $env:USERPROFILE 'Documents' }
    $dir = Join-Path $docs 'Brave-Free-Origin-Backups'
    if ($script:SelfTestMode) { $dir = Join-Path ([System.IO.Path]::GetTempPath()) 'bfo-selftest-backups' }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Remove-OldBackups {
    param([string]$Filter, [int]$Keep = 30)
    try {
        Get-ChildItem -LiteralPath (Get-BackupDirectory) -Filter $Filter -File -ErrorAction Stop |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

# Returns @{ Ok; File; Reason }. "Nothing to back up" and "the backup failed" are
# different outcomes and must not be reported the same way.
function Export-PolicyBackup {
    # The whole BraveSoftware policy branch, so legacy per-channel keys are saved too.
    $hive = if ($script:SelfTestMode) { $script:SandboxRegistryRoot } else { 'HKLM:\Software\Policies\BraveSoftware' }
    if (-not (Test-Path -LiteralPath $hive)) { return @{ Ok = $true; File = $null; Reason = 'none' } }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $file  = Join-Path (Get-BackupDirectory) "brave-policies-backup-$stamp.reg"
    $regKey = $hive -replace '^(HK[A-Z]+):\\', '$1\'
    $output = & reg.exe EXPORT $regKey $file /y 2>&1
    if ($LASTEXITCODE -ne 0) {
        return @{ Ok = $false; File = $null; Reason = ("reg.exe exit code {0}: {1}" -f $LASTEXITCODE, (($output | Out-String).Trim())) }
    }
    Remove-OldBackups -Filter 'brave-policies-backup-*.reg'
    return @{ Ok = $true; File = $file; Reason = '' }
}
#endregion

#region Core: hosts file -------------------------------------------------------
$script:HostsSentinelStart = '# === Brave-Free-Origin START - managed block, do not edit between sentinels ==='
$script:HostsSentinelEnd   = '# === Brave-Free-Origin END ==='
$script:HostsFile = if ($script:SelfTestMode) { $script:SandboxHostsFile } else { Join-Path $env:WINDIR 'System32\drivers\etc\hosts' }
$script:HostsStartRx = [regex]'^\s*#\s*===\s*Brave-Free-Origin START\b'
$script:HostsEndRx   = [regex]'^\s*#\s*===\s*Brave-Free-Origin END\b'

# The hosts file is a system file the user may have edited by hand, in any
# encoding. Decoding it as text and writing it back as ASCII destroys every
# non-ASCII character (accented comments, IDN names). So the bytes are handled
# losslessly: Latin-1 maps every byte to exactly one char and back, and only a
# real UTF-16 file (BOM) is decoded as such. The block we add is pure ASCII.
function Read-HostsFileText {
    if (-not (Test-Path -LiteralPath $script:HostsFile)) {
        return [pscustomobject]@{ Text = ''; Encoding = [System.Text.Encoding]::GetEncoding(28591); Exists = $false }
    }
    $bytes = [System.IO.File]::ReadAllBytes($script:HostsFile)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $enc = New-Object System.Text.UnicodeEncoding($false, $true)
        return [pscustomobject]@{ Text = $enc.GetString($bytes, 2, $bytes.Length - 2); Encoding = $enc; Exists = $true }
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $enc = New-Object System.Text.UnicodeEncoding($true, $true)
        return [pscustomobject]@{ Text = $enc.GetString($bytes, 2, $bytes.Length - 2); Encoding = $enc; Exists = $true }
    }
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    return [pscustomobject]@{ Text = $latin1.GetString($bytes); Encoding = $latin1; Exists = $true }
}

function Split-HostsLines {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $lines = [regex]::Split($Text, "\r\n|\n|\r")
    # A trailing newline yields one empty last element that is not a real line.
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
    return @($lines)
}

function Get-HostsManagedDomains {
    $domains = @()
    $inBlock = $false
    foreach ($line in (Split-HostsLines (Read-HostsFileText).Text)) {
        if ($script:HostsStartRx.IsMatch($line)) { $inBlock = $true; continue }
        if ($script:HostsEndRx.IsMatch($line))   { $inBlock = $false; continue }
        if ($inBlock -and $line -match '^\s*0\.0\.0\.0\s+(\S+)') { $domains += $Matches[1] }
    }
    return $domains
}

function Backup-HostsFile {
    if (-not (Test-Path -LiteralPath $script:HostsFile)) { return $null }
    $file = Join-Path (Get-BackupDirectory) ("hosts-backup-{0}.bak" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $script:HostsFile -Destination $file -Force
    Remove-OldBackups -Filter 'hosts-backup-*.bak'
    Write-Log "Hosts backup saved: $file" 'OK'
    return $file
}

# Rebuilds the hosts file with our sentinel block replaced (or removed when
# $Domains is empty). Everything outside the block is preserved byte for byte.
function Set-HostsManagedDomains {
    param([string[]]$Domains)
    [void](Backup-HostsFile)
    $current = Read-HostsFileText
    $newline = if ($current.Text -match "\r\n") { "`r`n" } elseif ($current.Text -match "\n") { "`n" } else { "`r`n" }

    $kept = New-Object System.Collections.ArrayList
    $skipping = $false
    foreach ($line in (Split-HostsLines $current.Text)) {
        if ($script:HostsStartRx.IsMatch($line)) { $skipping = $true; continue }
        if ($script:HostsEndRx.IsMatch($line))   { $skipping = $false; continue }
        if (-not $skipping) { [void]$kept.Add($line) }
    }
    while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) { $kept.RemoveAt($kept.Count - 1) }

    if ($Domains -and $Domains.Count -gt 0) {
        [void]$kept.Add('')
        [void]$kept.Add($script:HostsSentinelStart)
        [void]$kept.Add("# Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') by Brave Free Origin. Remove it from the app or delete these lines.")
        foreach ($d in ($Domains | Sort-Object -Unique)) { [void]$kept.Add("0.0.0.0 $d") }
        [void]$kept.Add($script:HostsSentinelEnd)
    }
    $text = ($kept -join $newline) + $newline

    $bom = @()
    if ($current.Encoding -is [System.Text.UnicodeEncoding]) { $bom = $current.Encoding.GetPreamble() }
    $bytes = $bom + $current.Encoding.GetBytes($text)

    # The file may be read-only, or briefly locked by antivirus.
    $attributes = $null
    if (Test-Path -LiteralPath $script:HostsFile) {
        $attributes = (Get-Item -LiteralPath $script:HostsFile).Attributes
        if ($attributes -band [System.IO.FileAttributes]::ReadOnly) {
            Set-ItemProperty -LiteralPath $script:HostsFile -Name Attributes -Value ($attributes -bxor [System.IO.FileAttributes]::ReadOnly)
        }
    }
    $written = $false
    for ($attempt = 1; $attempt -le 4 -and -not $written; $attempt++) {
        try {
            [System.IO.File]::WriteAllBytes($script:HostsFile, [byte[]]$bytes)
            $written = $true
        } catch [System.IO.IOException] {
            if ($attempt -eq 4) { throw }
            Start-Sleep -Milliseconds (250 * $attempt)
        }
    }
    if ($attributes -band [System.IO.FileAttributes]::ReadOnly) {
        Set-ItemProperty -LiteralPath $script:HostsFile -Name Attributes -Value $attributes
    }
    # Prove it: read back and compare, so "hosts updated" is never a guess.
    $back = @(Get-HostsManagedDomains)
    $want = @($Domains | Sort-Object -Unique)
    if (($back -join ',') -ne ($want -join ',')) {
        throw "The hosts file was written but its managed block does not match what was requested ($($back.Count) of $($want.Count) domains)."
    }
    if (-not $script:SelfTestMode) { & ipconfig.exe /flushdns | Out-Null }
    Write-Log "Hosts block written: $($want.Count) domain(s)." 'OK'
}
#endregion

#region Core: updater tasks and services ----------------------------------------
# Brave's updater (Omaha) names its scheduled tasks with a GUID suffix, and with
# the user's SID for per-user installs, e.g.
#   BraveSoftwareUpdateTaskMachineCore{GUID}   per-machine install
#   BraveSoftwareUpdateTaskUserS-1-5-21-...Core{GUID}   per-user install
# so they can only be found by pattern, never by exact name. Enumerating tasks
# takes about a second, so results are cached and refreshed on demand.
$script:UpdaterTaskDefs = @(
    @{ Id = 'core'; Pattern = 'BraveSoftwareUpdateTask*Core*' }
    @{ Id = 'ua';   Pattern = 'BraveSoftwareUpdateTask*UA*' }
)
$script:UpdaterServiceDefs = @(
    @{ Id = 'brave';  Name = 'brave';  Default = 'Automatic' }
    @{ Id = 'bravem'; Name = 'bravem'; Default = 'Manual' }
)
# Never offered as a checkbox: Brave Elevation Service guards the keys that encrypt
# cookies and saved data (App-Bound Encryption) and is not an updater; the VPN
# services only exist after a VPN purchase. Versions 1.5-1.12 could have switched
# them off, so Restore turns them back on when it finds them disabled.
$script:RestoreOnlyServices = @(
    @{ Name = 'BraveElevationService';    Default = 'Manual' }
    @{ Name = 'BraveVpnService';          Default = 'Manual' }
    @{ Name = 'BraveVpnWireguardService'; Default = 'Manual' }
)
$script:TaskCache    = $null
$script:FakeTasks    = @()      # sandbox: objects with Name, State
$script:FakeServices = @()      # sandbox: objects with Name, StartType, Status

function Get-BfoTasks {
    param([switch]$Refresh)
    if ($script:SelfTestMode) { return @($script:FakeTasks) }
    if ($script:TaskCache -and -not $Refresh) { return @($script:TaskCache) }
    $found = @()
    try {
        foreach ($t in @(Get-ScheduledTask -TaskName 'BraveSoftwareUpdateTask*' -ErrorAction SilentlyContinue)) {
            # A foreign task that merely shares the prefix must never be touched.
            $exe = (@($t.Actions | ForEach-Object { "$($_.Execute)" }) -join ' ')
            if ($exe -and $exe -notlike '*BraveUpdate.exe*') { continue }
            $found += [pscustomobject]@{ Name = $t.TaskName; State = "$($t.State)"; Task = $t }
        }
    } catch { Write-Log "Scheduled task lookup failed: $_" 'WARN' }
    $script:TaskCache = $found
    return @($found)
}

function Find-BfoTasks {
    param([string]$Pattern, [switch]$Refresh)
    return @(Get-BfoTasks -Refresh:$Refresh | Where-Object { $_.Name -like $Pattern })
}

function Set-BfoTaskEnabled {
    param($TaskInfo, [bool]$Enabled)
    if ($script:SelfTestMode) {
        foreach ($t in $script:FakeTasks) { if ($t.Name -eq $TaskInfo.Name) { $t.State = if ($Enabled) { 'Ready' } else { 'Disabled' } } }
        return
    }
    if ($Enabled) { Enable-ScheduledTask -InputObject $TaskInfo.Task -ErrorAction Stop | Out-Null }
    else          { Disable-ScheduledTask -InputObject $TaskInfo.Task -ErrorAction Stop | Out-Null }
}

# Updater services (per-machine installs only) matched by name prefix AND image
# path. Id is 'brave' or 'bravem' ('bravem' also starts with 'brave').
function Find-BfoUpdaterServices {
    param([string]$Id)
    $all = @()
    if ($script:SelfTestMode) { $all = @($script:FakeServices) }
    else {
        try {
            foreach ($c in @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Where-Object { $_.PathName -like '*\BraveSoftware\Update\BraveUpdate.exe*' })) {
                $start = switch ("$($c.StartMode)") { 'Auto' { 'Automatic' } default { "$($c.StartMode)" } }
                $all += [pscustomobject]@{ Name = $c.Name; StartType = $start; Status = "$($c.State)" }
            }
        } catch { Write-Log "Service lookup failed: $_" 'WARN' }
    }
    return @($all | Where-Object {
        if ($Id -eq 'bravem') { $_.Name -like 'bravem*' } else { $_.Name -like 'brave*' -and $_.Name -notlike 'bravem*' }
    })
}

# One service by exact name (used to undo what older versions may have disabled).
function Get-BfoService {
    param([string]$Name)
    if ($script:SelfTestMode) { return $script:FakeServices | Where-Object { $_.Name -eq $Name } | Select-Object -First 1 }
    return Get-Service -Name $Name -ErrorAction SilentlyContinue
}

function Set-BfoServiceStartType {
    param([string]$Name, [string]$StartType, [switch]$StopIfRunning)
    if ($script:SelfTestMode) {
        foreach ($s in $script:FakeServices) {
            if ($s.Name -eq $Name) { $s.StartType = $StartType; if ($StopIfRunning) { $s.Status = 'Stopped' } }
        }
        return
    }
    if ($StopIfRunning) {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
    }
    Set-Service -Name $Name -StartupType $StartType -ErrorAction Stop
}
#endregion

#region Core: opening Brave --------------------------------------------------
# This app runs elevated, but Brave must not. A browser started from an elevated
# process runs with administrator rights (dangerous) or, on current Chromium,
# tries to relaunch itself unelevated and may silently do nothing when another
# instance already owns the profile. Handing the launch to Explorer - which
# runs at normal privilege - starts it the way a double-click would. If that is
# impossible the address is copied so the user can paste it.
$script:TempFiles = New-Object System.Collections.ArrayList
$script:LastOpenedUrl = $null

function Start-UnelevatedProcess {
    param([string]$FilePath, [string]$Arguments)
    if ($script:SelfTestMode) { $script:LastOpenedUrl = $Arguments; return $true }
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { return $false }
    $shortcut = Join-Path ([System.IO.Path]::GetTempPath()) ("bfo-open-{0}.lnk" -f ([guid]::NewGuid().ToString('N')))
    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut($shortcut)
        $link.TargetPath = $FilePath
        $link.Arguments  = $Arguments
        $link.WorkingDirectory = Split-Path -Parent $FilePath
        $link.Save()
    } finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
    [void]$script:TempFiles.Add($shortcut)
    Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe') -ArgumentList ('"{0}"' -f $shortcut) | Out-Null
    return $true
}

function Remove-TempShortcuts {
    foreach ($f in @($script:TempFiles)) { try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop } catch { } }
    $script:TempFiles.Clear()
}

# $Target is a URL such as brave://policy or an https:// address.
function Open-InBrave {
    param([string]$Target)
    $exe = Get-BraveExecutable -Channel (Get-PrimaryChannel)
    if (-not $exe) {
        [void](Show-Message -Text (T 'msg.braveMissing') -Title (T 'msg.title.info') -Icon 'Information')
        return $false
    }
    $opened = $false
    try { $opened = Start-UnelevatedProcess -FilePath $exe -Arguments $Target }
    catch { Write-Log "Could not start Brave for $Target : $_" 'WARN' }
    if ($opened) {
        Write-Log "Opened $Target in Brave." 'OK'
        return $true
    }
    try { [System.Windows.Forms.Clipboard]::SetText($Target) } catch { }
    Write-Log "Brave could not be started from here; copied $Target to the clipboard." 'WARN'
    [void](Show-Message -Text (T 'msg.openBrave.copied' @($Target)) -Title (T 'msg.title.info') -Icon 'Information')
    return $false
}
#endregion


#region Model: settings, presets, planning -------------------------------------
# Everything in this region is UI-independent: the window only reads and writes
# the item list below, and Preview, Apply and Verify all derive from the same
# plan. That keeps "what you see" and "what gets written" from drifting apart,
# and lets the self-test drive the whole pipeline without a window.
$script:Items       = New-Object System.Collections.Generic.List[object]
$script:ItemIndex   = @{}
$script:PolicyByName = @{}
$script:PolicyPages = [ordered]@{}
$script:ActiveProfile = 'Custom'
$script:Snapshot    = $null      # snapshot of the policy key as last read

# Presets are stable ids; labels live in the string catalog. Order is the order
# of the buttons.
$script:PresetKeys  = @('Minimal', 'Recommended', 'Origin', 'Performance', 'MaxPerformance', 'MaxPrivacy', 'None')
$script:AllPresetKeys = $script:PresetKeys + @('CurrentState', 'Custom')
$script:PresetCodes = @{ Minimal = 'Q'; Origin = 'O'; Recommended = 'R'; Performance = 'B'; MaxPerformance = 'X'; MaxPrivacy = 'P' }

function Initialize-PolicyCatalog {
    $script:PolicyPages.Clear()
    $script:PolicyByName.Clear()
    foreach ($row in $script:PolicyTable) {
        if ($row -match '^\s*(#|$)') { continue }
        $f = $row.Split('|')
        if ($f.Count -ne 8) { throw "Bad policy table row: $row" }
        $value = if ($f[2] -eq 'DWORD') { [int]$f[3] } else { $f[3] }
        $def = @{
            Page = $f[0]; Name = $f[1]; Type = $f[2]; Value = $value
            Kind = $f[4]; Risk = $f[5]; Lock = ($f[6] -eq '1'); Presets = $f[7]; Choices = $null
        }
        if ($script:PolicyChoices.ContainsKey($def.Name)) { $def.Choices = $script:PolicyChoices[$def.Name] }
        if (-not $script:PolicyPages.Contains($def.Page)) { $script:PolicyPages[$def.Page] = New-Object System.Collections.ArrayList }
        [void]$script:PolicyPages[$def.Page].Add($def)
        $script:PolicyByName[$def.Name] = $def
    }
}

function New-BfoItem {
    param([string]$Kind, [string]$Id, [string]$Page, $Def)
    $item = [pscustomobject]@{
        Kind = $Kind; Id = $Id; Page = $Page; Def = $Def
        Checked = $false; Value = $null; Baseline = $null; Loaded = $false; Detail = $null
        Row = $null; Status = ''
    }
    if ($Def -and $Def.ContainsKey('Value')) { $item.Value = $Def.Value }
    [void]$script:Items.Add($item)
    $script:ItemIndex["$Kind|$Id"] = $item
    return $item
}

function Get-BfoItem {
    param([string]$Kind, [string]$Id)
    return $script:ItemIndex["$Kind|$Id"]
}

function Initialize-Items {
    $script:Items.Clear()
    $script:ItemIndex.Clear()
    foreach ($page in $script:PolicyPageOrder) {
        if (-not $script:PolicyPages.Contains($page)) { continue }
        foreach ($def in $script:PolicyPages[$page]) { [void](New-BfoItem -Kind 'Policy' -Id $def.Name -Page $page -Def $def) }
    }
    foreach ($def in $script:UpdaterTaskDefs)    { [void](New-BfoItem -Kind 'Task'    -Id $def.Id -Page 'updater' -Def $def) }
    foreach ($def in $script:UpdaterServiceDefs) { [void](New-BfoItem -Kind 'Service' -Id $def.Id -Page 'updater' -Def $def) }
    foreach ($def in $script:HostsBlocks)        { [void](New-BfoItem -Kind 'Host'    -Id $def.Id -Page 'hosts'   -Def $def) }
}

# ---- Overrides (search engine / new tab / startup) ---------------------------
# These three are plain model state; the window edits it, the plan reads it.
$script:Overrides = @{
    Search  = @{ Enabled = $false; EngineId = 'brave'; CustomUrl = '' }
    Ntp     = @{ Enabled = $false; DestinationId = 'blank'; CustomUrl = '' }
    Startup = @{ Enabled = $false; ModeId = 'newTab'; Urls = '' }
}
# Policies that versions 1.5-1.12 wrote and that Brave 154 no longer has (removed upstream, cloud-only or renamed).
# They are not offered any more, but they are still this tool's own leftovers: Apply and Restore stock clean them up
# and Verify does not call them foreign. Some (SigninAllowed, the Lens policies, IPFSEnabled) are still honoured by
# Brave, so leaving them behind would keep sign-in or Lens switched off after a "restore".
$script:LegacyPolicyNames = @(
    'ChromeCleanupEnabled', 'ChromeCleanupReportingEnabled', 'CloudPrintSubmitEnabled', 'CloudReportingEnabled',
    'GenAiDefaultSettings', 'IPFSEnabled', 'LensDesktopNTPSearchEnabled', 'LensOverlaySettings', 'LensRegionSearchEnabled',
    'MediaRouterEnabled', 'PromotionalTabsEnabled', 'ReadingListEnabled', 'SigninAllowed', 'TabOrganizerSettings',
    'WebTorrentDisabled', 'WelcomePageOnOSUpgradeEnabled'
)
$script:OverridePolicyNames = @(
    'DefaultSearchProviderEnabled', 'DefaultSearchProviderName', 'DefaultSearchProviderKeyword',
    'DefaultSearchProviderSearchURL', 'DefaultSearchProviderSuggestURL',
    'NewTabPageLocation', 'RestoreOnStartup'
)

function Resolve-Destination {
    param([string]$DestinationId, [string]$CustomUrl, [string]$SearchEngineHome)
    $entry = $script:DestinationOptions[$DestinationId]
    if (-not $entry) { return $null }
    switch ($entry.Value) {
        '__SKIP__'   { return $null }
        '__SEARCH__' { return $SearchEngineHome }
        '__CUSTOM__' { return $CustomUrl.Trim() }
        default      { return $entry.Value }
    }
}

function Test-HttpUrl {
    param([string]$Url)
    $u = $null
    return ([System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$u) -and ($u.Scheme -in @('http', 'https', 'about', 'brave', 'chrome', 'file')))
}

# Returns the registry values the search/new-tab/startup overrides want, or
# throws a message the user can act on when the input is unusable.
function Get-DesiredOverrides {
    $desired = [ordered]@{}
    $urls = @()

    $s = $script:Overrides.Search
    $engine = $script:SearchEngines[$s.EngineId]
    if ($s.Enabled) {
        if (-not $engine) { throw (T 'err.search.unknown') }
        $url = $engine.URL; $name = $engine.ProviderName
        if ($engine.IsCustom) {
            $url = "$($s.CustomUrl)".Trim()
            if ([string]::IsNullOrWhiteSpace($url)) { throw (T 'err.search.empty') }
            if ($url -notmatch '\{searchTerms\}')   { throw (T 'err.search.placeholder') }
            if (-not (Test-HttpUrl ($url -replace '\{searchTerms\}', 'x'))) { throw (T 'err.search.badUrl') }
            $name = 'Custom Search'
        }
        $desired['DefaultSearchProviderEnabled'] = @{ Type = 'DWORD';  Value = 1 }
        $desired['DefaultSearchProviderName']    = @{ Type = 'STRING'; Value = $name }
        $desired['DefaultSearchProviderKeyword'] = @{ Type = 'STRING'; Value = $engine.Keyword }
        $desired['DefaultSearchProviderSearchURL'] = @{ Type = 'STRING'; Value = $url }
        if ($engine.Suggest) { $desired['DefaultSearchProviderSuggestURL'] = @{ Type = 'STRING'; Value = $engine.Suggest } }
    }

    $n = $script:Overrides.Ntp
    if ($n.Enabled) {
        $engineHome = ''
        if ($engine -and -not $engine.IsCustom) { $engineHome = $engine.Home }
        $target = Resolve-Destination -DestinationId $n.DestinationId -CustomUrl "$($n.CustomUrl)" -SearchEngineHome $engineHome
        if ([string]::IsNullOrWhiteSpace($target)) { throw (T 'err.ntp.empty') }
        if (-not (Test-HttpUrl $target)) { throw (T 'err.ntp.badUrl') }
        $desired['NewTabPageLocation'] = @{ Type = 'STRING'; Value = $target }
    }

    $st = $script:Overrides.Startup
    if ($st.Enabled) {
        $mode = $script:StartupModes[$st.ModeId]
        if (-not $mode) { throw (T 'err.startup.unknown') }
        $desired['RestoreOnStartup'] = @{ Type = 'DWORD'; Value = $mode.Code }
        if ($mode.UsesURL) {
            $urls = if ($mode.FixedURL) { @($mode.FixedURL) }
                    else { @("$($st.Urls)" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
            if ($urls.Count -eq 0) { throw (T 'err.startup.empty') }
            foreach ($u in $urls) { if (-not (Test-HttpUrl $u)) { throw (T 'err.startup.badUrl' @($u)) } }
        }
    }
    return [pscustomobject]@{ Values = $desired; Urls = @($urls) }
}

# ---- Desired state -----------------------------------------------------------
function Get-DesiredPolicyMap {
    $map = [ordered]@{}
    foreach ($item in $script:Items) {
        if ($item.Kind -eq 'Policy' -and $item.Checked) {
            $map[$item.Id] = @{ Type = $item.Def.Type; Value = $item.Value }
        }
    }
    $ov = Get-DesiredOverrides
    # Overrides run last and always win over a same-named ticked policy.
    foreach ($k in $ov.Values.Keys) { $map[$k] = $ov.Values[$k] }
    return [pscustomobject]@{ Values = $map; Urls = $ov.Urls; HasStartupOverride = $script:Overrides.Startup.Enabled }
}

function Get-ManagedPolicyNames {
    return @(@($script:PolicyByName.Keys) + $script:OverridePolicyNames + $script:LegacyPolicyNames | Select-Object -Unique)
}

# What Apply would do to the policy key. Each op has an Action of Add, Change,
# Keep or Clear so the same list drives Preview and Apply.
function Get-RegistryOps {
    param($Desired, $Snapshot)
    $ops = New-Object System.Collections.ArrayList
    foreach ($name in (Get-ManagedPolicyNames)) {
        $has = $Snapshot.Values.ContainsKey($name)
        if ($Desired.Values.Contains($name)) {
            $want = $Desired.Values[$name]
            $kindWanted = if ($want.Type -eq 'DWORD') { 'DWord' } else { 'String' }
            $action = 'Add'
            if ($has) {
                $same = ("$($Snapshot.Values[$name])" -eq "$($want.Value)") -and ($Snapshot.Kinds[$name] -eq $kindWanted)
                $action = if ($same) { 'Keep' } else { 'Change' }
            }
            [void]$ops.Add([pscustomobject]@{
                Path = $script:PolicyKeyPath; Action = $action; Name = $name
                Type = $want.Type; Value = $want.Value; Old = $(if ($has) { $Snapshot.Values[$name] } else { $null })
            })
        } elseif ($has) {
            [void]$ops.Add([pscustomobject]@{
                Path = $script:PolicyKeyPath; Action = 'Clear'; Name = $name
                Type = $null; Value = $null; Old = $Snapshot.Values[$name]
            })
        }
    }
    return @($ops)
}

function Get-StartupUrlOp {
    param($Desired, $Snapshot)
    $want = @($Desired.Urls)
    $have = @($Snapshot.Urls)
    if (-not $Desired.HasStartupOverride) { $want = @() }
    if (($want -join "`n") -eq ($have -join "`n")) { return $null }
    return [pscustomobject]@{ Path = (Join-Path $script:PolicyKeyPath 'RestoreOnStartupURLs'); Want = $want; Have = $have }
}

# Updater tasks/services only take part when the user changed them: their
# state is read lazily, and an untouched row must never flip something the
# user (or another tool) set on purpose.
function Get-SystemOps {
    param([switch]$Refresh)
    $ops = New-Object System.Collections.ArrayList
    foreach ($item in $script:Items) {
        if ($item.Kind -eq 'Task') {
            if (-not $item.Loaded -or $item.Checked -eq $item.Baseline) { continue }
            foreach ($t in (Find-BfoTasks -Pattern $item.Def.Pattern -Refresh:$Refresh)) {
                $disabled = ($t.State -eq 'Disabled')
                if ($item.Checked -and -not $disabled) { [void]$ops.Add([pscustomobject]@{ Kind = 'Task'; Id = $item.Id; Action = 'Disable'; Name = $t.Name; Info = $t }) }
                if (-not $item.Checked -and $disabled) { [void]$ops.Add([pscustomobject]@{ Kind = 'Task'; Id = $item.Id; Action = 'Enable';  Name = $t.Name; Info = $t }) }
            }
        }
        if ($item.Kind -eq 'Service') {
            if (-not $item.Loaded -or $item.Checked -eq $item.Baseline) { continue }
            foreach ($svc in (Find-BfoUpdaterServices -Id $item.Id)) {
                $disabled = ("$($svc.StartType)" -eq 'Disabled')
                if ($item.Checked -and -not $disabled) { [void]$ops.Add([pscustomobject]@{ Kind = 'Service'; Id = $item.Id; Action = 'Disable'; Name = $svc.Name; Info = $svc }) }
                if (-not $item.Checked -and $disabled) { [void]$ops.Add([pscustomobject]@{ Kind = 'Service'; Id = $item.Id; Action = 'Enable';  Name = $svc.Name; Info = $svc; Default = $item.Def.Default }) }
            }
        }
    }
    return @($ops)
}

function New-ApplyPlan {
    $desired = Get-DesiredPolicyMap
    $snap = Read-PolicySnapshot -Path $script:PolicyKeyPath
    $plan = [pscustomobject]@{
        Desired = $desired
        Registry = @(Get-RegistryOps -Desired $desired -Snapshot $snap)
        UrlOps = @(); System = @()
        Counts = @{ Add = 0; Change = 0; Keep = 0; Clear = 0 }
    }
    $urlOp = Get-StartupUrlOp -Desired $desired -Snapshot $snap
    if ($urlOp) { $plan.UrlOps = @($urlOp) }
    foreach ($op in $plan.Registry) { $plan.Counts[$op.Action]++ }
    $plan.System = @(Get-SystemOps)
    return $plan
}

function Test-PlanHasChanges {
    param($Plan)
    return (($Plan.Counts.Add + $Plan.Counts.Change + $Plan.Counts.Clear) -gt 0) -or $Plan.UrlOps.Count -gt 0 -or $Plan.System.Count -gt 0
}

# Writes the plan. One failing value never aborts the rest; every failure is
# collected so the final message can say exactly what did not happen.
function Invoke-ApplyPlan {
    param($Plan)
    $result = [pscustomobject]@{ Added = 0; Changed = 0; Cleared = 0; Kept = 0; System = 0; Failures = @() }
    foreach ($op in $Plan.Registry) {
        try {
            switch ($op.Action) {
                'Add'    { Set-PolicyRegistryValue -Path $op.Path -Name $op.Name -Type $op.Type -Value $op.Value; $result.Added++;   Write-Log "SET $($op.Name) = $($op.Value)" 'OK' }
                'Change' { Set-PolicyRegistryValue -Path $op.Path -Name $op.Name -Type $op.Type -Value $op.Value; $result.Changed++; Write-Log "SET $($op.Name) = $($op.Value) (was $($op.Old))" 'OK' }
                'Clear'  { if (Remove-PolicyRegistryValue -Path $op.Path -Name $op.Name) { $result.Cleared++; Write-Log "CLEARED $($op.Name)" 'OK' } }
                'Keep'   { $result.Kept++ }
            }
        } catch {
            $result.Failures += "$($op.Name): $($_.Exception.Message)"
            Write-Log "FAIL $($op.Name): $_" 'ERR'
        }
    }
    foreach ($u in $Plan.UrlOps) {
        try {
            if (Test-Path -LiteralPath $u.Path) { Remove-Item -LiteralPath $u.Path -Recurse -Force -ErrorAction Stop }
            if ($u.Want.Count -gt 0) {
                New-Item -Path $u.Path -Force | Out-Null
                $i = 1
                foreach ($url in $u.Want) { New-ItemProperty -LiteralPath $u.Path -Name "$i" -Value $url -PropertyType String -Force | Out-Null; $i++ }
            }
            Write-Log "Startup URLs -> $($u.Want -join ', ')" 'OK'
        } catch {
            $result.Failures += "RestoreOnStartupURLs: $($_.Exception.Message)"
            Write-Log "FAIL RestoreOnStartupURLs: $_" 'ERR'
        }
    }
    foreach ($op in $Plan.System) {
        try {
            if ($op.Kind -eq 'Task') {
                Set-BfoTaskEnabled -TaskInfo $op.Info -Enabled ($op.Action -eq 'Enable')
            } else {
                if ($op.Action -eq 'Disable') { Set-BfoServiceStartType -Name $op.Name -StartType 'Disabled' -StopIfRunning }
                else { Set-BfoServiceStartType -Name $op.Name -StartType $(if ($op.Default) { $op.Default } else { 'Manual' }) }
            }
            $result.System++
            Write-Log "$($op.Action.ToUpper()) $($op.Kind.ToLower()) $($op.Name)" 'OK'
        } catch {
            $result.Failures += "$($op.Kind) $($op.Name): $($_.Exception.Message)"
            Write-Log "FAIL $($op.Kind) $($op.Name): $_" 'ERR'
        }
    }
    return $result
}

# ---- Restore -----------------------------------------------------------------
# Policy values in the key that this tool did not create (set by an administrator,
# another tool, or Brave itself). A restore must not delete them silently.
function Get-ForeignPolicyValues {
    $snap = Read-PolicySnapshot -Path $script:PolicyKeyPath
    $managed = Get-ManagedPolicyNames
    $foreign = @($snap.Values.Keys | Where-Object { $managed -notcontains $_ } | Sort-Object)
    $extraSub = @($snap.SubKeys | Where-Object { $_ -ne 'RestoreOnStartupURLs' } | Sort-Object)
    return [pscustomobject]@{ Values = $foreign; SubKeys = $extraSub; Count = ($foreign.Count + $extraSub.Count) }
}

function Invoke-FullRestore {
    param([bool]$RemoveForeign = $false)
    $failures = @()
    $path = $script:PolicyKeyPath
    try {
        if (-not (Test-Path -LiteralPath $path)) { Write-Log 'No Brave policy key found - nothing to remove.' 'INFO' }
        elseif ($RemoveForeign) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            Write-Log 'Removed the whole Brave policy key.' 'OK'
        } else {
            $snap = Read-PolicySnapshot -Path $path
            $managed = Get-ManagedPolicyNames
            foreach ($name in $snap.Values.Keys) {
                if ($managed -contains $name) { Remove-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop }
            }
            $urls = Join-Path $path 'RestoreOnStartupURLs'
            if (Test-Path -LiteralPath $urls) { Remove-Item -LiteralPath $urls -Recurse -Force -ErrorAction Stop }
            # An empty key adds nothing but the "managed" banner, so drop it.
            $left = Read-PolicySnapshot -Path $path
            if ($left.Values.Count -eq 0 -and $left.SubKeys.Count -eq 0) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
            Write-Log 'Removed this tool''s policies.' 'OK'
        }
    } catch {
        $failures += "policies: $($_.Exception.Message)"
        Write-Log "Restore policy remove: $_" 'ERR'
    }
    # Versions 1.5-1.12 also wrote per-channel keys that Brave never reads. They
    # do no harm, but a restore should leave nothing of ours behind.
    foreach ($legacy in $script:LegacyPolicyKeys) {
        $legacyPath = Get-PolicyHivePath $legacy
        try {
            if (Test-Path -LiteralPath $legacyPath) { Remove-Item -LiteralPath $legacyPath -Recurse -Force -ErrorAction Stop; Write-Log "Removed legacy key $legacy." 'OK' }
        } catch { $failures += "legacy $legacy : $($_.Exception.Message)"; Write-Log "Restore legacy key ${legacy}: $_" 'WARN' }
    }
    if (@(Get-HostsManagedDomains).Count -gt 0) {
        try { Set-HostsManagedDomains -Domains @(); Write-Log 'Hosts block removed.' 'OK' }
        catch { $failures += "hosts: $($_.Exception.Message)"; Write-Log "Restore hosts clear: $_" 'ERR' }
    }
    # Only undo what this tool could have done: re-enable updater pieces that
    # are currently disabled.
    foreach ($def in $script:UpdaterTaskDefs) {
        foreach ($t in (Find-BfoTasks -Pattern $def.Pattern -Refresh)) {
            if ($t.State -eq 'Disabled') {
                try { Set-BfoTaskEnabled -TaskInfo $t -Enabled $true; Write-Log "ENABLED task $($t.Name)" 'OK' }
                catch { $failures += "task $($t.Name): $($_.Exception.Message)"; Write-Log "Restore task $($t.Name): $_" 'WARN' }
            }
        }
    }
    $toReset = @()
    foreach ($def in $script:UpdaterServiceDefs) {
        foreach ($svc in (Find-BfoUpdaterServices -Id $def.Id)) { $toReset += [pscustomobject]@{ Name = $svc.Name; StartType = "$($svc.StartType)"; Default = $def.Default } }
    }
    foreach ($def in $script:RestoreOnlyServices) {
        $svc = Get-BfoService -Name $def.Name
        if ($svc) { $toReset += [pscustomobject]@{ Name = $def.Name; StartType = "$($svc.StartType)"; Default = $def.Default } }
    }
    foreach ($r in $toReset) {
        if ($r.StartType -ne 'Disabled') { continue }
        try { Set-BfoServiceStartType -Name $r.Name -StartType $r.Default; Write-Log "RESET service $($r.Name) to $($r.Default)" 'OK' }
        catch { $failures += "service $($r.Name): $($_.Exception.Message)"; Write-Log "Restore service $($r.Name): $_" 'WARN' }
    }
    return $failures
}

# ---- Presets -----------------------------------------------------------------
function Get-PresetSelection {
    param([string]$Preset)
    $sel = [pscustomobject]@{ Policies = @(); Hosts = @() }
    $code = $script:PresetCodes[$Preset]
    if ($code) {
        $sel.Policies = @($script:PolicyByName.Values | Where-Object { $_.Presets.Contains($code) } | ForEach-Object { $_.Name })
        if ($script:PresetHosts.ContainsKey($Preset)) { $sel.Hosts = @($script:PresetHosts[$Preset]) }
    }
    return $sel
}

# Presets set the policy and hosts ticks only. The updater tasks/services are
# never touched by a preset (disabling them stops security updates), and the
# search/new-tab/startup overrides are never touched either.
function Set-PresetChecks {
    param([string]$Preset)
    $sel = Get-PresetSelection -Preset $Preset
    foreach ($item in $script:Items) {
        if ($item.Kind -eq 'Policy') { Set-ItemChecked $item ($sel.Policies -contains $item.Id) }
        elseif ($item.Kind -eq 'Host') { Set-ItemChecked $item ($sel.Hosts -contains $item.Id) }
    }
    $script:ActiveProfile = $Preset
}

# ---- Config export / import ---------------------------------------------------
$script:ConfigSchema = 3
function New-ConfigObject {
    $cfg = [ordered]@{
        schemaVersion = $script:ConfigSchema
        appVersion    = $script:AppVersion
        exported      = (Get-Date -Format 's')
        profile       = $script:ActiveProfile
        policies      = [ordered]@{}
        policyValues  = [ordered]@{}
        tasks         = [ordered]@{}
        services      = [ordered]@{}
        hosts         = [ordered]@{}
        search  = [ordered]@{ enabled = [bool]$script:Overrides.Search.Enabled;  engineId = "$($script:Overrides.Search.EngineId)"; customUrl = "$($script:Overrides.Search.CustomUrl)" }
        ntp     = [ordered]@{ enabled = [bool]$script:Overrides.Ntp.Enabled;     destinationId = "$($script:Overrides.Ntp.DestinationId)"; customUrl = "$($script:Overrides.Ntp.CustomUrl)" }
        startup = [ordered]@{ enabled = [bool]$script:Overrides.Startup.Enabled; modeId = "$($script:Overrides.Startup.ModeId)"; urls = "$($script:Overrides.Startup.Urls)" }
    }
    foreach ($item in $script:Items) {
        switch ($item.Kind) {
            'Policy'  { $cfg.policies[$item.Id] = [bool]$item.Checked; if ($item.Def.Choices) { $cfg.policyValues[$item.Id] = $item.Value } }
            'Task'    { $cfg.tasks[$item.Id]    = [bool]$item.Checked }
            'Service' { $cfg.services[$item.Id] = [bool]$item.Checked }
            'Host'    { $cfg.hosts[$item.Id]    = [bool]$item.Checked }
        }
    }
    return $cfg
}

function ConvertTo-BoolStrict {
    param($Value)
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) { return ($Value.Trim().ToLowerInvariant() -in @('true', '1', 'yes')) }
    return [bool]$Value
}

# Applies a parsed config to the item list. Unknown names are skipped (a config
# from an older version may mention a policy that no longer exists) and counted.
function Import-ConfigObject {
    param($Cfg)
    $unknown = 0
    if ($Cfg.policies) {
        foreach ($p in $Cfg.policies.PSObject.Properties) {
            $item = Get-BfoItem 'Policy' $p.Name
            if ($item) { Set-ItemChecked $item (ConvertTo-BoolStrict $p.Value) } else { $unknown++ }
        }
    }
    if ($Cfg.policyValues) {
        foreach ($p in $Cfg.policyValues.PSObject.Properties) {
            $item = Get-BfoItem 'Policy' $p.Name
            if ($item -and $item.Def.Choices) {
                foreach ($cid in $item.Def.Choices.Keys) { if ("$($item.Def.Choices[$cid])" -eq "$($p.Value)") { Set-ItemChoice $item $cid; break } }
            }
        }
    }
    $legacyTasks = @{ 'BraveSoftwareUpdateTaskMachineCore' = 'core'; 'BraveSoftwareUpdateTaskMachineUA' = 'ua' }
    if ($Cfg.tasks) {
        foreach ($p in $Cfg.tasks.PSObject.Properties) {
            $id = if ($legacyTasks.ContainsKey($p.Name)) { $legacyTasks[$p.Name] } else { $p.Name }
            $item = Get-BfoItem 'Task' $id
            if ($item) { Set-ItemChecked $item (ConvertTo-BoolStrict $p.Value); $item.Loaded = $true } else { $unknown++ }
        }
    }
    if ($Cfg.services) {
        foreach ($p in $Cfg.services.PSObject.Properties) {
            $item = Get-BfoItem 'Service' $p.Name
            if ($item) { Set-ItemChecked $item (ConvertTo-BoolStrict $p.Value); $item.Loaded = $true } else { $unknown++ }
        }
    }
    if ($Cfg.hosts) {
        foreach ($p in $Cfg.hosts.PSObject.Properties) {
            $id = if ($script:LegacyHostsIds.ContainsKey($p.Name)) { $script:LegacyHostsIds[$p.Name] } else { $p.Name }
            $item = Get-BfoItem 'Host' $id
            if ($item) { Set-ItemChecked $item (ConvertTo-BoolStrict $p.Value) } else { $unknown++ }
        }
    }
    if ($Cfg.search) {
        $script:Overrides.Search.Enabled = ConvertTo-BoolStrict $Cfg.search.enabled
        $id = if ($Cfg.search.engineId) { "$($Cfg.search.engineId)" } elseif ($Cfg.search.engine -and $script:LegacySearchEngineIds.ContainsKey("$($Cfg.search.engine)")) { $script:LegacySearchEngineIds["$($Cfg.search.engine)"] } else { $null }
        if ($id -and $script:SearchEngines.Contains($id)) { $script:Overrides.Search.EngineId = $id }
        if ($Cfg.search.customUrl) { $script:Overrides.Search.CustomUrl = "$($Cfg.search.customUrl)" }
    }
    if ($Cfg.ntp) {
        $script:Overrides.Ntp.Enabled = ConvertTo-BoolStrict $Cfg.ntp.enabled
        $id = if ($Cfg.ntp.destinationId) { "$($Cfg.ntp.destinationId)" } elseif ($Cfg.ntp.destination -and $script:LegacyDestinationIds.ContainsKey("$($Cfg.ntp.destination)")) { $script:LegacyDestinationIds["$($Cfg.ntp.destination)"] } else { $null }
        if ($id -and $script:DestinationOptions.Contains($id) -and $id -ne 'ntpDefault') { $script:Overrides.Ntp.DestinationId = $id }
        if ($Cfg.ntp.customUrl) { $script:Overrides.Ntp.CustomUrl = "$($Cfg.ntp.customUrl)" }
    }
    if ($Cfg.startup) {
        $script:Overrides.Startup.Enabled = ConvertTo-BoolStrict $Cfg.startup.enabled
        $id = if ($Cfg.startup.modeId) { "$($Cfg.startup.modeId)" } elseif ($Cfg.startup.mode -and $script:LegacyStartupModeIds.ContainsKey("$($Cfg.startup.mode)")) { $script:LegacyStartupModeIds["$($Cfg.startup.mode)"] } else { $null }
        if ($id -and $script:StartupModes.Contains($id)) { $script:Overrides.Startup.ModeId = $id }
        if ($Cfg.startup.urls) { $script:Overrides.Startup.Urls = "$($Cfg.startup.urls)" }
    }
    $script:ActiveProfile = if ($Cfg.profile -and ($script:AllPresetKeys -contains "$($Cfg.profile)")) { "$($Cfg.profile)" } else { 'Custom' }
    return $unknown
}
#endregion


#region Model: item state, loading, reports ------------------------------------
function Set-ItemChecked {
    param($Item, [bool]$Checked)
    $Item.Checked = $Checked
    if ($Item.Row) { Update-ItemView $Item }
}

function Set-ItemChoice {
    param($Item, [string]$ChoiceId)
    if (-not $Item.Def.Choices -or -not $Item.Def.Choices.Contains($ChoiceId)) { return }
    $Item.Value = $Item.Def.Choices[$ChoiceId]
    if ($Item.Row) { Update-ItemView $Item }
}

function Get-ItemChoiceId {
    param($Item)
    if (-not $Item.Def.Choices) { return $null }
    foreach ($cid in $Item.Def.Choices.Keys) { if ("$($Item.Def.Choices[$cid])" -eq "$($Item.Value)") { return $cid } }
    return @($Item.Def.Choices.Keys)[0]
}

# Loads what is really configured on this PC into the ticks: a policy is ticked
# when its value in the registry is the one this tool would write.
function Import-CurrentPolicyState {
    $snap = Read-PolicySnapshot -Path $script:PolicyKeyPath
    $script:Snapshot = $snap
    foreach ($item in $script:Items) {
        if ($item.Kind -ne 'Policy') { continue }
        $has = $snap.Values.ContainsKey($item.Id)
        if ($item.Def.Choices) {
            if ($has) {
                foreach ($cid in $item.Def.Choices.Keys) { if ("$($item.Def.Choices[$cid])" -eq "$($snap.Values[$item.Id])") { $item.Value = $item.Def.Choices[$cid]; break } }
            }
            Set-ItemChecked $item $has
        } else {
            Set-ItemChecked $item ($has -and "$($snap.Values[$item.Id])" -eq "$($item.Def.Value)")
        }
    }

    # Overrides: ticked only when the registry holds a value that maps back to
    # one of the choices this tool offers (otherwise it is a foreign setting).
    $so = $script:Overrides
    $so.Search.Enabled = $false; $so.Ntp.Enabled = $false; $so.Startup.Enabled = $false
    if ($snap.Values['DefaultSearchProviderEnabled'] -eq 1 -and $snap.Values.ContainsKey('DefaultSearchProviderSearchURL')) {
        $url = "$($snap.Values['DefaultSearchProviderSearchURL'])"
        $so.Search.Enabled = $true
        $matched = $false
        foreach ($id in $script:SearchEngines.Keys) {
            if (-not $script:SearchEngines[$id].IsCustom -and $script:SearchEngines[$id].URL -eq $url) { $so.Search.EngineId = $id; $matched = $true; break }
        }
        if (-not $matched) { $so.Search.EngineId = 'custom'; $so.Search.CustomUrl = $url }
    }
    if ($snap.Values.ContainsKey('NewTabPageLocation')) {
        $so.Ntp.Enabled = $true
        $ntp = "$($snap.Values['NewTabPageLocation'])"
        $matched = $false
        foreach ($id in $script:DestinationIds) {
            if ($script:DestinationOptions[$id].Value -eq $ntp) { $so.Ntp.DestinationId = $id; $matched = $true; break }
        }
        if (-not $matched) { $so.Ntp.DestinationId = 'custom'; $so.Ntp.CustomUrl = $ntp }
    }
    if ($snap.Values.ContainsKey('RestoreOnStartup')) {
        $so.Startup.Enabled = $true
        $code = [int]$snap.Values['RestoreOnStartup']
        foreach ($id in $script:StartupModeIds) {
            $mode = $script:StartupModes[$id]
            if ($mode.Code -ne $code) { continue }
            # Code 4 covers both "blank page" and "specific pages": tell them apart by URL.
            if ($mode.FixedURL -and (@($snap.Urls).Count -ne 1 -or $snap.Urls[0] -ne $mode.FixedURL)) { continue }
            $so.Startup.ModeId = $id; break
        }
        if ($snap.Urls.Count -gt 0) { $so.Startup.Urls = ($snap.Urls -join ', ') }
    }
    Import-CurrentHostsState
    $script:ActiveProfile = 'CurrentState'
}

# The hosts file is read once and cached: row status is recomputed on every
# tick, and re-reading a system file for each row would be wasteful.
$script:HostsCurrent = @()
function Update-HostsCache { $script:HostsCurrent = @(Get-HostsManagedDomains) }

function Import-CurrentHostsState {
    Update-HostsCache
    $current = @($script:HostsCurrent)
    foreach ($item in $script:Items) {
        if ($item.Kind -ne 'Host') { continue }
        $all = $true
        foreach ($d in $item.Def.Domains) { if ($current -notcontains $d) { $all = $false; break } }
        Set-ItemChecked $item $all
    }
}

# Updater tasks and services are read on demand (enumerating scheduled tasks
# takes about a second) and remembered as the baseline: only rows the user
# changes afterwards take part in Apply.
function Import-CurrentSystemState {
    param([switch]$Refresh)
    foreach ($item in $script:Items) {
        if ($item.Kind -eq 'Task') {
            $found = @(Find-BfoTasks -Pattern $item.Def.Pattern -Refresh:$Refresh)
            $item.Detail = $found.Count
            $item.Baseline = ($found.Count -gt 0 -and @($found | Where-Object { $_.State -ne 'Disabled' }).Count -eq 0)
            $item.Loaded = $true
            Set-ItemChecked $item $item.Baseline
        } elseif ($item.Kind -eq 'Service') {
            $found = @(Find-BfoUpdaterServices -Id $item.Id)
            $item.Detail = $found.Count
            $item.Baseline = ($found.Count -gt 0 -and @($found | Where-Object { "$($_.StartType)" -ne 'Disabled' }).Count -eq 0)
            $item.Loaded = $true
            Set-ItemChecked $item $item.Baseline
        }
    }
}

# ---- Status of one row -------------------------------------------------------
# The vocabulary matches the Preview report, so a row and the report can never
# disagree: Active / Will apply / Will change / Will remove / Not set.
function Get-ItemState {
    param($Item)
    switch ($Item.Kind) {
        'Policy' {
            $snap = $script:Snapshot
            $has = ($snap -and $snap.Values.ContainsKey($Item.Id))
            if ($Item.Checked) {
                if (-not $has) { return 'willApply' }
                if ("$($snap.Values[$Item.Id])" -eq "$($Item.Value)" -and $snap.Kinds[$Item.Id] -eq $(if ($Item.Def.Type -eq 'DWORD') { 'DWord' } else { 'String' })) { return 'active' }
                return 'willChange'
            }
            if ($has) { return 'willRemove' }
            return 'notSet'
        }
        'Task' {
            if (-not $Item.Loaded) { return 'unknown' }
            if ($Item.Detail -eq 0) { return 'missing' }
            if ($Item.Checked -eq $Item.Baseline) { return $(if ($Item.Checked) { 'disabled' } else { 'enabled' }) }
            return $(if ($Item.Checked) { 'willDisable' } else { 'willEnable' })
        }
        'Service' {
            if (-not $Item.Loaded) { return 'unknown' }
            if ($Item.Detail -eq 0) { return 'missing' }
            if ($Item.Checked -eq $Item.Baseline) { return $(if ($Item.Checked) { 'disabled' } else { 'enabled' }) }
            return $(if ($Item.Checked) { 'willDisable' } else { 'willEnable' })
        }
        'Host' {
            $current = @($script:HostsCurrent)
            $all = $true; $any = $false
            foreach ($d in $Item.Def.Domains) { if ($current -contains $d) { $any = $true } else { $all = $false } }
            if ($Item.Checked) { return $(if ($all) { 'blocked' } else { 'willBlock' }) }
            return $(if ($any) { 'willUnblock' } else { 'notBlocked' })
        }
    }
    return 'unknown'
}

# ---- Reports (English on purpose: they get pasted into bug reports) ----------
function New-ApplyPlanReport {
    param($Plan)
    $r = New-Object System.Text.StringBuilder
    $mode = if ($script:ActiveProfile) { $script:ActiveProfile } else { 'Custom' }
    [void]$r.AppendLine("Brave Free Origin v$($script:AppVersion) apply preview")
    [void]$r.AppendLine("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$r.AppendLine("Mode: $(TEn "preset.$mode.name")")
    [void]$r.AppendLine("Policy key: $($script:PolicyKeyPath)  (shared by every Brave channel)")
    [void]$r.AppendLine('')
    [void]$r.AppendLine('This is a dry run. Nothing has been written.')
    [void]$r.AppendLine('')
    foreach ($op in $Plan.Registry) {
        switch ($op.Action) {
            'Add'    { [void]$r.AppendLine("  ADD    $($op.Name) = $($op.Value)") }
            'Change' { [void]$r.AppendLine("  CHANGE $($op.Name) : $($op.Old) -> $($op.Value)") }
            'Keep'   { [void]$r.AppendLine("  KEEP   $($op.Name) = $($op.Value)") }
            'Clear'  {
                $note = if ($script:LegacyPolicyNames -contains $op.Name) { '  - leftover from an older version of this tool' } else { '' }
                [void]$r.AppendLine("  CLEAR  $($op.Name) (currently $($op.Old))$note")
            }
        }
    }
    foreach ($u in $Plan.UrlOps) {
        if ($u.Want.Count -gt 0) { [void]$r.AppendLine("  REPLACE RestoreOnStartupURLs with $($u.Want.Count) URL(s): $($u.Want -join ', ')") }
        else { [void]$r.AppendLine("  CLEAR  RestoreOnStartupURLs ($($u.Have.Count) URL(s))") }
    }
    [void]$r.AppendLine("  Summary: $($Plan.Counts.Add) add, $($Plan.Counts.Change) change, $($Plan.Counts.Clear) clear, $($Plan.Counts.Keep) already correct")
    [void]$r.AppendLine('')
    [void]$r.AppendLine('=== Updater tasks and services ===')
    if ($Plan.System.Count -eq 0) { [void]$r.AppendLine('  No change requested.') }
    foreach ($op in $Plan.System) { [void]$r.AppendLine("  $($op.Action.ToUpper().PadRight(8)) $($op.Kind.ToLower()) $($op.Name)") }
    [void]$r.AppendLine('')
    [void]$r.AppendLine('=== Hosts blocklist ===')
    [void]$r.AppendLine('Apply does not edit hosts. Use Preview hosts / Apply hosts blocks on the Hosts page.')
    return $r.ToString()
}

function New-HostsPlanReport {
    $desired = @(Get-SelectedHostsDomains)
    $current = @(Get-HostsManagedDomains)
    $r = New-Object System.Text.StringBuilder
    [void]$r.AppendLine('Brave Free Origin hosts preview')
    [void]$r.AppendLine("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$r.AppendLine("File: $($script:HostsFile)")
    [void]$r.AppendLine('')
    [void]$r.AppendLine("Current managed domains: $($current.Count)")
    [void]$r.AppendLine("Desired managed domains: $($desired.Count)")
    [void]$r.AppendLine('')
    $add = @($desired | Where-Object { $current -notcontains $_ })
    $keep = @($desired | Where-Object { $current -contains $_ })
    $remove = @($current | Where-Object { $desired -notcontains $_ })
    [void]$r.AppendLine("Add: $($add.Count)");                            foreach ($d in $add)    { [void]$r.AppendLine("  + $d") }
    [void]$r.AppendLine("Keep: $($keep.Count)");                          foreach ($d in $keep)   { [void]$r.AppendLine("  = $d") }
    [void]$r.AppendLine("Remove from managed block: $($remove.Count)");  foreach ($d in $remove) { [void]$r.AppendLine("  - $d") }
    [void]$r.AppendLine('')
    [void]$r.AppendLine('No other hosts entries are touched. Only the Brave-Free-Origin sentinel block is replaced.')
    return $r.ToString()
}

function Get-SelectedHostsDomains {
    $domains = @()
    foreach ($item in $script:Items) { if ($item.Kind -eq 'Host' -and $item.Checked) { $domains += $item.Def.Domains } }
    return @($domains | Sort-Object -Unique)
}

function New-VerifyReport {
    $r = New-Object System.Text.StringBuilder
    [void]$r.AppendLine("Brave Free Origin v$($script:AppVersion) verify report")
    [void]$r.AppendLine("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$r.AppendLine("Policy catalog checked against Brave $($script:CatalogBrave) on $($script:CatalogDate)")
    foreach ($ch in (Get-DetectedChannels)) {
        $info = Get-BraveInfo -Channel $ch
        [void]$r.AppendLine("Installed: $ch $($info.Version) ($($info.Scope) install)")
    }
    [void]$r.AppendLine('')
    [void]$r.AppendLine("=== $($script:PolicyKeyPath) ===")
    $snap = Read-PolicySnapshot -Path $script:PolicyKeyPath
    if (-not $snap.Exists) {
        [void]$r.AppendLine('  (no policy key exists - nothing applied)')
    } else {
        $ok = 0; $missing = @(); $wrong = @(); $ticked = 0
        foreach ($item in $script:Items) {
            if ($item.Kind -ne 'Policy' -or -not $item.Checked) { continue }
            $ticked++
            if (-not $snap.Values.ContainsKey($item.Id)) { $missing += $item.Id; continue }
            if ("$($snap.Values[$item.Id])" -eq "$($item.Value)") { $ok++ }
            else { $wrong += "$($item.Id): registry=$($snap.Values[$item.Id]), expected=$($item.Value)" }
        }
        [void]$r.AppendLine("  Ticked in UI: $ticked")
        [void]$r.AppendLine("  Match in registry: $ok")
        [void]$r.AppendLine("  Missing (not in registry): $($missing.Count)")
        [void]$r.AppendLine("  Mismatch (wrong value): $($wrong.Count)")
        if ($missing.Count) { [void]$r.AppendLine('  -- missing:'); foreach ($n in $missing) { [void]$r.AppendLine("     - $n") } }
        if ($wrong.Count)   { [void]$r.AppendLine('  -- mismatch:'); foreach ($n in $wrong) { [void]$r.AppendLine("     - $n") } }
        $leftovers = @($snap.Values.Keys | Where-Object { $script:LegacyPolicyNames -contains $_ } | Sort-Object)
        if ($leftovers.Count -gt 0) {
            [void]$r.AppendLine("  Leftovers from older versions of this tool: $($leftovers.Count) (Apply or Restore stock removes them)")
            foreach ($n in $leftovers) { [void]$r.AppendLine("     - $n") }
        }
        $foreign = Get-ForeignPolicyValues
        if ($foreign.Count -gt 0) {
            [void]$r.AppendLine("  Other Brave policies present that this tool does not manage: $($foreign.Count)")
            foreach ($n in $foreign.Values) { [void]$r.AppendLine("     - $n") }
            foreach ($n in $foreign.SubKeys) { [void]$r.AppendLine("     - (subkey) $n") }
        }
        if ($snap.Values.ContainsKey('DefaultSearchProviderEnabled') -and $snap.Values['DefaultSearchProviderEnabled'] -eq 1) {
            [void]$r.AppendLine("  Search engine forced: $($snap.Values['DefaultSearchProviderName']) ($($snap.Values['DefaultSearchProviderSearchURL']))")
        }
        if ($snap.Values.ContainsKey('NewTabPageLocation')) { [void]$r.AppendLine("  New tab page forced: $($snap.Values['NewTabPageLocation'])") }
        if ($snap.Values.ContainsKey('RestoreOnStartup')) {
            $extra = if ($snap.Urls.Count -gt 0) { " URLs: $($snap.Urls -join ', ')" } else { '' }
            [void]$r.AppendLine("  Startup forced: code $($snap.Values['RestoreOnStartup'])$extra")
        }
    }
    foreach ($legacy in $script:LegacyPolicyKeys) {
        if (Test-Path -LiteralPath (Get-PolicyHivePath $legacy)) {
            [void]$r.AppendLine("  Note: legacy key $legacy exists (written by Brave Free Origin 1.5-1.12; Brave does not read it).")
        }
    }
    $hosts = @(Get-HostsManagedDomains)
    [void]$r.AppendLine('')
    [void]$r.AppendLine('=== Hosts blocklist ===')
    [void]$r.AppendLine("  Currently blocked domains: $($hosts.Count)")
    foreach ($d in $hosts) { [void]$r.AppendLine("     - $d") }
    return $r.ToString()
}
#endregion


#region Scriptlets: logic ---------------------------------------------------------------
# State for the optional expert tool. The UI lives in the Scriptlets page; this is
# the scanner, the renderer and the rule editing, which the page only calls.
$script:ScriptletDisablePrefix = '! BFO disabled: '
$script:ScriptletRules = @()
$script:ScriptletVisibleRules = @()
$script:ScriptletScanState = $null
$script:ScriptletScanTimer = $null
$script:ScriptletRenderState = $null
$script:ScriptletRenderTimer = $null
$script:ScriptletFilterTimer = $null
$script:ScriptletCheckedKeys = @{}
$script:SuppressScriptletStatusEvents = $false
$script:ScriptletComponentNames = @{
    'iodkpdagapdfkphljnddpjlldadblomo' = 'uBlock filters'
    'adcocjohghhfpidemphmcmlmhnfgikei' = 'Brave Firstparty specific filters'
    'cdbbhgbmjhfnhnmgeddbliobbofkgdhe' = 'EasyList Cookie'
    'kihnoaefogbkmblfimmibknnmkllbhlf' = 'EasyPrivacy'
    'flnkmpokemfpaajmiimmjeiandgoodgg' = 'AdGuard French'
}

function Get-ScriptletDefaultRoot {
    return $script:BraveInstalls[(Get-PrimaryChannel)].UserDataRoot
}

# Brave's filter-list files are LF text. Rewriting them line by line with the
# .NET default would convert every line to CRLF on Windows, so the original
# newline style and trailing newline are kept, and a file is only written when a
# rule actually changed.
function Read-ListFileLines {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [regex]::Split($text, "
|
")
    $trailing = $text.EndsWith("`n")
    if ($trailing -and $lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        $lines = if ($lines.Count -gt 1) { $lines[0..($lines.Count - 2)] } else { @() }
    }
    return [pscustomobject]@{ Lines = [string[]]$lines; Newline = $newline; TrailingNewline = $trailing }
}

function Write-ListFileLines {
    param([string]$Path, $Data, [string[]]$Lines)
    $text = $Lines -join $Data.Newline
    if ($Data.TrailingNewline) { $text += $Data.Newline }
    [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ScriptletComponentInfo {
    param([string]$File, [string]$Root)

    $componentId = 'unknown'
    $version = 'unknown'
    $source = 'Unknown filter list'
    try {
        $full = [System.IO.Path]::GetFullPath($File)
        $base = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
        if ($full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relative = $full.Substring($base.Length)
            $parts = $relative -split '[\\/]'
            if ($parts.Count -ge 1) { $componentId = $parts[0] }
            if ($parts.Count -ge 2) { $version = $parts[1] }
        }
        if ($script:ScriptletComponentNames.ContainsKey($componentId)) {
            $source = $script:ScriptletComponentNames[$componentId]
        } elseif ($componentId -ne 'unknown') {
            $source = $componentId
        }
    } catch {}

    return [pscustomobject]@{
        ComponentId = $componentId
        Version     = $version
        Source      = $source
    }
}

function Get-BfoDisabledScriptletRule {
    param([string]$Line)
    if ($Line -match '^\s*!\s*BFO disabled:\s*(?<rule>.+)$') {
        return $Matches.rule.Trim()
    }
    return $null
}

function Get-ScriptletRuleFromLine {
    param([string]$Line)
    $disabled = Get-BfoDisabledScriptletRule -Line $Line
    if ($disabled) { return $disabled }

    $trimmed = $Line.Trim()
    if ($trimmed.StartsWith('!')) { return $null }
    return $trimmed
}

function ConvertTo-ScriptletRecord {
    param(
        [string]$File,
        [string]$Root,
        [string]$Line,
        [int]$LineNumber
    )

    $disabledRule = Get-BfoDisabledScriptletRule -Line $Line
    $enabled = -not [bool]$disabledRule
    $rule = if ($disabledRule) { $disabledRule } else { $Line.Trim() }
    if ([string]::IsNullOrWhiteSpace($rule)) { return $null }
    if ($rule.StartsWith('!')) { return $null }
    if ($rule -notmatch '##\+js\((?<body>.*)\)') { return $null }

    $marker = $rule.IndexOf('##+js(', [System.StringComparison]::Ordinal)
    if ($marker -lt 0) { return $null }
    $domain = $rule.Substring(0, $marker)
    $body = $Matches.body
    $scriptlet = $body
    $arguments = ''
    $comma = $body.IndexOf(',')
    if ($comma -ge 0) {
        $scriptlet = $body.Substring(0, $comma).Trim()
        $arguments = $body.Substring($comma + 1).Trim()
    } else {
        $scriptlet = $body.Trim()
    }

    $info = Get-ScriptletComponentInfo -File $File -Root $Root
    return [pscustomobject]@{
        Enabled     = $enabled
        Domain      = $domain
        Scriptlet   = $scriptlet
        Arguments   = $arguments
        Source      = $info.Source
        ComponentId = $info.ComponentId
        Version     = $info.Version
        File        = $File
        LineNumber  = $LineNumber
        Rule        = $rule
    }
}

function Get-ScriptletListFiles {
    param(
        [string]$Root,
        [System.Collections.IList]$Warnings = $null
    )

    if ([string]::IsNullOrWhiteSpace($Root)) { throw 'User Data folder is empty.' }
    if (-not (Test-Path $Root)) { throw "User Data folder not found: $Root" }

    $files = @()
    $componentDirs = @(Get-ChildItem -Path $Root -Directory -ErrorAction Stop | Where-Object { $_.Name -match '^[a-z]{32}$' })
    foreach ($dir in $componentDirs) {
        try {
            $files += Get-ChildItem -Path $dir.FullName -Recurse -Filter 'list.txt' -File -ErrorAction Stop
        } catch {
            $warning = "Scriptlet scan skipped $($dir.FullName): $_"
            if ($Warnings) { [void]$Warnings.Add($warning) } else { Write-Log $warning 'WARN' }
        }
    }
    return @($files | Sort-Object FullName)
}

function Backup-ScriptletFile {
    param([string]$File)

    if (-not (Test-Path $File)) { throw "Scriptlet list file not found: $File" }
    $backup = "$File.bfo-backup"
    if (-not (Test-Path $backup)) {
        Copy-Item -LiteralPath $File -Destination $backup -Force
        Write-Log "Scriptlet backup created: $backup" 'OK'
    }
    return $backup
}

function Test-ScriptletAdvancedWriteAllowed {
    if (-not $script:ChkScriptletAdvanced -or -not $script:ChkScriptletAdvanced.Checked) {
        [void](Show-Message -Text (T 'msg.scriptlet.locked') -Title (T 'msg.title.scriptlet') -Buttons 'OK' -Icon 'Warning')
        return $false
    }

    $braveProcesses = @(Get-Process -Name brave -ErrorAction SilentlyContinue)
    if ($braveProcesses.Count -gt 0) {
        $ans = Show-Message -Text (T 'msg.scriptlet.braveRunning' @($braveProcesses.Count)) -Title (T 'msg.title.scriptlet') -Buttons 'YesNo' -Icon 'Warning'
        if ($ans -ne 'Yes') { return $false }
    }

    return $true
}

function Set-ScriptletRuleState {
    param(
        [object[]]$Records,
        [bool]$Enable,
        [bool]$AffectDuplicates
    )

    if (-not $Records -or $Records.Count -eq 0) { return 0 }
    $changed = 0
    $byFile = $Records | Group-Object File

    foreach ($group in $byFile) {
        $file = $group.Name
        [void](Backup-ScriptletFile -File $file)
        $data = Read-ListFileLines -Path $file
        $lines = $data.Lines
        $before = $changed

        if ($AffectDuplicates) {
            $wanted = @{}
            foreach ($record in $group.Group) { $wanted[$record.Rule] = $true }
            for ($i = 0; $i -lt $lines.Length; $i++) {
                $original = Get-ScriptletRuleFromLine -Line $lines[$i]
                if (-not $original -or -not $wanted.ContainsKey($original)) { continue }

                $disabledRule = Get-BfoDisabledScriptletRule -Line $lines[$i]
                if ($Enable -and $disabledRule) {
                    $lines[$i] = $disabledRule
                    $changed++
                } elseif (-not $Enable -and -not $disabledRule) {
                    $lines[$i] = "$($script:ScriptletDisablePrefix)$original"
                    $changed++
                }
            }
        } else {
            foreach ($record in $group.Group) {
                $idx = [int]$record.LineNumber - 1
                if ($idx -lt 0 -or $idx -ge $lines.Length) { continue }
                $original = Get-ScriptletRuleFromLine -Line $lines[$idx]
                if ($original -ne $record.Rule) { continue }

                $disabledRule = Get-BfoDisabledScriptletRule -Line $lines[$idx]
                if ($Enable -and $disabledRule) {
                    $lines[$idx] = $disabledRule
                    $changed++
                } elseif (-not $Enable -and -not $disabledRule) {
                    $lines[$idx] = "$($script:ScriptletDisablePrefix)$original"
                    $changed++
                }
            }
        }

        if ($changed -gt $before) { Write-ListFileLines -Path $file -Data $data -Lines $lines }
    }

    return $changed
}

function Restore-ScriptletBackup {
    param([string]$File)

    $backup = "$File.bfo-backup"
    if (-not (Test-Path $backup)) { throw "No backup exists for: $File" }
    Copy-Item -LiteralPath $backup -Destination $File -Force
}

function Restore-AllScriptletBackups {
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-Path $Root)) { throw "User Data folder not found: $Root" }
    $backups = @(Get-ChildItem -Path $Root -Recurse -Filter 'list.txt.bfo-backup' -File -ErrorAction SilentlyContinue)
    $count = 0
    foreach ($backup in $backups) {
        $target = $backup.FullName.Substring(0, $backup.FullName.Length - '.bfo-backup'.Length)
        Copy-Item -LiteralPath $backup.FullName -Destination $target -Force
        $count++
    }
    return $count
}

function Export-ScriptletDisabledPreferences {
    param([string]$File)

    $disabled = @($script:ScriptletRules | Where-Object { -not $_.Enabled } | Sort-Object Rule -Unique)
    $payload = [ordered]@{
        version       = '1.9'
        exported      = (Get-Date -Format 's')
        disabledRules = @(
            foreach ($r in $disabled) {
                [ordered]@{
                    rule      = $r.Rule
                    domain    = $r.Domain
                    scriptlet = $r.Scriptlet
                    source    = $r.Source
                }
            }
        )
    }
    [System.IO.File]::WriteAllText($File, ($payload | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    return $disabled.Count
}

function Import-ScriptletPreferencesAndReapply {
    param([string]$PrefsFile, [string]$Root)

    if (-not (Test-Path $PrefsFile)) { throw "Preference file not found: $PrefsFile" }
    $prefs = [System.IO.File]::ReadAllText($PrefsFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not $prefs.disabledRules) { throw 'Preference file has no disabledRules array.' }

    $wanted = @{}
    foreach ($entry in $prefs.disabledRules) {
        if ($entry.rule) { $wanted["$($entry.rule)"] = $true }
    }
    if ($wanted.Count -eq 0) { return 0 }

    $changed = 0
    foreach ($file in (Get-ScriptletListFiles -Root $Root)) {
        $data = Read-ListFileLines -Path $file.FullName
        $lines = $data.Lines
        $fileChanged = $false
        for ($i = 0; $i -lt $lines.Length; $i++) {
            $original = Get-ScriptletRuleFromLine -Line $lines[$i]
            if (-not $original -or -not $wanted.ContainsKey($original)) { continue }
            if (Get-BfoDisabledScriptletRule -Line $lines[$i]) { continue }
            if (-not $fileChanged) {
                [void](Backup-ScriptletFile -File $file.FullName)
                $fileChanged = $true
            }
            $lines[$i] = "$($script:ScriptletDisablePrefix)$original"
            $changed++
        }
        if ($fileChanged) {
            Write-ListFileLines -Path $file.FullName -Data $data -Lines $lines
        }
    }
    return $changed
}

function Resize-ScriptletColumns {
    if (-not $script:ScriptletList) { return }
    if ($script:ScriptletList.Columns.Count -lt 7) { return }

    $width = [Math]::Max(760, $script:ScriptletList.ClientSize.Width - 10)
    $pickWidth = 92
    $lineWidth = 55
    $flex = [Math]::Max(600, $width - $pickWidth - $lineWidth)
    $domainWidth = [Math]::Max(105, [int]($flex * 0.16))
    $scriptletWidth = [Math]::Max(115, [int]($flex * 0.17))
    $argsWidth = [Math]::Max(145, [int]($flex * 0.22))
    $sourceWidth = [Math]::Max(125, [int]($flex * 0.15))
    $rawWidth = [Math]::Max(170, $width - ($pickWidth + $domainWidth + $scriptletWidth + $argsWidth + $sourceWidth + $lineWidth + 4))

    $script:ScriptletList.Columns[0].Width = $pickWidth
    $script:ScriptletList.Columns[1].Width = $domainWidth
    $script:ScriptletList.Columns[2].Width = $scriptletWidth
    $script:ScriptletList.Columns[3].Width = $argsWidth
    $script:ScriptletList.Columns[4].Width = $sourceWidth
    $script:ScriptletList.Columns[5].Width = $lineWidth
    $script:ScriptletList.Columns[6].Width = $rawWidth
}

function Update-ScriptletStatusText {
    param([int]$Shown = -1)

    if (-not $script:LblScriptletStatus) { return }
    if ($Shown -lt 0) { $Shown = @($script:ScriptletVisibleRules).Count }

    $enabled = @($script:ScriptletRules | Where-Object { $_.Enabled }).Count
    $disabled = @($script:ScriptletRules | Where-Object { -not $_.Enabled }).Count
    $checked = $script:ScriptletCheckedKeys.Count
    $script:LblScriptletStatus.Text = T 'scriptlet.statusShowing' @($Shown, $script:ScriptletRules.Count, $enabled, $disabled, $checked)
}

# The scriptlet tab keeps live text outside the binding table: the ListView
# column headers, the per-row Enabled/Disabled cell and the status line are
# all written imperatively as the scan/render progresses. A language switch
# therefore has to re-text them explicitly, in place, without re-scanning.
function Update-ScriptletLocalizedText {
    if ($script:ScriptletList -and $script:ScriptletList.Columns.Count -ge 7) {
        $headerKeys = @(
            'scriptlet.col.pick', 'scriptlet.col.domain', 'scriptlet.col.scriptlet',
            'scriptlet.col.arguments', 'scriptlet.col.source', 'scriptlet.col.line',
            'scriptlet.col.rawRule'
        )
        for ($i = 0; $i -lt $headerKeys.Count; $i++) {
            $script:ScriptletList.Columns[$i].Text = T $headerKeys[$i]
        }
    }
    if ($script:ScriptletList -and $script:ScriptletList.Items.Count -gt 0) {
        $script:SuppressScriptletStatusEvents = $true
        $script:ScriptletList.BeginUpdate()
        try {
            foreach ($item in $script:ScriptletList.Items) {
                if (-not $item.Tag) { continue }
                $item.Text = if ($item.Tag.Enabled) { T 'scriptlet.state.enabled' } else { T 'scriptlet.state.disabled' }
            }
        } finally {
            $script:ScriptletList.EndUpdate()
            $script:SuppressScriptletStatusEvents = $false
        }
    }
    # Only refresh the counter line if a scan has actually produced rules;
    # otherwise the binding table's idle prompt is the correct text.
    if (@($script:ScriptletRules).Count -gt 0) { Update-ScriptletStatusText }
}

function Set-ScriptletUiBusy {
    param([bool]$Busy, [string]$Message = '')

    foreach ($control in @(
        $script:BtnScriptletScan,
        $script:BtnScriptletFilter,
        $script:BtnScriptletDisable,
        $script:BtnScriptletEnable,
        $script:BtnScriptletCheckVisible,
        $script:BtnScriptletClearChecks,
        $script:BtnScriptletImportPrefs
    )) {
        if ($control) { $control.Enabled = -not $Busy }
    }

    if ($script:LblScriptletStatus -and $Message) { $script:LblScriptletStatus.Text = $Message }
    if ($script:Form) { $script:Form.UseWaitCursor = $Busy }
    [System.Windows.Forms.Application]::DoEvents()
}

function Start-ScriptletFilterDelay {
    if ($script:ScriptletFilterTimer) {
        $script:ScriptletFilterTimer.Stop()
        $script:ScriptletFilterTimer.Start()
    } else {
        Update-ScriptletListView
    }
}

function Get-ScriptletRecordKey {
    param([object]$Record)

    if (-not $Record) { return $null }
    return ('{0}`t{1}' -f [string]$Record.File, [int]$Record.LineNumber)
}

function Test-ScriptletRecordChecked {
    param([object]$Record)

    $key = Get-ScriptletRecordKey -Record $Record
    return ($key -and $script:ScriptletCheckedKeys.ContainsKey($key))
}

function Set-ScriptletRecordChecked {
    param(
        [object]$Record,
        [bool]$Checked
    )

    $key = Get-ScriptletRecordKey -Record $Record
    if (-not $key) { return }

    if ($Checked) {
        $script:ScriptletCheckedKeys[$key] = $true
    } else {
        [void]$script:ScriptletCheckedKeys.Remove($key)
    }
}

function New-ScriptletListItem {
    param([object]$Record)

    $stateText = if ($Record.Enabled) { T 'scriptlet.state.enabled' } else { T 'scriptlet.state.disabled' }
    $item = New-Object System.Windows.Forms.ListViewItem($stateText)
    [void]$item.SubItems.Add($Record.Domain)
    [void]$item.SubItems.Add($Record.Scriptlet)
    [void]$item.SubItems.Add($Record.Arguments)
    [void]$item.SubItems.Add("$($Record.Source) $($Record.Version)")
    [void]$item.SubItems.Add([string]$Record.LineNumber)
    [void]$item.SubItems.Add($Record.Rule)
    $item.Tag = $Record
    $item.Checked = Test-ScriptletRecordChecked -Record $Record
    if (-not $Record.Enabled) {
        $item.ForeColor = [System.Drawing.Color]::FromArgb(150, 60, 60)
    }
    return $item
}

function Stop-ScriptletRender {
    if ($script:ScriptletRenderTimer) { $script:ScriptletRenderTimer.Stop() }
    $script:ScriptletRenderState = $null
    $script:SuppressScriptletStatusEvents = $false
}

function Start-ScriptletRender {
    param([object[]]$Rows)

    if (-not $script:ScriptletList) { return }
    Stop-ScriptletRender
    Set-ScriptletUiBusy $true (T 'scriptlet.statusRender0' @($Rows.Count))
    Resize-ScriptletColumns

    $script:SuppressScriptletStatusEvents = $true
    $script:ScriptletList.BeginUpdate()
    try {
        $script:ScriptletList.Items.Clear()
    } finally {
        $script:ScriptletList.EndUpdate()
    }

    $script:ScriptletRenderState = [pscustomobject]@{
        Rows      = @($Rows)
        Index     = 0
        Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    }

    if ($script:ScriptletProgress) {
        $script:ScriptletProgress.Visible = $true
        $script:ScriptletProgress.Style = 'Continuous'
        $script:ScriptletProgress.Value = 0
    }
    if ($script:LblScriptletStatus) {
        $script:LblScriptletStatus.Text = T 'scriptlet.statusRender0' @($Rows.Count)
    }

    if ($Rows.Count -eq 0) {
        Stop-ScriptletRender
        if ($script:ScriptletProgress) { $script:ScriptletProgress.Value = 0 }
        Update-ScriptletStatusText -Shown 0
        Set-ScriptletUiBusy $false
        return
    }

    if (-not $script:ScriptletRenderTimer) {
        $script:ScriptletRenderTimer = New-Object System.Windows.Forms.Timer
        $script:ScriptletRenderTimer.Interval = 10
        $script:ScriptletRenderTimer.Add_Tick({ Step-ScriptletRender })
    }
    $script:ScriptletRenderTimer.Start()
}

function Step-ScriptletRender {
    $state = $script:ScriptletRenderState
    if (-not $state) {
        Stop-ScriptletRender
        return
    }

    $total = $state.Rows.Count
    if ($total -eq 0) {
        Stop-ScriptletRender
        Update-ScriptletStatusText -Shown 0
        return
    }

    $startTick = [Environment]::TickCount64
    $batch = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
    while ($state.Index -lt $total -and (([Environment]::TickCount64 - $startTick) -lt 25) -and $batch.Count -lt 400) {
        [void]$batch.Add((New-ScriptletListItem -Record $state.Rows[$state.Index]))
        $state.Index++
    }

    if ($batch.Count -gt 0) {
        $items = $batch.ToArray()
        $script:ScriptletList.BeginUpdate()
        try {
            $script:ScriptletList.Items.AddRange($items)
        } finally {
            $script:ScriptletList.EndUpdate()
        }
    }

    $percent = [int](($state.Index * 1000L) / [Math]::Max(1, $total))
    $percent = [Math]::Max(0, [Math]::Min(1000, $percent))
    if ($script:ScriptletProgress) { $script:ScriptletProgress.Value = $percent }
    if ($script:LblScriptletStatus) {
        $seconds = [Math]::Round($state.Stopwatch.Elapsed.TotalSeconds, 1)
        $script:LblScriptletStatus.Text = T 'scriptlet.statusRendering' @($state.Index, $total, $seconds)
    }

    if ($state.Index -ge $total) {
        $elapsed = [Math]::Round($state.Stopwatch.Elapsed.TotalSeconds, 1)
        Stop-ScriptletRender
        if ($script:ScriptletProgress) { $script:ScriptletProgress.Value = 1000 }
        Update-ScriptletStatusText -Shown $total
        if ($script:LblScriptletStatus) {
            $script:LblScriptletStatus.Text += (T 'scriptlet.renderDone' @($elapsed))
        }
        Set-ScriptletUiBusy $false
    }
}

function Update-ScriptletListView {
    if (-not $script:ScriptletList) { return }

    $query = if ($script:TxtScriptletSearch) { $script:TxtScriptletSearch.Text.Trim() } else { '' }
    $disabledOnly = ($script:ChkScriptletDisabledOnly -and $script:ChkScriptletDisabledOnly.Checked)
    $rows = @($script:ScriptletRules)
    if ($disabledOnly) { $rows = @($rows | Where-Object { -not $_.Enabled }) }
    if (-not [string]::IsNullOrWhiteSpace($query)) {
        $needle = $query.ToLowerInvariant()
        $rows = @($rows | Where-Object {
            ("$($_.Domain) $($_.Scriptlet) $($_.Arguments) $($_.Source) $($_.Rule) $($_.File)").ToLowerInvariant().Contains($needle)
        })
    }

    $script:ScriptletVisibleRules = $rows
    Start-ScriptletRender -Rows $rows
}

function Get-SelectedScriptletRecords {
    if (-not $script:ScriptletList) { return @() }
    $records = @()

    if ($script:ScriptletCheckedKeys.Count -gt 0) {
        foreach ($record in $script:ScriptletRules) {
            if (Test-ScriptletRecordChecked -Record $record) { $records += $record }
        }
        return $records
    }

    foreach ($item in $script:ScriptletList.SelectedItems) {
        if ($item.Tag) { $records += $item.Tag }
    }
    return $records
}

function Set-ScriptletVisibleChecks {
    param([bool]$Checked)

    if (-not $script:ScriptletList) { return }
    if ($Checked) {
        foreach ($record in $script:ScriptletVisibleRules) {
            Set-ScriptletRecordChecked -Record $record -Checked $true
        }
    } else {
        $script:ScriptletCheckedKeys.Clear()
    }

    $script:SuppressScriptletStatusEvents = $true
    $script:ScriptletList.BeginUpdate()
    try {
        foreach ($item in $script:ScriptletList.Items) {
            $item.Checked = Test-ScriptletRecordChecked -Record $item.Tag
        }
    } finally {
        $script:ScriptletList.EndUpdate()
        $script:SuppressScriptletStatusEvents = $false
    }
    Update-ScriptletStatusText
}

function Update-ScriptletScanProgress {
    param([string]$Message = '')

    $state = $script:ScriptletScanState
    if (-not $state) { return }

    $currentBytes = 0L
    if ($state.Reader -and $state.Reader.BaseStream) {
        try { $currentBytes = [int64]$state.Reader.BaseStream.Position } catch { $currentBytes = 0L }
    }
    $doneBytes = [Math]::Min([int64]$state.TotalBytes, [int64]($state.ProcessedBytes + $currentBytes))
    $percent = if ($state.TotalBytes -gt 0) { [int](($doneBytes * 1000L) / $state.TotalBytes) } else { 0 }
    $percent = [Math]::Max(0, [Math]::Min(1000, $percent))

    if ($script:ScriptletProgress) {
        $script:ScriptletProgress.Visible = $true
        $script:ScriptletProgress.Style = 'Continuous'
        $script:ScriptletProgress.Value = $percent
    }

    if ($script:LblScriptletStatus) {
        if ([string]::IsNullOrWhiteSpace($Message)) {
            $fileName = if ($state.CurrentFile) { Split-Path $state.CurrentFile.FullName -Leaf } else { T 'scriptlet.statusStarting' }
            $seconds = [Math]::Max(1, [int]$state.Stopwatch.Elapsed.TotalSeconds)
            $Message = T 'scriptlet.statusScanning' @(
                $state.FileIndex, $state.Files.Count, $fileName,
                $state.Records.Count, [int]($percent / 10), $seconds)
        }
        $script:LblScriptletStatus.Text = $Message
    }
}

function Stop-ScriptletScan {
    if ($script:ScriptletScanTimer) { $script:ScriptletScanTimer.Stop() }
    if ($script:ScriptletScanState -and $script:ScriptletScanState.Reader) {
        try { $script:ScriptletScanState.Reader.Dispose() } catch {}
    }
    $script:ScriptletScanState = $null
    Set-ScriptletUiBusy $false
}

function Complete-ScriptletScan {
    $state = $script:ScriptletScanState
    if (-not $state) { return }

    if ($script:ScriptletScanTimer) { $script:ScriptletScanTimer.Stop() }
    if ($state.Reader) {
        try { $state.Reader.Dispose() } catch {}
        $state.Reader = $null
    }
    $state.Stopwatch.Stop()

    $script:ScriptletRules = @($state.Records.ToArray())
    foreach ($warning in @($state.Warnings)) { Write-Log $warning 'WARN' }

    if ($script:ScriptletProgress) {
        $script:ScriptletProgress.Visible = $true
        $script:ScriptletProgress.Style = 'Continuous'
        $script:ScriptletProgress.Value = 1000
    }

    $elapsed = [Math]::Round($state.Stopwatch.Elapsed.TotalSeconds, 1)
    $root = $state.Root
    $script:ScriptletScanState = $null
    if ($script:LblScriptletStatus) {
        $script:LblScriptletStatus.Text = T 'scriptlet.statusRenderN' @($script:ScriptletRules.Count)
    }
    [System.Windows.Forms.Application]::DoEvents()
    Update-ScriptletListView
    Write-Log "Scriptlet scan complete: $($script:ScriptletRules.Count) rule(s) from $root in ${elapsed}s" 'OK'

    if ($script:LblScriptletStatus) {
        $script:LblScriptletStatus.Text += (T 'scriptlet.scanDone' @($elapsed))
    }
    if ($script:ScriptletRules.Count -eq 0) {
        [void](Show-Message -Text (T 'msg.scriptlet.noRules' @($root)) -Title (T 'msg.title.scriptlet') -Buttons 'OK' -Icon 'Information')
    }
}

function Step-ScriptletScan {
    $state = $script:ScriptletScanState
    if (-not $state) {
        if ($script:ScriptletScanTimer) { $script:ScriptletScanTimer.Stop() }
        return
    }

    $startTick = [Environment]::TickCount64
    $linesThisTick = 0
    while ((([Environment]::TickCount64 - $startTick) -lt 35) -and ($linesThisTick -lt 2500)) {
        if (-not $state.Reader) {
            if ($state.FileIndex -ge $state.Files.Count) {
                Complete-ScriptletScan
                return
            }

            $file = $state.Files[$state.FileIndex]
            $state.FileIndex++
            $state.CurrentFile = $file
            $state.CurrentLine = 0
            try {
                $state.Reader = [System.IO.File]::OpenText($file.FullName)
            } catch {
                [void]$state.Warnings.Add("Scriptlet scan failed $($file.FullName): $_")
                $state.ProcessedBytes += [int64]$file.Length
                $state.Reader = $null
                continue
            }
        }

        try {
            $line = $state.Reader.ReadLine()
        } catch {
            [void]$state.Warnings.Add("Scriptlet scan failed $($state.CurrentFile.FullName): $_")
            try { $state.Reader.Dispose() } catch {}
            $state.ProcessedBytes += [int64]$state.CurrentFile.Length
            $state.Reader = $null
            continue
        }

        if ($null -eq $line) {
            try { $state.Reader.Dispose() } catch {}
            $state.ProcessedBytes += [int64]$state.CurrentFile.Length
            $state.Reader = $null
            continue
        }

        $state.CurrentLine++
        $linesThisTick++
        $record = ConvertTo-ScriptletRecord -File $state.CurrentFile.FullName -Root $state.Root -Line $line -LineNumber $state.CurrentLine
        if ($record) { [void]$state.Records.Add($record) }
    }

    Update-ScriptletScanProgress
}

function Invoke-ScriptletScan {
    $root = $script:TxtScriptletRoot.Text.Trim()
    if ($script:ScriptletScanState) {
        Write-Log 'Scriptlet scan is already running.' 'INFO'
        return
    }

    try {
        Set-ScriptletUiBusy $true (T 'scriptlet.statusFinding')
        $warnings = New-Object System.Collections.ArrayList
        $files = @(Get-ScriptletListFiles -Root $root -Warnings $warnings)
        if ($files.Count -eq 0) {
            Set-ScriptletUiBusy $false
            if ($script:ScriptletProgress) { $script:ScriptletProgress.Value = 0 }
            [void](Show-Message -Text (T 'msg.scriptlet.noFiles' @($root)) -Title (T 'msg.title.scriptlet') -Buttons 'OK' -Icon 'Information')
            return
        }

        $totalBytes = [int64](@($files | Measure-Object Length -Sum).Sum)
        if ($totalBytes -lt 1) { $totalBytes = 1 }
        $script:ScriptletRules = @()
        $script:ScriptletVisibleRules = @()
        $script:ScriptletCheckedKeys.Clear()
        if ($script:ScriptletList) { $script:ScriptletList.Items.Clear() }

        $script:ScriptletScanState = [pscustomobject]@{
            Root           = $root
            Files          = $files
            FileIndex      = 0
            CurrentFile    = $null
            CurrentLine    = 0
            Reader         = $null
            ProcessedBytes = 0L
            TotalBytes     = $totalBytes
            Records        = (New-Object System.Collections.Generic.List[object])
            Warnings       = $warnings
            Stopwatch      = [System.Diagnostics.Stopwatch]::StartNew()
        }

        if ($script:ScriptletProgress) {
            $script:ScriptletProgress.Visible = $true
            $script:ScriptletProgress.Style = 'Continuous'
            $script:ScriptletProgress.Value = 0
        }
        Update-ScriptletScanProgress (T 'scriptlet.statusFound' @($files.Count))
        Write-Log "Scriptlet scan started: $root ($($files.Count) list file(s), $([Math]::Round($totalBytes / 1MB, 2)) MB)" 'INFO'

        if (-not $script:ScriptletScanTimer) {
            $script:ScriptletScanTimer = New-Object System.Windows.Forms.Timer
            $script:ScriptletScanTimer.Interval = 15
            $script:ScriptletScanTimer.Add_Tick({ Step-ScriptletScan })
        }
        $script:ScriptletScanTimer.Start()
    } catch {
        Stop-ScriptletScan
        $script:ScriptletRules = @()
        Update-ScriptletListView
        Write-Log "Scriptlet scan failed: $_" 'ERR'
        [void](Show-Message -Text (T 'msg.scriptlet.scanFailed' @("$_")) -Title (T 'msg.title.scriptlet') -Buttons 'OK' -Icon 'Error')
    }
}


#endregion

#region UI: shell ---------------------------------------------------------------
# Layout rules: every control is docked or lives in a Table/FlowLayoutPanel, and
# nothing is placed by absolute coordinates. Absolute positions break as soon as
# a translation is longer, the window is small, or the layout is mirrored for a
# right-to-left language.
function New-Rgb { param([int]$R, [int]$G, [int]$B) return [System.Drawing.Color]::FromArgb($R, $G, $B) }
$script:Clr = @{
    Graphite = (New-Rgb 20 24 31);   Graphite2 = (New-Rgb 36 42 52);  GraphiteLine = (New-Rgb 62 70 84)
    Ink      = (New-Rgb 31 35 40);   Slate     = (New-Rgb 87 96 106); Mist = (New-Rgb 101 109 118)
    Fog      = (New-Rgb 244 245 247); Line     = (New-Rgb 228 231 235); LineStrong = (New-Rgb 208 213 219)
    White    = [System.Drawing.Color]::White
    Ember    = (New-Rgb 201 63 23);  EmberDark = (New-Rgb 168 50 16); EmberSoft = (New-Rgb 253 236 229)
    Green    = (New-Rgb 26 127 75);  Blue = (New-Rgb 9 105 218);      Amber = (New-Rgb 154 103 0)
    Red      = (New-Rgb 207 34 46);  RedSoft = (New-Rgb 255 241 242); AmberSoft = (New-Rgb 255 248 230)
    Selection = (New-Rgb 236 242 251); OnDark = (New-Rgb 226 230 235); OnDarkMuted = (New-Rgb 176 184 194)
}

function New-Ctl {
    param([string]$Type, [hashtable]$Props = @{}, $Parent = $null)
    $c = New-Object ("System.Windows.Forms.$Type")
    foreach ($k in $Props.Keys) { $c.$k = $Props[$k] }
    if ($Parent) { [void]$Parent.Controls.Add($c) }
    return $c
}

function New-BfoButton {
    param([string]$Key, [ValidateSet('Default', 'Primary', 'Danger', 'Ghost')][string]$Style = 'Default', [int]$MinWidth = 0)
    $b = New-Object System.Windows.Forms.Button
    $b.AutoSize = $true
    $b.AutoSizeMode = 'GrowAndShrink'
    $b.MinimumSize = New-Object System.Drawing.Size($MinWidth, 34)
    $b.Padding = New-Object System.Windows.Forms.Padding(10, 0, 10, 0)
    $b.FlatStyle = 'Flat'
    $b.UseVisualStyleBackColor = $false
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.FlatAppearance.BorderSize = 1
    switch ($Style) {
        'Primary' {
            $b.BackColor = $script:Clr.Ember; $b.ForeColor = $script:Clr.White
            $b.FlatAppearance.BorderColor = $script:Clr.Ember; $b.FlatAppearance.MouseOverBackColor = $script:Clr.EmberDark
            [void](Set-LocFont $b -Size 9.5 -Semibold)
        }
        'Danger' {
            $b.BackColor = $script:Clr.White; $b.ForeColor = $script:Clr.Red
            $b.FlatAppearance.BorderColor = (New-Rgb 240 190 195); $b.FlatAppearance.MouseOverBackColor = $script:Clr.RedSoft
            [void](Set-LocFont $b -Size 9)
        }
        'Ghost' {
            $b.BackColor = $script:Clr.White; $b.ForeColor = $script:Clr.Ink
            $b.FlatAppearance.BorderColor = $script:Clr.White; $b.FlatAppearance.MouseOverBackColor = $script:Clr.Fog
            [void](Set-LocFont $b -Size 9)
        }
        default {
            $b.BackColor = $script:Clr.White; $b.ForeColor = $script:Clr.Ink
            $b.FlatAppearance.BorderColor = $script:Clr.LineStrong; $b.FlatAppearance.MouseOverBackColor = $script:Clr.Fog
            [void](Set-LocFont $b -Size 9)
        }
    }
    if ($Key) { [void](Set-Loc $b $Key) }
    return $b
}

$script:ToolTip = New-Object System.Windows.Forms.ToolTip
$script:ToolTip.AutoPopDelay = 30000
$script:ToolTip.InitialDelay = 350
$script:ToolTip.ReshowDelay  = 200

# ---- Window -------------------------------------------------------------------
function New-MainForm {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    try { $wa = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea } catch { }
    $w = [Math]::Min(1180, $wa.Width - 32)
    $h = [Math]::Min(800, $wa.Height - 32)
    $form = New-Object System.Windows.Forms.Form
    $form.SuspendLayout()
    $form.Size = New-Object System.Drawing.Size($w, $h)
    # The old fixed minimum (1080x860) did not fit small screens at all.
    $form.MinimumSize = New-Object System.Drawing.Size([Math]::Min(940, $w), [Math]::Min(600, $h))
    $form.StartPosition = 'CenterScreen'
    $form.Font = Get-BfoUiFont -Size 9
    $form.BackColor = $script:Clr.Fog
    $form.KeyPreview = $true
    # The window / taskbar icon is the same mark. Icon.FromHandle does not own the handle; one small icon lives as long as the window.
    $logo = Get-BfoLogoBitmap
    if ($logo) { try { $form.Icon = [System.Drawing.Icon]::FromHandle($logo.GetHicon()) } catch { Write-Log "Window icon not set: $($_.Exception.Message)" 'WARN' } }
    [void](Set-Loc $form 'app.title' -FormatArgs @($script:AppVersion))
    return $form
}

# ---- Header: brand, language, preset strip -----------------------------------
function New-HeaderPanel {
    $hdr = New-Ctl 'Panel' @{ Dock = 'Top'; BackColor = $script:Clr.Graphite; Padding = (New-Object System.Windows.Forms.Padding(16, 10, 16, 6)); Height = 160 }

    $table = New-Ctl 'TableLayoutPanel' @{ Dock = 'Top'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; ColumnCount = 3; RowCount = 4; BackColor = $script:Clr.Graphite } $hdr
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
    foreach ($i in 0..2) { [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize'))) }
    # Row 3 (version note) stays collapsed until Update-BraveInfo has something to say;
    # an invisible control in an AutoSize row still reserves the row's space.
    [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 0)))
    $script:HeaderTable = $table
    $script:HeaderPanel = $hdr
    $table.Add_SizeChanged({ $script:HeaderPanel.Height = $script:HeaderTable.Height + $script:HeaderPanel.Padding.Vertical })

    # Row 0, left - brand mark + title/subtitle
    $brand = New-Ctl 'FlowLayoutPanel' @{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $false; FlowDirection = 'LeftToRight'; BackColor = $script:Clr.Graphite; Margin = (New-Object System.Windows.Forms.Padding(0)) }
    $logo = Get-BfoLogoBitmap
    if ($logo) {
        $mark = New-Ctl 'PictureBox' @{ Image = $logo; SizeMode = 'Zoom'; Size = (New-Object System.Drawing.Size(48, 48)); BackColor = $script:Clr.Graphite; Margin = (New-Object System.Windows.Forms.Padding(0, 0, 10, 0)) } $brand
        $mark.RightToLeft = 'No'
    } else {
        # Only if the embedded picture could not be decoded: a plain lettered tile keeps the layout identical.
        $mark = New-Ctl 'Label' @{ Text = 'B'; AutoSize = $false; Size = (New-Object System.Drawing.Size(36, 36)); BackColor = $script:Clr.Ember; ForeColor = $script:Clr.White; TextAlign = 'MiddleCenter'; Margin = (New-Object System.Windows.Forms.Padding(0, 2, 10, 0)) } $brand
        $mark.RightToLeft = 'No'
        [void](Set-LocFont $mark -Size 15 -Semibold)
    }
    $titles = New-Ctl 'FlowLayoutPanel' @{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $false; FlowDirection = 'TopDown'; BackColor = $script:Clr.Graphite; Margin = (New-Object System.Windows.Forms.Padding(0)) } $brand
    $title = New-Ctl 'Label' @{ AutoSize = $true; ForeColor = $script:Clr.White; BackColor = $script:Clr.Graphite; Margin = (New-Object System.Windows.Forms.Padding(0)) } $titles
    [void](Set-Loc $title 'app.name'); [void](Set-LocFont $title -Size 15 -Semibold)
    $sub = New-Ctl 'Label' @{ AutoSize = $true; ForeColor = $script:Clr.OnDarkMuted; BackColor = $script:Clr.Graphite; Margin = (New-Object System.Windows.Forms.Padding(1, 0, 0, 0)) } $titles
    [void](Set-Loc $sub 'header.subtitle'); [void](Set-LocFont $sub -Size 8.5)
    $table.Controls.Add($brand, 0, 0)

    # Row 0, right - language picker and, underneath, which Brave this PC has
    $rightStack = New-Ctl 'FlowLayoutPanel' @{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $false; FlowDirection = 'TopDown'; BackColor = $script:Clr.Graphite; Margin = (New-Object System.Windows.Forms.Padding(0)); Anchor = 'Right' }
    $right = New-Ctl 'FlowLayoutPanel' @{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $false; FlowDirection = 'LeftToRight'; BackColor = $script:Clr.Graphite; Margin = (New-Object System.Windows.Forms.Padding(0)) } $rightStack
    $lblLang = New-Ctl 'Label' @{ AutoSize = $true; ForeColor = $script:Clr.OnDarkMuted; BackColor = $script:Clr.Graphite; Margin = (New-Object System.Windows.Forms.Padding(0, 6, 6, 0)) } $right
    [void](Set-Loc $lblLang 'header.language'); [void](Set-LocFont $lblLang -Size 8.5)
    $script:LanguageCombo = New-Ctl 'ComboBox' @{ DropDownStyle = 'DropDownList'; Width = 170; FlatStyle = 'Flat'; Margin = (New-Object System.Windows.Forms.Padding(0, 2, 0, 0)) } $right
    $script:LblLocaleNote = New-Ctl 'Label' @{ AutoSize = $true; ForeColor = (New-Rgb 255 212 153); BackColor = $script:Clr.Graphite; Margin = (New-Object System.Windows.Forms.Padding(8, 6, 0, 0)); Text = '' } $right
    [void](Set-LocFont $script:LblLocaleNote -Size 8)
    $btnHelp = New-Ctl 'Button' @{ Text = '?'; Size = (New-Object System.Drawing.Size(30, 26)); FlatStyle = 'Flat'; BackColor = $script:Clr.Graphite2; ForeColor = $script:Clr.OnDark; Cursor = [System.Windows.Forms.Cursors]::Hand; Margin = (New-Object System.Windows.Forms.Padding(8, 2, 0, 0)); UseVisualStyleBackColor = $false } $right
    $btnHelp.FlatAppearance.BorderColor = $script:Clr.GraphiteLine
    $btnHelp.RightToLeft = 'No'
    [void](Set-LocTooltip $btnHelp 'header.help')
    $btnHelp.Add_Click({ Invoke-Guarded 'Help' { Show-HelpDialog } })
    $script:LblBrave = New-Ctl 'Label' @{ AutoSize = $true; ForeColor = $script:Clr.OnDarkMuted; BackColor = $script:Clr.Graphite; Margin = (New-Object System.Windows.Forms.Padding(0, 6, 0, 0)); Anchor = 'Right' } $rightStack
    [void](Set-LocFont $script:LblBrave -Size 8.5)
    $table.Controls.Add($rightStack, 2, 0)

    # Row 1 - preset strip (segmented buttons that wrap on narrow windows)
    $script:PresetFlow = New-Ctl 'FlowLayoutPanel' @{ Dock = 'Fill'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $true; BackColor = $script:Clr.Graphite; Margin = (New-Object System.Windows.Forms.Padding(0, 8, 0, 0)) }
    $table.Controls.Add($script:PresetFlow, 0, 1)
    $table.SetColumnSpan($script:PresetFlow, 3)
    $script:PresetButtons = @{}
    foreach ($key in $script:PresetKeys) {
        $b = New-Ctl 'Button' @{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; FlatStyle = 'Flat'; Cursor = [System.Windows.Forms.Cursors]::Hand; UseVisualStyleBackColor = $false
            Margin = (New-Object System.Windows.Forms.Padding(0, 3, 8, 3)); Padding = (New-Object System.Windows.Forms.Padding(8, 0, 8, 0)); MinimumSize = (New-Object System.Drawing.Size(96, 30)); Tag = $key } $script:PresetFlow
        $b.FlatAppearance.BorderSize = 1
        [void](Set-Loc $b "preset.$key.name")
        [void](Set-LocTooltip $b "preset.$key.description")
        $b.Add_Click({ $k = $this.Tag; Invoke-Guarded 'Preset' { Invoke-PresetClick $k } })
        $script:PresetButtons[$key] = $b
    }

    # Row 2 - what the selected mode does (fixed two-line height: text wraps, the layout never jumps)
    $script:LblModeInfo = New-Ctl 'Label' @{ Dock = 'Fill'; AutoSize = $false; Height = 38; ForeColor = $script:Clr.OnDark; BackColor = $script:Clr.Graphite; Margin = (New-Object System.Windows.Forms.Padding(0, 4, 0, 0)) }
    [void](Set-LocFont $script:LblModeInfo -Size 8.5)
    $table.Controls.Add($script:LblModeInfo, 0, 2)
    $table.SetColumnSpan($script:LblModeInfo, 3)

    # Row 3 - shown only when the installed Brave is much newer or older than the
    # version this list of settings was checked against.
    $script:LblCompat = New-Ctl 'Label' @{ Dock = 'Fill'; AutoSize = $false; Height = 36; ForeColor = (New-Rgb 255 212 153); BackColor = $script:Clr.Graphite; Margin = (New-Object System.Windows.Forms.Padding(0, 0, 0, 2)); Visible = $false }
    [void](Set-LocFont $script:LblCompat -Size 8.5)
    $table.Controls.Add($script:LblCompat, 0, 3)
    $table.SetColumnSpan($script:LblCompat, 3)
    return $hdr
}

# Highlights the active preset (the old UI never showed which mode was in effect).
function Update-PresetStrip {
    foreach ($key in $script:PresetKeys) {
        $b = $script:PresetButtons[$key]
        $on = ($script:ActiveProfile -eq $key)
        if ($on) {
            $b.BackColor = $script:Clr.Ember; $b.ForeColor = $script:Clr.White
            $b.FlatAppearance.BorderColor = $script:Clr.Ember; $b.FlatAppearance.MouseOverBackColor = $script:Clr.EmberDark
            $b.Font = Get-BfoUiFont -Size 9.5 -Semibold
        } else {
            $b.BackColor = $script:Clr.Graphite2; $b.ForeColor = $script:Clr.OnDark
            $b.FlatAppearance.BorderColor = $script:Clr.GraphiteLine; $b.FlatAppearance.MouseOverBackColor = $script:Clr.GraphiteLine
            $b.Font = Get-BfoUiFont -Size 9.5
        }
    }
}

# ---- Sidebar ------------------------------------------------------------------
function New-Sidebar {
    $side = New-Ctl 'Panel' @{ Dock = 'Left'; Width = 226; BackColor = $script:Clr.Fog; Padding = (New-Object System.Windows.Forms.Padding(8, 8, 0, 0)) }
    $tv = New-Ctl 'TreeView' @{ Dock = 'Fill'; BorderStyle = 'None'; BackColor = $script:Clr.Fog; ShowLines = $false; ShowRootLines = $false; ShowPlusMinus = $false
        FullRowSelect = $true; HideSelection = $false; ItemHeight = 30; Indent = 4; Scrollable = $true; ShowNodeToolTips = $true } $side
    $tv.Font = Get-BfoUiFont -Size 9
    $script:Nav = $tv
    # Group headings are labels, not destinations: never let them take the selection.
    $tv.Add_BeforeSelect({ if ($_.Node.Tag -is [string] -and $_.Node.Tag.StartsWith('group:')) { $_.Cancel = $true } })
    $tv.Add_BeforeCollapse({ $_.Cancel = $true })
    $tv.Add_AfterSelect({ $target = $_.Node.Tag; Invoke-Guarded 'Navigate' { Show-Page $target } })
    return $side
}

# ---- Bottom: action bar + status strip ------------------------------------------
function New-ActionBar {
    $bar = New-Ctl 'Panel' @{ Dock = 'Bottom'; Height = 58; BackColor = $script:Clr.White; Padding = (New-Object System.Windows.Forms.Padding(12, 11, 12, 11)) }
    [void](New-Ctl 'Panel' @{ Dock = 'Top'; Height = 1; BackColor = $script:Clr.Line } $bar)

    $right = New-Ctl 'FlowLayoutPanel' @{ Dock = 'Right'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $false; FlowDirection = 'LeftToRight'; BackColor = $script:Clr.White } $bar
    $script:LblPending = New-Ctl 'Label' @{ AutoSize = $true; ForeColor = $script:Clr.Ink; BackColor = $script:Clr.White; Margin = (New-Object System.Windows.Forms.Padding(0, 8, 14, 0)) } $right
    [void](Set-LocFont $script:LblPending -Size 9.5 -Semibold)
    $script:BtnPreview = New-BfoButton 'action.preview' 'Default' 120
    $script:BtnPreview.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $script:BtnApply = New-BfoButton 'action.apply' 'Primary' 150
    $script:BtnApply.Margin = New-Object System.Windows.Forms.Padding(0)
    $right.Controls.AddRange([System.Windows.Forms.Control[]]@($script:LblPending, $script:BtnPreview, $script:BtnApply))

    $left = New-Ctl 'FlowLayoutPanel' @{ Dock = 'Left'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $false; FlowDirection = 'LeftToRight'; BackColor = $script:Clr.White } $bar
    $script:BtnTools = New-BfoButton 'tools.button' 'Default' 90
    $script:BtnTools.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
    $script:BtnRestore = New-BfoButton 'action.fullRestore' 'Danger' 120
    $script:BtnRestore.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)
    $script:ChkBackup = New-Ctl 'CheckBox' @{ AutoSize = $true; Checked = $true; BackColor = $script:Clr.White; Margin = (New-Object System.Windows.Forms.Padding(0, 8, 0, 0)) }
    [void](Set-Loc $script:ChkBackup 'action.backup'); [void](Set-LocFont $script:ChkBackup -Size 9)
    $left.Controls.AddRange([System.Windows.Forms.Control[]]@($script:BtnTools, $script:BtnRestore, $script:ChkBackup))
    return $bar
}

function New-StatusStrip {
    $status = New-Ctl 'Panel' @{ Dock = 'Bottom'; Height = 26; BackColor = (New-Rgb 236 238 241) }
    $script:BtnLogToggle = New-Ctl 'Button' @{ Dock = 'Right'; AutoSize = $true; FlatStyle = 'Flat'; BackColor = (New-Rgb 236 238 241); ForeColor = $script:Clr.Slate; Cursor = [System.Windows.Forms.Cursors]::Hand; UseVisualStyleBackColor = $false; Padding = (New-Object System.Windows.Forms.Padding(6, 0, 6, 0)) } $status
    $script:BtnLogToggle.FlatAppearance.BorderSize = 0
    [void](Set-Loc $script:BtnLogToggle 'status.showLog'); [void](Set-LocFont $script:BtnLogToggle -Size 8.5)
    $script:StatusLabel = New-Ctl 'Label' @{ Dock = 'Fill'; TextAlign = 'MiddleLeft'; ForeColor = $script:Clr.Slate; Padding = (New-Object System.Windows.Forms.Padding(12, 0, 0, 0)); AutoEllipsis = $true } $status
    [void](Set-LocFont $script:StatusLabel -Size 8.5)
    $script:StatusLabel.BringToFront()
    return $status
}

function New-LogPanel {
    $panel = New-Ctl 'Panel' @{ Dock = 'Bottom'; Height = 150; Visible = $false; BackColor = (New-Rgb 18 18 18) }
    $script:LogBox = New-Ctl 'TextBox' @{ Dock = 'Fill'; Multiline = $true; ScrollBars = 'Vertical'; ReadOnly = $true; BorderStyle = 'None'
        BackColor = (New-Rgb 18 18 18); ForeColor = [System.Drawing.Color]::LightGreen; WordWrap = $true } $panel
    $script:LogBox.Font = Get-BfoUiFont -Size 8.5 -Mono
    return $panel
}
#endregion

#region UI: brand mark ---------------------------------------------------------
# The Brave Free Origin mark (transparent PNG, 96 px) is embedded as base64 so the
# app stays a single file: the header and the window icon work even when only
# Brave-Free-Origin.ps1 was copied. Pure ASCII, like the rest of the file.
$script:LogoPngBase64 = -join @(
    'iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAMAAADVRocKAAABgFBMVEXhZx8VN1wsa5tQco9ai6vY29pJXXHziiJvkKWPoKqgpqtg'
    'dYooT27clV51j6S1Ow8Yamzg3tpnn6RVZHS1VimVs8fXsJTozKrLdE1qbq+zaUpldotbXmTRk26wy9W0ydSTprMiIniQm6c6hLOj'
    'tczYrpKdtscA//8mPT1YandYmMM7UW3CPRR4fvndso3TmXXr5NToyLDm2bGqxdS0dlfqrqQhZKd///+kXV2/fz+enX6KrsfdoHpo'
    'ERH/f3+4jnCSws/FfmO4k3d2p8H//38AAP/t8/DvxIwA/wA9Tmefi3f//wCDa4uBf4SedGJ+scl/uNRzgH4AAAAtZpP+/v4ZRm/G'
    'SBLQVRUnWYcoSWz8/PswVHPvdyf0hyd/f3+6RBMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACvetg9AAAAYHRSTlP+/vzs8SHo/ppZIKDy'
    '9Gn+A/wQpP5f+fz7B/VjDJ0r/fgDmf0qYfgBBGX2qv4DnG1PWBxaqhsEAgoEGpMIAwL/l7dwowIBnJgBW5YC/6pyXxJ5AP4H/v7+'
    '/vv++/7+Av6XeY4zAAAM8ElEQVR42u1Zh3LjOBIlCZBiVs6WLMuSPQ6T887mdDmBYBIl8f//4l6DctqzvZ6t2au6q0HZFCWR/dCv'
    '+zWakCZ+56F9BvgM8L8D8PgT2z1++9/1QIqF+ymtSuEuxPYawLHkrUunPsFoHXe5vAbwWEyZLRqfDmAobG5WLiiAlnAiLn+Sn4wh'
    'MMLcawAuATjik4VhIbqnvFvZ0yqPnMjgsnF83124fPvAFJWSHwKgdQmwBUCET4b33bZnC/HmQXLZii432BWAxJkbkQt790bB8vD1'
    'gRTSvT9YsgEHDLYQjyUu1MC/I4TJAGBXmLfftXXnEQtN8euRaiCFDANZRJZd7UDYDJiMXLiXpC8Yjwxmu0J23ftTtAsHFB98LBoA'
    'CEGXsKMsItTW3cTusSijmXE+M7d3svRYmJi/YYQCQCEAGmIMNDGNjIhgD+TteYEgiznLCcGoNHQ7BAzYZJ+ZpIVQDLWhCCPDFtJT'
    'LszFG3nbrJQPrmcVWRZFiJVb6fOuAMCixAllEoI89Q1SGcsoDM6tYZAmJgyVSPiQMVfpxbzNhUdiTvYj5JDDIwZXKU0Z/J4iCgAw'
    'yCshjm+y36IEg72pl+cFrmi4zgITXPwHTVCssg9KFvwQ5Yd0sCdAGuOmSS4ove3dIBiJzw37QIh/WUVunSBTkbEn4sCm0N1EQE1j'
    'ZB9Tn3Ju/HWOnNbw6VRlhwzVd0Aw59djLSVy2Bam6zJmXSSo+UIQgLx22fbFXPyDV/YXZF8xREpuCC+rEDIKYcS+3TFS3TgEhxG3'
    '2RwUtcSj4VsSss1sHnFx7TKK7gejmmPXJCWAp21VixpT5iPw7NnMVwgGSa4qOxLUmF0G5FzNfovptK2p9ApcyLqS1ha67u0b8YEm'
    'Tfaz/aYiiplDVYugZ2kXdANvzmJywsgIgeAp3W3oK45zHwBb0pdstRsuwhHnBaqLSQL5Iyx9y3FbpOzvc+VJqGqFJk6QUpJlBaHv'
    'HxECYZx+MEUD7IQsy3U9tpwLLuZORYnD4jguUDskVSfTJlJwY1Yc7YMCiIrUy/cAIBkWn4Wl+Dc4j4kidQZLY1bEse8VuV2lE9TC'
    'yeEQcF7OWB7HtFLJl6enJF9QVMx4puwjwi85k0JrgE/miC+tIia7zMi4ERPKIf9h6lhx3nalVdithorA2Me1IuSObHk5l047xwfT'
    'U0yf5mVAW5RHmCzsdzmSr4FS4eKtjVzMYh8uGtC1YcQZXY6M9cCktLKqJUDdygGA5cP9iTyAH44nuxTdKIpxw6FBSQIuPClRMiJX'
    '7GmYloccYg48KXykkY/JHwKBnDj9AKtb8gDGt5IAIhQTxP5AAQzfCMFPyX4WZ/zwsMqiuLClQ6i20sFWTK24KCJuOj7FLcZUjNOI'
    'CIsOuS1bYgeAfPmSAN5/JX7cVgAA/eH0UNk3VJEGOUbMmj8j9SLQ1FBCQ60pwE7GvJdHRZznBIDLdwimUADvv/ryBRhRHkC/7/fe'
    'txVF04r+2MCLAZgsjo6aM4bPCta6EFqLEJQC+BGLEQsSjBHFBRUOhwAoi8xeMFmaZ2fmkyB4grvaBQF0iZ8ijlQSxRkz2BFX+UiZ'
    's71qfluMhFPEBQNXvOInjysAKa2jn59MgiBYb4Jnz4KNFgSTyR+eeQzdIYoy4lvpP+Kn4CVTPKGoXzS/SG5SikfazMAVsqiCyOg+'
    'vsA0nvWD9VrDnwbbONL5JlhOhfja5SrAKkcRV5/SxMA8oT+yK1WQXctb4G27AP/ElUppvNJ90KP7NNCUUY3Gunqhs2D5GqU8IwDE'
    'jcobcjzz46zwgG2GrAJALRnnhRcu4IVPZYFkRn4rqBDcD5J0ZzpV9jH9yp+g95zWqezaLXE1+6ljMzamtasKcptgLS905twiJ1RF'
    'oiPi+DyA3U1to7xI1utEw+kmQCi0NQCwTmUX18dZznjYDVHKjQypvXcRZKwIBTSQgyPGIGLSc0WWLSZavUzI+EZLybpW19bpurYh'
    'ppJEe0IND9FJlR4lk0WUexF0NYYYrz1COVauHNTBEZjJIpwhT1vLQQlLHTqs00RLNHUgd8AbMINlqCjKVaUmCznFmZL00c1nNBla'
    'FGSFUCiPdb3Iwkm6Dmq1GiaLyZdpSrMmlBJe1IinSZjhruLSPpRaoDGQ1fyvAKjHmY69Mz/PK1fIG8R+mda0lCjRynpZAiYp1Ugp'
    'KqkWaE+sPNeV3cq23/ZCksDejYfAt6DoLHT33K7dhpJz5UsMV4q5tk4oBmlaUp6mpSILb/GSJulG6/k7gAIiirhnd929PafNLp5n'
    'dh5sJVoe3aeLQREskyM4LfqUoIAok/VmU6tt0nRDA/GgYACgWajrMSrPC7q1KMa7Z8BLihoQGhm/HLE6HjU7KlnScg3zNWW8RifI'
    'Jwr6Wmse6bq/o1SvXsHs4tatBNfDAlXkhUWFiVQ9d55QdJGedeJ8N2oKAZDrFGPQa+5TiiNirKAIFpa9uArBNYDtrgvtoommuWBi'
    '7SVUnJC4KGdIX2pohFUDWfiHmpuzauZ6YYULed3YLzxwt67tta08viTJn06QmuCiviaT2rpyQNOAVtskSDCMfvOK1Dy3zk4ct7W9'
    'dbcFZQ3mdbosZxa9hhPkPJgAQZQ0a0UTuYKZb0CSpvTc3yfzaDEoQ/zcarvXW9brFLlo0p2TdvtPLx1G9v3nqrol9TqSctTROgRA'
    'c0/TzghHig5BNGk2utXt4t4TNFCucytFj9ATmugSuuILyqe8PXZUGU3TpI7i0O8FpC6Kr9YJev3aOlElitYIx6M7/PY73O6g/HnX'
    'tiWuAIboctyhp1vm36wzb4y1eIkI0zKgysSm1w/KtcqgEqcbAkiqVSJYwvNx+8yypRXbrT0vPB7euePl6bTSwgnri4NloNaByhBC'
    'HFAugaIUJQjBgNZS5UHPaZiWZ1IYC9++e0sNzcKJ4+gWkrhxkvv4YFQVhAsAuEH2aypdyTNVMOABmko/C/cw7TzvOidC3hbkLXpU'
    'yQp+FCJM8iQ3hHjdSUEBrNASQHTXqhiQopFTEDKSCevE4LkCOEaP6qCn4JJdbBbdKNcy9BhjPsPThikAIMVETTBdU5A1VYRqlYrJ'
    '/q7WrWk8FWaeYXHljLMcBy+88uFGDMYn0smR0Z4ckweTlCZJQUaepqSyoB/gDz7AI/Ud9AGoiQLAczHTc0eOwztioMqr9Hlz3+qi'
    'yQUAlTliJ62TnVrQGXzT638TdAKsEfTdOiVf0jUBRGHo7zd5Ln/xBH3Dg9YWTba1WnGmPAhAglatveegY9Mf1dX4pl+rUehRpNTi'
    'qTwo5oyvVhaasaF798YsxNZEY+AzTwfAq8GgSpP6eVLv9PvNVRMQo+aq3+93CADZRDEOCCCfI3is2Ld3a/HtAAdQM1WWo5nuS/H3'
    '/oAWYC0BQyWpFwidDg79Xo/WfHhFLgT974XpF46NarcPFd8HgP5FnzVnOW/i6adlPuukBHCerrEeK4BV0FsBAKLGEkdBJhdNcwih'
    'PWP+rMl0+2K1vxOArVb7MZ+9pIiPkCtrwqiXdRT+1Wo1GuFAdSkpqT8igAE9enZtlu8jBvGDAFDhc52qrlpu0M6BqbIzaK56nbLT'
    '6a2aA2qUIDUNhTWFkLusQP1tPhhglrPmEStc8UolKvJUK5Pzzmg06vX7vdFoUJ6rUkq1PEEOuQXHw7c++wgPkHG8mIslZk7mUS8q'
    'F9ToD9AX0Uqt6pG2lHY0WzX5hQePfh1gNdN1Tsu3HA06pDWtRCp1VpejU0/X1CeBpMFI0mLGc/0IX1j6wwBWWMj1s3Zbft8LkqrL'
    'Leud5oX9ZqcsqRFAUxb0nkrWxnrjqW8fDHDE5i21b2BOEpXxSKfOqN8j673+qExUMQV5k+e0Kyrc0P84AAgN7w7G1j9fdyAzWpQT'
    '+DAKoITBiBp6Cm+SDF48xnNGAyVM3/84D3T/R6zcYczEq6RUaya6XtShXg+SoEaSUhcZhEdc2oQz848EUB5gs01n5otRmdJDQlKe'
    'n0Ne0HRJ7YRWDtJkZC6KOETxlL8RIEQLIJbQFjXYl627RgCJ1iuxlJk7gOJhALToWzuAv+CdAhBPB8tRXUVaIainnLQe9EfLY2gM'
    'AI+AcwVw/+9o9mUMaHvIAUUoNE+cp8h8apKUA0R+XVs6S9odLGI8qj8QQAps7epYVBm39NzCwBMhthqtsTQnHZAP5uvKfnnemZjy'
    'pO15aJRZGxfiBQ/ikJtleTd+yLjpgaXfNrDpVAwnkDTYoQjgr/N0aFn+rVfrZ3d6sMVyQ48HGDgUxe4Fwy+s6XI0oCKNPyjhaddS'
    'DzKXQ11b3dm+0wNQefdwhTs3X6FGaN+Zf36BRvnucWM/+OE/Nb6jKbwqy+/k7s1v+TVWbu8c2N36Cnsfo5EUr999ff+Vv/3n3q9p'
    'i+ad+B1/T5Z3/fLxyX6w3m7F59/0PwP83wH8GxBXyTmZI1jjAAAAAElFTkSuQmCC'
)
$script:LogoBitmap = $null
$script:LogoStream = $null

function Get-BfoLogoBitmap {
    if ($script:LogoBitmap) { return $script:LogoBitmap }
    try {
        # A Bitmap loaded from a stream needs that stream for its whole lifetime, so keep it.
        $script:LogoStream = New-Object System.IO.MemoryStream(, [System.Convert]::FromBase64String($script:LogoPngBase64))
        $script:LogoBitmap = New-Object System.Drawing.Bitmap($script:LogoStream)
    } catch {
        Write-Log "The brand mark could not be decoded: $($_.Exception.Message)" 'WARN'
        $script:LogoBitmap = $null
    }
    return $script:LogoBitmap
}
#endregion


#region UI: settings grids --------------------------------------------------------
# One DataGridView per page instead of hundreds of loose controls: it builds in
# tens of milliseconds, scrolls, wraps text at any width and mirrors for RTL.
$script:ColCheck = 0; $script:ColSetting = 1; $script:ColWhat = 2; $script:ColRisk = 3
$script:ColState = 4; $script:ColPolicy = 5; $script:ColValue = 6
$script:Grids = @{}
$script:GridsDirty = @{}
$script:ShowTechnical = $true

function Get-ItemText {
    param($Item, [ValidateSet('title', 'description')][string]$Part)
    switch ($Item.Kind) {
        'Policy'  { return T "policy.$($Item.Id).$Part" }
        'Task'    { return T "task.$($Item.Id).$Part" }
        'Service' { return T "service.$($Item.Id).$Part" }
        'Host'    { if ($Part -eq 'title') { return T "hosts.$($Item.Id).name" } else { return T "hosts.$($Item.Id).description" } }
    }
    return $Item.Id
}

function Get-ItemRisk {
    param($Item)
    switch ($Item.Kind) {
        'Policy'  { return $Item.Def.Risk }
        'Task'    { return 'high' }
        'Service' { return 'high' }
        'Host'    { return $Item.Def.Risk }
    }
    return 'low'
}

function Get-ItemTechnical {
    param($Item)
    switch ($Item.Kind) {
        'Policy'  { if ($Item.Def.Choices) { return $Item.Id } else { return $Item.Id } }
        'Task'    { return $Item.Def.Pattern }
        'Service' { return $Item.Def.Name }
        'Host'    { return ($Item.Def.Domains -join ', ') }
    }
    return ''
}

function Get-ItemTooltip {
    param($Item)
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add((Get-ItemText $Item 'title'))
    [void]$lines.Add('')
    [void]$lines.Add((Get-ItemText $Item 'description'))
    [void]$lines.Add('')
    switch ($Item.Kind) {
        'Policy' {
            [void]$lines.Add((T "tip.ticked.$($Item.Def.Kind)"))
            [void]$lines.Add((T 'tip.unticked'))
            if ($Item.Def.Lock) { [void]$lines.Add((T 'tip.lock')) }
            [void]$lines.Add('')
            [void]$lines.Add((T 'tip.risk' @((T "risk.$($Item.Def.Risk)"))))
            [void]$lines.Add((T 'tip.policy' @($Item.Id, $Item.Value, $Item.Def.Type)))
        }
        'Task'    { [void]$lines.Add((T 'tip.updater')); [void]$lines.Add((T 'tip.pattern' @($Item.Def.Pattern))) }
        'Service' { [void]$lines.Add((T 'tip.updater')); [void]$lines.Add((T 'tip.service' @($Item.Def.Name))) }
        'Host'    { [void]$lines.Add((T 'tip.hosts')); [void]$lines.Add((T 'tip.domains' @(($Item.Def.Domains -join ', ')))) }
    }
    return ($lines -join "`r`n")
}

# ---- Grid factory --------------------------------------------------------------
function New-SettingsGrid {
    $g = New-Object System.Windows.Forms.DataGridView
    # DoubleBuffered is protected; without it scrolling a styled grid flickers.
    $prop = [System.Windows.Forms.DataGridView].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
    if ($prop) { $prop.SetValue($g, $true, $null) }
    $g.Dock = 'Fill'
    $g.AllowUserToAddRows = $false; $g.AllowUserToDeleteRows = $false; $g.AllowUserToResizeRows = $false; $g.AllowUserToOrderColumns = $false
    $g.RowHeadersVisible = $false
    $g.SelectionMode = 'FullRowSelect'; $g.MultiSelect = $false
    $g.BackgroundColor = $script:Clr.White; $g.BorderStyle = 'None'
    $g.CellBorderStyle = 'SingleHorizontal'; $g.GridColor = (New-Rgb 236 238 242)
    $g.EnableHeadersVisualStyles = $false
    $g.ColumnHeadersHeightSizeMode = 'DisableResizing'; $g.ColumnHeadersHeight = 30
    $g.ColumnHeadersBorderStyle = 'Single'
    $hs = $g.ColumnHeadersDefaultCellStyle
    $hs.BackColor = $script:Clr.Fog; $hs.ForeColor = $script:Clr.Slate; $hs.SelectionBackColor = $script:Clr.Fog; $hs.SelectionForeColor = $script:Clr.Slate
    $hs.Padding = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)
    $ds = $g.DefaultCellStyle
    $ds.BackColor = $script:Clr.White; $ds.ForeColor = $script:Clr.Ink
    $ds.SelectionBackColor = $script:Clr.Selection; $ds.SelectionForeColor = $script:Clr.Ink
    $ds.Padding = New-Object System.Windows.Forms.Padding(4, 6, 4, 6)
    $ds.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
    $g.EditMode = 'EditProgrammatically'
    $g.AutoSizeRowsMode = 'None'
    $g.RowTemplate.Height = 46
    $g.ShowCellToolTips = $true
    $g.ScrollBars = 'Vertical'
    $g.TabStop = $true

    $cCheck = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $cCheck.Width = 40; $cCheck.Resizable = 'False'; $cCheck.Name = 'check'
    $cCheck.DefaultCellStyle.Alignment = 'MiddleCenter'
    $cSetting = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $cSetting.Name = 'setting'; $cSetting.AutoSizeMode = 'Fill'; $cSetting.FillWeight = 30; $cSetting.MinimumWidth = 170
    $cWhat = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $cWhat.Name = 'what'; $cWhat.AutoSizeMode = 'Fill'; $cWhat.FillWeight = 55; $cWhat.MinimumWidth = 220
    $cRisk = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $cRisk.Name = 'risk'; $cRisk.Width = 66; $cRisk.Resizable = 'False'
    $cState = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $cState.Name = 'state'; $cState.Width = 100; $cState.Resizable = 'False'
    $cPolicy = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $cPolicy.Name = 'policy'; $cPolicy.AutoSizeMode = 'Fill'; $cPolicy.FillWeight = 45; $cPolicy.MinimumWidth = 170
    $cValue = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $cValue.Name = 'value'; $cValue.Width = 86
    foreach ($c in @($cCheck, $cSetting, $cWhat, $cRisk, $cState, $cPolicy, $cValue)) {
        $c.SortMode = 'NotSortable'
        if ($c.Name -ne 'check') { $c.ReadOnly = $true }
    }
    $g.Columns.AddRange([System.Windows.Forms.DataGridViewColumn[]]@($cCheck, $cSetting, $cWhat, $cRisk, $cState, $cPolicy, $cValue))
    Set-GridFonts $g
    Update-GridHeaders $g

    # Click on the tick or on the setting name toggles the row; the description
    # column is read-only text so selecting and reading never changes anything.
    $g.Add_CellClick({
        param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        $item = $s.Rows[$e.RowIndex].Tag
        if (-not $item) { return }
        Invoke-Guarded 'Toggle' {
            if ($e.ColumnIndex -eq $script:ColCheck -or $e.ColumnIndex -eq $script:ColSetting) { Toggle-Item $item }
            elseif ($e.ColumnIndex -eq $script:ColValue -and $item.Def.Choices) {
                $s.CurrentCell = $s.Rows[$e.RowIndex].Cells[$script:ColValue]
                [void]$s.BeginEdit($true)
                if ($s.EditingControl -is [System.Windows.Forms.ComboBox]) { $s.EditingControl.DroppedDown = $true }
            }
        }
    })
    $g.Add_CurrentCellDirtyStateChanged({ param($s, $e) if ($s.IsCurrentCellDirty) { [void]$s.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) } })
    $g.Add_CellValueChanged({
        param($s, $e)
        if ($script:SuppressSelectionEvents -or $e.RowIndex -lt 0 -or $e.ColumnIndex -ne $script:ColValue) { return }
        $item = $s.Rows[$e.RowIndex].Tag
        if (-not $item -or -not $item.Def.Choices) { return }
        Invoke-Guarded 'Choice' {
            $label = "$($s.Rows[$e.RowIndex].Cells[$script:ColValue].Value)"
            foreach ($cid in $item.Def.Choices.Keys) {
                if ((T "policy.$($item.Id).choice.$cid") -eq $label) { Set-ItemChoice $item $cid; break }
            }
            Set-CustomMode
            Update-Chrome
        }
    })
    $g.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Space -and $s.CurrentRow -and -not $s.IsCurrentCellInEditMode) {
            $item = $s.CurrentRow.Tag
            if ($item) { Invoke-Guarded 'Toggle' { Toggle-Item $item }; $e.Handled = $true; $e.SuppressKeyPress = $true }
        }
    })
    $g.Add_Resize({ param($s, $e) $script:GridsDirty[$s.Name] = $true; Start-RowHeightTimer })
    return $g
}

function Set-GridFonts {
    param($Grid)
    $Grid.Font = Get-BfoUiFont -Size 9
    $Grid.DefaultCellStyle.Font = Get-BfoUiFont -Size 9
    $Grid.ColumnHeadersDefaultCellStyle.Font = Get-BfoUiFont -Size 8.5 -Semibold
    $Grid.Columns['setting'].DefaultCellStyle.Font = Get-BfoUiFont -Size 9.5 -Semibold
    $Grid.Columns['what'].DefaultCellStyle.ForeColor = $script:Clr.Slate
    $Grid.Columns['policy'].DefaultCellStyle.Font = Get-BfoUiFont -Size 8.5 -Mono
    $Grid.Columns['policy'].DefaultCellStyle.ForeColor = $script:Clr.Slate
    $Grid.Columns['value'].DefaultCellStyle.Font = Get-BfoUiFont -Size 8.5 -Mono
    $Grid.Columns['value'].DefaultCellStyle.ForeColor = $script:Clr.Slate
}

function Update-GridHeaders {
    param($Grid)
    $Grid.Columns['check'].HeaderText   = ''
    $Grid.Columns['setting'].HeaderText = T 'grid.col.setting'
    $Grid.Columns['what'].HeaderText    = T 'grid.col.what'
    $Grid.Columns['risk'].HeaderText    = T 'grid.col.risk'
    $Grid.Columns['state'].HeaderText   = T 'grid.col.status'
    # The column holds a policy name, a domain or a task / service name depending on the page.
    $technicalKey = switch ($Grid.Name) { 'hosts' { 'grid.col.domains' } 'updater' { 'grid.col.name' } default { 'grid.col.policy' } }
    $Grid.Columns['policy'].HeaderText  = T $technicalKey
    $Grid.Columns['value'].HeaderText   = T 'grid.col.value'
    $Grid.Columns['policy'].Visible = $script:ShowTechnical
    $Grid.Columns['value'].Visible  = $script:ShowTechnical
}

# ---- Rows ------------------------------------------------------------------------
function Add-ItemRow {
    param($Grid, $Item)
    $idx = $Grid.Rows.Add($false, '', '', '', '', '', '')
    $row = $Grid.Rows[$idx]
    $row.Tag = $Item
    $Item.Row = $row
    if ($Item.Kind -eq 'Policy' -and $Item.Def.Choices) {
        $combo = New-Object System.Windows.Forms.DataGridViewComboBoxCell
        $combo.FlatStyle = 'Flat'
        $combo.DropDownWidth = 200
        $row.Cells[$script:ColValue] = $combo
    }
    Update-ItemTexts $Item
    Update-ItemView $Item
}

# Text that depends on the language. Also refills a choice combo's items.
function Update-ItemTexts {
    param($Item)
    $row = $Item.Row
    if (-not $row) { return }
    $row.Cells[$script:ColSetting].Value = Get-ItemText $Item 'title'
    $row.Cells[$script:ColWhat].Value    = Get-ItemText $Item 'description'
    $risk = Get-ItemRisk $Item
    $row.Cells[$script:ColRisk].Value    = T "risk.$risk"
    $row.Cells[$script:ColRisk].Style.ForeColor = switch ($risk) { 'high' { $script:Clr.Red } 'medium' { $script:Clr.Amber } default { $script:Clr.Green } }
    $row.Cells[$script:ColPolicy].Value  = Get-ItemTechnical $Item
    $tip = Get-ItemTooltip $Item
    $row.Cells[$script:ColSetting].ToolTipText = $tip
    $row.Cells[$script:ColWhat].ToolTipText    = $tip
    $row.Cells[$script:ColPolicy].ToolTipText  = $tip
    $row.Cells[$script:ColState].ToolTipText   = (T 'tip.status')
    if ($Item.Kind -eq 'Policy' -and $Item.Def.Choices) {
        $cell = $row.Cells[$script:ColValue]
        Push-SuppressSelectionEvents
        try {
            $cell.Items.Clear()
            foreach ($cid in $Item.Def.Choices.Keys) { [void]$cell.Items.Add((T "policy.$($Item.Id).choice.$cid")) }
            $cell.Value = T "policy.$($Item.Id).choice.$(Get-ItemChoiceId $Item)"
        } finally { Pop-SuppressSelectionEvents }
    }
}

# State-dependent cells: the tick, the status word and its colour, the value.
function Update-ItemView {
    param($Item)
    $row = $Item.Row
    if (-not $row) { return }
    $row.Cells[$script:ColCheck].Value = [bool]$Item.Checked
    $state = Get-ItemState $Item
    $Item.Status = $state
    $cell = $row.Cells[$script:ColState]
    $cell.Value = T "state.$state"
    switch ($state) {
        { $_ -in 'active', 'blocked' }                       { $cell.Style.ForeColor = $script:Clr.Green; $cell.Style.Font = Get-BfoUiFont -Size 9; break }
        { $_ -in 'willApply', 'willChange', 'willEnable', 'willBlock' } { $cell.Style.ForeColor = $script:Clr.Blue;  $cell.Style.Font = Get-BfoUiFont -Size 9 -Semibold; break }
        { $_ -in 'willRemove', 'willDisable', 'willUnblock' } { $cell.Style.ForeColor = $script:Clr.Red;   $cell.Style.Font = Get-BfoUiFont -Size 9 -Semibold; break }
        'disabled'                                           { $cell.Style.ForeColor = $script:Clr.Amber;  $cell.Style.Font = Get-BfoUiFont -Size 9; break }
        default                                              { $cell.Style.ForeColor = $script:Clr.Mist;   $cell.Style.Font = Get-BfoUiFont -Size 9 }
    }
    if ($Item.Kind -eq 'Policy') {
        if ($Item.Def.Choices) {
            Push-SuppressSelectionEvents
            try { $row.Cells[$script:ColValue].Value = T "policy.$($Item.Id).choice.$(Get-ItemChoiceId $Item)" }
            finally { Pop-SuppressSelectionEvents }
        } else {
            $row.Cells[$script:ColValue].Value = "= $($Item.Value)"
        }
    }
}

function Update-AllItemViews {
    foreach ($item in $script:Items) { Update-ItemView $item }
}

function Toggle-Item {
    param($Item)
    if (($Item.Kind -eq 'Task' -or $Item.Kind -eq 'Service') -and -not $Item.Loaded) { Import-CurrentSystemState }
    if ($Item.Kind -eq 'Task' -or $Item.Kind -eq 'Service') {
        if ($Item.Detail -eq 0) { Write-Log (T 'log.updater.missing') 'INFO'; return }
    }
    Set-ItemChecked $Item (-not $Item.Checked)
    if ($Item.Kind -eq 'Policy') { Set-CustomMode }
    Update-Chrome
}

# ---- Row heights -------------------------------------------------------------------
# Wrapped descriptions need taller rows; the height depends on the column width
# and the language, so it is recomputed when a grid is shown after a change and
# (throttled) while the window is resized.
$script:RowHeightTimer = $null
function Start-RowHeightTimer {
    if (-not $script:RowHeightTimer) {
        $script:RowHeightTimer = New-Object System.Windows.Forms.Timer
        $script:RowHeightTimer.Interval = 120
        $script:RowHeightTimer.Add_Tick({
            $script:RowHeightTimer.Stop()
            Invoke-Guarded 'Layout' { Update-VisibleGridLayout }
        })
    }
    $script:RowHeightTimer.Stop(); $script:RowHeightTimer.Start()
}

function Update-GridRowHeights {
    param($Grid)
    if (-not $Grid -or -not $Grid.Visible -or $Grid.Width -lt 200) { return }
    $Grid.SuspendLayout()
    try {
        $Grid.AutoResizeRows([System.Windows.Forms.DataGridViewAutoSizeRowsMode]::AllCellsExceptHeaders)
        foreach ($r in $Grid.Rows) { if ($r.Visible -and $r.Height -lt 44) { $r.Height = 44 } }
    } finally { $Grid.ResumeLayout() }
    $script:GridsDirty[$Grid.Name] = $false
}

function Update-VisibleGridLayout {
    $g = $script:CurrentGrid
    if ($g -and $script:GridsDirty[$g.Name]) { Update-GridRowHeights $g }
}

# Very narrow windows: drop the technical columns so the description keeps its room.
function Update-GridColumnVisibility {
    $available = if ($script:PageHost) { $script:PageHost.ClientSize.Width } else { 1000 }
    foreach ($g in $script:Grids.Values) {
        $wide = ($available -ge 900)
        $show = $script:ShowTechnical -and $wide
        $g.Columns['policy'].Visible = $show
        $g.Columns['value'].Visible  = $show
    }
}

# ---- Filter -------------------------------------------------------------------------
# One search over every row of every page (name, description, category), plus
# "selected only". Purely presentational: it hides rows, it never changes a tick.
$script:FilterText = ''
$script:FilterSelectedOnly = $false
function Test-ItemMatchesFilter {
    param($Item, [string[]]$Terms)
    if ($script:FilterSelectedOnly -and -not $Item.Checked) { return $false }
    if ($Terms.Count -eq 0) { return $true }
    $hay = ('{0} {1} {2} {3} {4}' -f $Item.Id, (Get-ItemText $Item 'title'), (Get-ItemText $Item 'description'), (Get-ItemTechnical $Item), (Get-PageTitle $Item.Page)).ToLowerInvariant()
    foreach ($t in $Terms) { if (-not $hay.Contains($t)) { return $false } }
    return $true
}

function Update-Filter {
    $terms = @($script:FilterText.Trim().ToLowerInvariant() -split '\s+' | Where-Object { $_ })
    $filtering = ($terms.Count -gt 0 -or $script:FilterSelectedOnly)
    $script:PageMatchCounts = @{}
    $shown = 0; $total = 0
    foreach ($g in $script:Grids.Values) {
        $g.SuspendLayout()
        try { $g.CurrentCell = $null } catch { }
        foreach ($row in $g.Rows) {
            $item = $row.Tag
            if (-not $item) { continue }
            $total++
            $match = Test-ItemMatchesFilter $item $terms
            if ($row.Visible -ne $match) { $row.Visible = $match }
            if ($match) {
                $shown++
                $script:PageMatchCounts[$item.Page] = 1 + [int]$script:PageMatchCounts[$item.Page]
            }
        }
        $g.ResumeLayout()
        $script:GridsDirty[$g.Name] = $true
    }
    $script:Filtering = $filtering
    if ($script:LblFilterCount) {
        $script:LblFilterCount.Text = if ($filtering) { if ($shown -eq 0) { T 'filter.noMatches' } else { T 'filter.matches' @($shown, $total) } } else { '' }
    }
    Update-NavCounts
    Update-VisibleGridLayout
    # Jump to the first page with a hit, but never away from a page that already has one.
    if ($filtering -and $shown -gt 0 -and $script:CurrentPageId -and -not $script:PageMatchCounts[$script:CurrentPageId]) {
        foreach ($p in $script:PageOrder) { if ($script:PageMatchCounts[$p.Id]) { Select-NavPage $p.Id; break } }
    }
}

$script:FilterTimer = $null
function Start-FilterDebounce {
    if (-not $script:FilterTimer) {
        $script:FilterTimer = New-Object System.Windows.Forms.Timer
        $script:FilterTimer.Interval = 200
        $script:FilterTimer.Add_Tick({ $script:FilterTimer.Stop(); Invoke-Guarded 'Filter' { Update-Filter } })
    }
    $script:FilterTimer.Stop(); $script:FilterTimer.Start()
}
#endregion


#region UI: content frame, navigation, pages ----------------------------------------
$script:PageOrder = @()
foreach ($id in $script:PolicyPageOrder) { $script:PageOrder += @{ Id = $id; Group = 'settings'; Kind = 'grid' } }
$script:PageOrder += @(
    @{ Id = 'updater';    Group = 'advanced'; Kind = 'updater' }
    @{ Id = 'hosts';      Group = 'advanced'; Kind = 'hosts' }
    @{ Id = 'overrides';  Group = 'advanced'; Kind = 'overrides' }
    @{ Id = 'scriptlets'; Group = 'advanced'; Kind = 'scriptlets' }
)
$script:PagePanels = @{}
$script:PageMatchCounts = @{}
$script:CurrentPageId = $null
$script:CurrentGrid = $null
$script:Filtering = $false
$script:NavNodes = @{}

function Get-PageTitle { param([string]$PageId) return (T "page.$PageId.title") }
function Get-PageIntro { param([string]$PageId) return (T "page.$PageId.intro") }

# ---- Top of the content area: page title, one-line help, search, bulk links ------
function New-ContentTop {
    $top = New-Ctl 'Panel' @{ Dock = 'Top'; BackColor = $script:Clr.White; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; Padding = (New-Object System.Windows.Forms.Padding(18, 12, 16, 6)) }
    $table = New-Ctl 'TableLayoutPanel' @{ Dock = 'Top'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; ColumnCount = 2; RowCount = 2; BackColor = $script:Clr.White } $top
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$table.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
    [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
    [void]$table.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))

    $script:LblPageTitle = New-Ctl 'Label' @{ AutoSize = $true; ForeColor = $script:Clr.Ink; BackColor = $script:Clr.White; Margin = (New-Object System.Windows.Forms.Padding(0, 0, 0, 2)) }
    [void](Set-LocFont $script:LblPageTitle -Size 12 -Semibold)
    $table.Controls.Add($script:LblPageTitle, 0, 0)

    $script:LblPageIntro = New-Ctl 'Label' @{ AutoSize = $true; MaximumSize = (New-Object System.Drawing.Size(760, 0)); ForeColor = $script:Clr.Slate; BackColor = $script:Clr.White; Margin = (New-Object System.Windows.Forms.Padding(1, 0, 12, 0)) }
    [void](Set-LocFont $script:LblPageIntro -Size 8.5)
    $table.Controls.Add($script:LblPageIntro, 0, 1)

    $searchBox = New-Ctl 'FlowLayoutPanel' @{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $false; BackColor = $script:Clr.White; Margin = (New-Object System.Windows.Forms.Padding(0)) }
    $script:TxtFilter = New-Ctl 'TextBox' @{ Width = 250; Margin = (New-Object System.Windows.Forms.Padding(0, 0, 4, 0)) } $searchBox
    $script:TxtFilter.Add_TextChanged({
        $script:FilterText = $script:TxtFilter.Text
        $script:LblFilterHint.Visible = ($script:TxtFilter.Text.Length -eq 0 -and -not $script:TxtFilter.Focused)
        Start-FilterDebounce
    })
    [void](Set-LocTooltip $script:TxtFilter 'filter.help')
    # A native TextBox has no placeholder, so a label laid over it says what the box is for until the user focuses or types in it.
    $script:LblFilterHint = New-Ctl 'Label' @{ Dock = 'Fill'; AutoSize = $false; TextAlign = 'MiddleLeft'; ForeColor = $script:Clr.Mist; BackColor = $script:Clr.White; Cursor = [System.Windows.Forms.Cursors]::IBeam } $script:TxtFilter
    [void](Set-Loc $script:LblFilterHint 'filter.placeholder'); [void](Set-LocFont $script:LblFilterHint -Size 9)
    $script:LblFilterHint.Add_Click({ $script:TxtFilter.Focus() })
    $script:TxtFilter.Add_GotFocus({ $script:LblFilterHint.Visible = $false })
    $script:TxtFilter.Add_LostFocus({ $script:LblFilterHint.Visible = ($script:TxtFilter.Text.Length -eq 0) })
    $script:FilterBoxPanel = $searchBox
    $btnClear = New-Ctl 'Button' @{ Text = 'x'; Size = (New-Object System.Drawing.Size(26, 24)); FlatStyle = 'Flat'; BackColor = $script:Clr.White; ForeColor = $script:Clr.Slate; Cursor = [System.Windows.Forms.Cursors]::Hand; UseVisualStyleBackColor = $false; Margin = (New-Object System.Windows.Forms.Padding(0, 0, 0, 0)) } $searchBox
    $btnClear.FlatAppearance.BorderColor = $script:Clr.LineStrong
    $btnClear.RightToLeft = 'No'
    [void](Set-LocTooltip $btnClear 'filter.clear')
    $btnClear.Add_Click({ Clear-Filter })
    $table.Controls.Add($searchBox, 1, 0)

    $opts = New-Ctl 'FlowLayoutPanel' @{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $false; BackColor = $script:Clr.White; Margin = (New-Object System.Windows.Forms.Padding(0, 4, 0, 0)); Anchor = 'Right' }
    $script:ChkSelectedOnly = New-Ctl 'CheckBox' @{ AutoSize = $true; BackColor = $script:Clr.White; Margin = (New-Object System.Windows.Forms.Padding(0, 0, 10, 0)) } $opts
    [void](Set-Loc $script:ChkSelectedOnly 'filter.selectedOnly'); [void](Set-LocFont $script:ChkSelectedOnly -Size 8.5)
    $script:ChkSelectedOnly.Add_CheckedChanged({ $script:FilterSelectedOnly = $script:ChkSelectedOnly.Checked; Invoke-Guarded 'Filter' { Update-Filter } })
    $script:LblFilterCount = New-Ctl 'Label' @{ AutoSize = $true; ForeColor = $script:Clr.Slate; BackColor = $script:Clr.White; Margin = (New-Object System.Windows.Forms.Padding(0, 2, 0, 0)) } $opts
    [void](Set-LocFont $script:LblFilterCount -Size 8.5)
    $table.Controls.Add($opts, 1, 1)
    $script:FilterOptsPanel = $opts

    # Bulk links + technical-details switch, only meaningful on list pages.
    $script:BulkBar = New-Ctl 'FlowLayoutPanel' @{ Dock = 'Top'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $true; BackColor = $script:Clr.White; Padding = (New-Object System.Windows.Forms.Padding(18, 2, 16, 6)) }
    $script:LinkSelectAll = New-Ctl 'LinkLabel' @{ AutoSize = $true; BackColor = $script:Clr.White; LinkColor = $script:Clr.Ember; ActiveLinkColor = $script:Clr.EmberDark; Margin = (New-Object System.Windows.Forms.Padding(1, 0, 14, 0)) } $script:BulkBar
    [void](Set-Loc $script:LinkSelectAll 'policyTab.selectAll'); [void](Set-LocFont $script:LinkSelectAll -Size 8.5)
    $script:LinkSelectAll.Add_LinkClicked({ Invoke-Guarded 'Select all' { Set-PageChecks $true } })
    $script:LinkSelectNone = New-Ctl 'LinkLabel' @{ AutoSize = $true; BackColor = $script:Clr.White; LinkColor = $script:Clr.Ember; ActiveLinkColor = $script:Clr.EmberDark; Margin = (New-Object System.Windows.Forms.Padding(0, 0, 24, 0)) } $script:BulkBar
    [void](Set-Loc $script:LinkSelectNone 'policyTab.selectNone'); [void](Set-LocFont $script:LinkSelectNone -Size 8.5)
    $script:LinkSelectNone.Add_LinkClicked({ Invoke-Guarded 'Select none' { Set-PageChecks $false } })
    $script:ChkTechnical = New-Ctl 'CheckBox' @{ AutoSize = $true; Checked = $script:ShowTechnical; BackColor = $script:Clr.White; Margin = (New-Object System.Windows.Forms.Padding(0, 0, 0, 0)) } $script:BulkBar
    [void](Set-Loc $script:ChkTechnical 'filter.technical'); [void](Set-LocFont $script:ChkTechnical -Size 8.5)
    $script:ChkTechnical.Add_CheckedChanged({
        $script:ShowTechnical = $script:ChkTechnical.Checked
        Set-BfoSetting 'showTechnical' $script:ShowTechnical
        Update-GridColumnVisibility
        foreach ($k in @($script:GridsDirty.Keys)) { $script:GridsDirty[$k] = $true }
        Start-RowHeightTimer
    })
    return @($top, $script:BulkBar)
}

# Select all / none acts on what the user can see, so it composes with the filter.
function Set-PageChecks {
    param([bool]$Checked)
    $grid = $script:CurrentGrid
    if (-not $grid) { return }
    Push-SuppressSelectionEvents
    try {
        foreach ($row in $grid.Rows) {
            if ($row.Visible -and $row.Tag -and $row.Tag.Kind -eq 'Policy') { Set-ItemChecked $row.Tag $Checked }
        }
    } finally { Pop-SuppressSelectionEvents }
    Set-CustomMode
    Update-Chrome
}

function Clear-Filter {
    $script:TxtFilter.Text = ''
    $script:ChkSelectedOnly.Checked = $false
    $script:FilterText = ''
    $script:FilterSelectedOnly = $false
    Update-Filter
}

# ---- Sidebar -----------------------------------------------------------------------
function Build-Nav {
    $tv = $script:Nav
    $tv.BeginUpdate()
    $tv.Nodes.Clear()
    $script:NavNodes = @{}
    $groups = [ordered]@{ settings = 'nav.group.settings'; advanced = 'nav.group.advanced' }
    foreach ($g in $groups.Keys) {
        $parent = $tv.Nodes.Add((T $groups[$g]).ToUpperInvariant())
        $parent.Tag = "group:$g"
        $parent.NodeFont = Get-BfoUiFont -Size 8 -Semibold
        $parent.ForeColor = $script:Clr.Mist
        foreach ($p in ($script:PageOrder | Where-Object { $_.Group -eq $g })) {
            $node = $parent.Nodes.Add($p.Id)
            $node.Tag = $p.Id
            $node.NodeFont = Get-BfoUiFont -Size 9
            $script:NavNodes[$p.Id] = $node
        }
    }
    $tv.ExpandAll()
    $tv.EndUpdate()
    Update-NavCounts
}

function Get-NavCountText {
    param([string]$PageId)
    if ($script:Filtering) { return ('({0})' -f [int]$script:PageMatchCounts[$PageId]) }
    $pageItems = @($script:Items | Where-Object { $_.Page -eq $PageId })
    switch ($PageId) {
        'updater'    { return '' }
        'overrides'  { $n = 0; foreach ($k in 'Search', 'Ntp', 'Startup') { if ($script:Overrides[$k].Enabled) { $n++ } }; return ('{0}/3' -f $n) }
        'scriptlets' { return '' }
    }
    if ($pageItems.Count -eq 0) { return '' }
    return ('{0}/{1}' -f @($pageItems | Where-Object { $_.Checked }).Count, $pageItems.Count)
}

function Update-NavCounts {
    if (-not $script:Nav) { return }
    foreach ($id in $script:NavNodes.Keys) {
        $node = $script:NavNodes[$id]
        $count = Get-NavCountText $id
        $text = Get-PageTitle $id
        if ($count) { $text = "$text   $count" }
        if ($node.Text -ne $text) { $node.Text = $text }
        $node.ForeColor = if ($script:Filtering -and -not $script:PageMatchCounts[$id]) { $script:Clr.Mist } else { $script:Clr.Ink }
    }
}

function Select-NavPage {
    param([string]$PageId)
    if ($script:NavNodes.ContainsKey($PageId)) { $script:Nav.SelectedNode = $script:NavNodes[$PageId] }
}

function Show-Page {
    param([string]$PageId)
    if (-not $PageId -or -not $script:PagePanels.ContainsKey($PageId)) { return }
    if ($PageId -eq 'scriptlets' -and -not $script:ScriptletsBuilt) { Build-ScriptletsPage }
    $script:CurrentPageId = $PageId
    foreach ($id in @($script:PagePanels.Keys)) { $script:PagePanels[$id].Visible = ($id -eq $PageId) }
    $script:LblPageTitle.Text = Get-PageTitle $PageId
    $script:LblPageIntro.Text = Get-PageIntro $PageId
    $isGrid = $script:Grids.ContainsKey($PageId)
    # The search and "Ticked only" cover every list page; the two form-style pages are not indexed, so the controls would do nothing there.
    $hasFilter = ($PageId -ne 'overrides' -and $PageId -ne 'scriptlets')
    $script:FilterBoxPanel.Visible  = $hasFilter
    $script:FilterOptsPanel.Visible = $hasFilter
    $script:BulkBar.Visible = $isGrid -or $PageId -eq 'updater' -or $PageId -eq 'hosts'
    $isPolicyPage = ($script:PolicyPageOrder -contains $PageId)
    $script:LinkSelectAll.Visible = $isPolicyPage
    $script:LinkSelectNone.Visible = $isPolicyPage
    $script:CurrentGrid = if ($isGrid) { $script:Grids[$PageId] } else { $null }
    if ($isGrid) { $script:GridsDirty[$PageId] = $true; Start-RowHeightTimer }
    if ($PageId -eq 'updater' -and -not $script:UpdaterLoaded) { Invoke-Guarded 'Read updater state' { Load-UpdaterState } }
}

# ---- Policy pages -----------------------------------------------------------------------
function New-GridPage {
    param([string]$PageId)
    $panel = New-Ctl 'Panel' @{ Dock = 'Fill'; BackColor = $script:Clr.White; Visible = $false }
    $g = New-SettingsGrid
    $g.Name = $PageId
    $panel.Controls.Add($g)
    $script:Grids[$PageId] = $g
    $g.SuspendLayout()
    foreach ($item in ($script:Items | Where-Object { $_.Page -eq $PageId })) { Add-ItemRow -Grid $g -Item $item }
    $g.ResumeLayout()
    return $panel
}
#endregion


#region UI: combo helpers ---------------------------------------------------------------
# Combo items hold translated labels; the stable id lives in a parallel array and
# is linked by SelectedIndex - the one binding WinForms guarantees for a
# non-data-bound ComboBox, and one that survives re-translation intact.
function Get-ComboId {
    param($Combo, $Ids)
    if (-not $Combo -or -not $Ids) { return $null }
    $i = $Combo.SelectedIndex
    if ($i -lt 0 -or $i -ge @($Ids).Count) { return $null }
    return @($Ids)[$i]
}

function Set-ComboId {
    param($Combo, $Ids, [string]$Id)
    if (-not $Combo -or -not $Ids -or -not $Id) { return $false }
    $arr = @($Ids)
    for ($i = 0; $i -lt $arr.Count; $i++) {
        if ($arr[$i] -eq $Id) { $Combo.SelectedIndex = $i; return $true }
    }
    return $false
}

# Relabelling is Items.Clear() + refill, which drives SelectedIndex to -1 and back;
# both transitions raise SelectedIndexChanged, so handlers are muted meanwhile and
# the previously selected id is restored exactly.
function Set-ComboLabels {
    param($Combo, $Ids, $LabelKeys)
    if (-not $Combo) { return }
    $keep = Get-ComboId -Combo $Combo -Ids $Ids
    Push-SuppressSelectionEvents
    try {
        $Combo.BeginUpdate()
        try {
            $Combo.Items.Clear()
            foreach ($k in @($LabelKeys)) { [void]$Combo.Items.Add((T $k)) }
        } finally { $Combo.EndUpdate() }
        if (-not (Set-ComboId -Combo $Combo -Ids $Ids -Id $keep)) {
            if ($Combo.Items.Count -gt 0) { $Combo.SelectedIndex = 0 }
        }
    } finally { Pop-SuppressSelectionEvents }
}
#endregion

#region UI: updater page ------------------------------------------------------------------
$script:UpdaterLoaded = $false

function New-UpdaterPage {
    $panel = New-Ctl 'Panel' @{ Dock = 'Fill'; BackColor = $script:Clr.White; Visible = $false }
    $g = New-SettingsGrid
    $g.Name = 'updater'
    Update-GridHeaders $g
    $script:Grids['updater'] = $g

    $warn = New-Ctl 'Panel' @{ Dock = 'Top'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; BackColor = $script:Clr.RedSoft; Padding = (New-Object System.Windows.Forms.Padding(18, 10, 16, 10)) }
    $wt = New-Ctl 'TableLayoutPanel' @{ Dock = 'Top'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; ColumnCount = 2; RowCount = 1; BackColor = $script:Clr.RedSoft } $warn
    [void]$wt.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$wt.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
    $lbl = New-Ctl 'Label' @{ AutoSize = $true; MaximumSize = (New-Object System.Drawing.Size(720, 0)); ForeColor = (New-Rgb 130 20 30); BackColor = $script:Clr.RedSoft; Margin = (New-Object System.Windows.Forms.Padding(0, 0, 12, 0)) }
    [void](Set-Loc $lbl 'updater.warning'); [void](Set-LocFont $lbl -Size 9)
    $wt.Controls.Add($lbl, 0, 0)
    $btns = New-Ctl 'FlowLayoutPanel' @{ AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $false; FlowDirection = 'TopDown'; BackColor = $script:Clr.RedSoft }
    $bCheck = New-BfoButton 'updater.checkNow' 'Default' 150
    $bCheck.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    $bCheck.Add_Click({ Invoke-Guarded 'Check for updates' { [void](Open-InBrave 'brave://settings/help') } })
    $bScan = New-BfoButton 'updater.rescan' 'Default' 150
    $bScan.Margin = New-Object System.Windows.Forms.Padding(0)
    $bScan.Add_Click({ Invoke-Guarded 'Read updater state' { Load-UpdaterState -Refresh } })
    $btns.Controls.AddRange([System.Windows.Forms.Control[]]@($bCheck, $bScan))
    $wt.Controls.Add($btns, 1, 0)

    $panel.Controls.Add($g)
    $panel.Controls.Add($warn)
    $g.BringToFront()
    $g.SuspendLayout()
    foreach ($item in ($script:Items | Where-Object { $_.Page -eq 'updater' })) { Add-ItemRow -Grid $g -Item $item }
    $g.ResumeLayout()
    return $panel
}

function Load-UpdaterState {
    param([switch]$Refresh)
    $script:Form.UseWaitCursor = $true
    Write-Log (T 'log.updater.reading') 'INFO'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        Import-CurrentSystemState -Refresh:$Refresh
        $script:UpdaterLoaded = $true
    } finally { $script:Form.UseWaitCursor = $false }
    Update-AllItemViews
    Update-Chrome
}
#endregion

#region UI: hosts page ----------------------------------------------------------------------
function New-HostsPage {
    $panel = New-Ctl 'Panel' @{ Dock = 'Fill'; BackColor = $script:Clr.White; Visible = $false }
    $g = New-SettingsGrid
    $g.Name = 'hosts'
    Update-GridHeaders $g
    $script:Grids['hosts'] = $g

    $warn = New-Ctl 'Panel' @{ Dock = 'Top'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; BackColor = $script:Clr.AmberSoft; Padding = (New-Object System.Windows.Forms.Padding(18, 8, 16, 8)) }
    $wl = New-Ctl 'Label' @{ Dock = 'Top'; AutoSize = $true; MaximumSize = (New-Object System.Drawing.Size(900, 0)); ForeColor = (New-Rgb 110 72 0); BackColor = $script:Clr.AmberSoft } $warn
    [void](Set-Loc $wl 'hostsTab.warn'); [void](Set-LocFont $wl -Size 8.5)

    $bar = New-Ctl 'FlowLayoutPanel' @{ Dock = 'Bottom'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $true; BackColor = $script:Clr.White; Padding = (New-Object System.Windows.Forms.Padding(14, 8, 14, 8)) }
    $script:BtnHostsApply = New-BfoButton 'hostsTab.apply' 'Primary' 150
    $script:BtnHostsApply.Margin = New-Object System.Windows.Forms.Padding(4, 3, 8, 3)
    $bRemove  = New-BfoButton 'hostsTab.remove' 'Danger' 130;  $bRemove.Margin  = New-Object System.Windows.Forms.Padding(4, 3, 8, 3)
    $bLoad    = New-BfoButton 'hostsTab.load' 'Default' 130;   $bLoad.Margin    = New-Object System.Windows.Forms.Padding(4, 3, 8, 3)
    $bPreview = New-BfoButton 'hostsTab.preview' 'Default' 120; $bPreview.Margin = New-Object System.Windows.Forms.Padding(4, 3, 8, 3)
    $bOpen    = New-BfoButton 'hostsTab.open' 'Default' 120;    $bOpen.Margin    = New-Object System.Windows.Forms.Padding(4, 3, 8, 3)
    $bar.Controls.AddRange([System.Windows.Forms.Control[]]@($script:BtnHostsApply, $bRemove, $bLoad, $bPreview, $bOpen))

    $script:BtnHostsApply.Add_Click({ Invoke-Guarded 'Apply hosts blocks' { Invoke-HostsApply } })
    $bRemove.Add_Click({ Invoke-Guarded 'Remove hosts block' { Invoke-HostsRemove } })
    $bLoad.Add_Click({
        Invoke-Guarded 'Read hosts file' {
            Import-CurrentHostsState; Update-HostsCache; Update-AllItemViews; Update-Chrome
            Write-Log ("Hosts state loaded: {0} domain(s) currently blocked." -f $script:HostsCurrent.Count)
        }
    })
    $bPreview.Add_Click({ Invoke-Guarded 'Preview hosts' { Update-HostsCache; Show-TextReport -Title (T 'report.hostsTitle') -Text (New-HostsPlanReport) -DefaultFileName ("brave-free-origin-hosts-preview-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss')) } })
    $bOpen.Add_Click({ Invoke-Guarded 'Open hosts file' { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $script:HostsFile) } })

    $panel.Controls.Add($g)
    $panel.Controls.Add($bar)
    $panel.Controls.Add($warn)
    $g.BringToFront()
    $g.SuspendLayout()
    foreach ($item in ($script:Items | Where-Object { $_.Page -eq 'hosts' })) { Add-ItemRow -Grid $g -Item $item }
    $g.ResumeLayout()
    return $panel
}

function Invoke-HostsApply {
    $domains = @(Get-SelectedHostsDomains)
    if ($domains.Count -eq 0) {
        if ((Show-Message -Text (T 'msg.hosts.noGroups') -Title (T 'msg.title.hosts') -Buttons 'YesNo' -Icon 'Question') -ne 'Yes') { return }
    } else {
        if ((Show-Message -Text (T 'msg.hosts.confirmApply' @($domains.Count, $script:HostsFile)) -Title (T 'msg.title.hosts') -Buttons 'YesNo' -Icon 'Question') -ne 'Yes') { return }
    }
    try {
        Set-HostsManagedDomains -Domains $domains
        Update-HostsCache; Update-AllItemViews; Update-Chrome
        [void](Show-Message -Text (T 'msg.hosts.applied' @($domains.Count)) -Title (T 'msg.title.done'))
    } catch {
        Write-Log "Hosts apply failed: $_" 'ERR'
        [void](Show-Message -Text (T 'msg.failed' @("$($_.Exception.Message)")) -Title (T 'msg.title.error') -Icon 'Error')
    }
}

function Invoke-HostsRemove {
    if ((Show-Message -Text (T 'msg.hosts.confirmRemove') -Title (T 'msg.title.hosts') -Buttons 'YesNo' -Icon 'Warning') -ne 'Yes') { return }
    try {
        Set-HostsManagedDomains -Domains @()
        foreach ($item in $script:Items) { if ($item.Kind -eq 'Host') { Set-ItemChecked $item $false } }
        Update-HostsCache; Update-AllItemViews; Update-Chrome
        [void](Show-Message -Text (T 'msg.hosts.removed') -Title (T 'msg.title.done'))
    } catch {
        Write-Log "Hosts remove failed: $_" 'ERR'
        [void](Show-Message -Text (T 'msg.failed' @("$($_.Exception.Message)")) -Title (T 'msg.title.error') -Icon 'Error')
    }
}
#endregion

#region UI: search engine, new tab and startup page -----------------------------------------
function New-OverridesPage {
    $panel = New-Ctl 'Panel' @{ Dock = 'Fill'; BackColor = $script:Clr.White; Visible = $false; AutoScroll = $true }
    $flow = New-Ctl 'FlowLayoutPanel' @{ Dock = 'Top'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; FlowDirection = 'TopDown'; WrapContents = $false; BackColor = $script:Clr.White; Padding = (New-Object System.Windows.Forms.Padding(14, 6, 14, 14)) } $panel

    function New-Section {
        param([string]$TitleKey)
        $box = New-Object System.Windows.Forms.GroupBox
        $box.AutoSize = $true; $box.AutoSizeMode = 'GrowAndShrink'
        $box.Width = 860; $box.MinimumSize = New-Object System.Drawing.Size(860, 0)
        $box.Margin = New-Object System.Windows.Forms.Padding(4, 4, 4, 10)
        $box.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 10)
        [void](Set-Loc $box $TitleKey); [void](Set-LocFont $box -Size 9 -Semibold)
        $t = New-Object System.Windows.Forms.TableLayoutPanel
        $t.Dock = 'Top'; $t.AutoSize = $true; $t.AutoSizeMode = 'GrowAndShrink'; $t.ColumnCount = 4
        [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
        [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
        [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
        [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
        $box.Controls.Add($t)
        return @{ Box = $box; Table = $t }
    }
    function Add-Lbl { param($Table, [string]$Key, [int]$Col, [int]$Row)
        $l = New-Object System.Windows.Forms.Label; $l.AutoSize = $true; $l.Margin = New-Object System.Windows.Forms.Padding(0, 6, 8, 0)
        [void](Set-Loc $l $Key); [void](Set-LocFont $l -Size 9)
        $Table.Controls.Add($l, $Col, $Row); return $l }

    # -- search engine
    $s = New-Section 'searchTab.secSearch'
    $script:ChkSearchOverride = New-Object System.Windows.Forms.CheckBox
    $script:ChkSearchOverride.AutoSize = $true; $script:ChkSearchOverride.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 6)
    [void](Set-Loc $script:ChkSearchOverride 'searchTab.chkSearch'); [void](Set-LocFont $script:ChkSearchOverride -Size 9)
    $s.Table.Controls.Add($script:ChkSearchOverride, 0, 0); $s.Table.SetColumnSpan($script:ChkSearchOverride, 4)
    [void](Add-Lbl $s.Table 'searchTab.engineLabel' 0 1)
    $script:CmbSearchEngine = New-Object System.Windows.Forms.ComboBox
    $script:CmbSearchEngine.DropDownStyle = 'DropDownList'; $script:CmbSearchEngine.Width = 200; $script:CmbSearchEngine.Margin = New-Object System.Windows.Forms.Padding(0, 2, 16, 0)
    $s.Table.Controls.Add($script:CmbSearchEngine, 1, 1)
    [void](Add-Lbl $s.Table 'searchTab.customLabel' 2 1)
    $script:TxtCustomSearchUrl = New-Object System.Windows.Forms.TextBox
    $script:TxtCustomSearchUrl.Dock = 'Fill'; $script:TxtCustomSearchUrl.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0); $script:TxtCustomSearchUrl.Font = Get-BfoUiFont -Size 8.5 -Mono
    $s.Table.Controls.Add($script:TxtCustomSearchUrl, 3, 1)
    $help = New-Object System.Windows.Forms.Label; $help.AutoSize = $true; $help.ForeColor = $script:Clr.Slate; $help.MaximumSize = New-Object System.Drawing.Size(800, 0); $help.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    [void](Set-Loc $help 'searchTab.searchHelp'); [void](Set-LocFont $help -Size 8.5)
    $s.Table.Controls.Add($help, 0, 2); $s.Table.SetColumnSpan($help, 4)
    $flow.Controls.Add($s.Box)

    # -- new tab page
    $n = New-Section 'searchTab.secNtp'
    $script:ChkNtpOverride = New-Object System.Windows.Forms.CheckBox
    $script:ChkNtpOverride.AutoSize = $true; $script:ChkNtpOverride.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 6)
    [void](Set-Loc $script:ChkNtpOverride 'searchTab.chkNtp'); [void](Set-LocFont $script:ChkNtpOverride -Size 9)
    $n.Table.Controls.Add($script:ChkNtpOverride, 0, 0); $n.Table.SetColumnSpan($script:ChkNtpOverride, 4)
    [void](Add-Lbl $n.Table 'searchTab.ntpOpenLabel' 0 1)
    $script:CmbNtpDest = New-Object System.Windows.Forms.ComboBox
    $script:CmbNtpDest.DropDownStyle = 'DropDownList'; $script:CmbNtpDest.Width = 300; $script:CmbNtpDest.Margin = New-Object System.Windows.Forms.Padding(0, 2, 16, 0)
    $n.Table.Controls.Add($script:CmbNtpDest, 1, 1)
    [void](Add-Lbl $n.Table 'searchTab.ntpCustomLabel' 2 1)
    $script:TxtNtpCustomUrl = New-Object System.Windows.Forms.TextBox
    $script:TxtNtpCustomUrl.Dock = 'Fill'; $script:TxtNtpCustomUrl.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0); $script:TxtNtpCustomUrl.Font = Get-BfoUiFont -Size 8.5 -Mono
    $n.Table.Controls.Add($script:TxtNtpCustomUrl, 3, 1)
    $flow.Controls.Add($n.Box)

    # -- startup
    $st = New-Section 'searchTab.secStartup'
    $script:ChkStartupOverride = New-Object System.Windows.Forms.CheckBox
    $script:ChkStartupOverride.AutoSize = $true; $script:ChkStartupOverride.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 6)
    [void](Set-Loc $script:ChkStartupOverride 'searchTab.chkStartup'); [void](Set-LocFont $script:ChkStartupOverride -Size 9)
    $st.Table.Controls.Add($script:ChkStartupOverride, 0, 0); $st.Table.SetColumnSpan($script:ChkStartupOverride, 4)
    [void](Add-Lbl $st.Table 'searchTab.modeLabel' 0 1)
    $script:CmbStartupMode = New-Object System.Windows.Forms.ComboBox
    $script:CmbStartupMode.DropDownStyle = 'DropDownList'; $script:CmbStartupMode.Width = 300; $script:CmbStartupMode.Margin = New-Object System.Windows.Forms.Padding(0, 2, 16, 0)
    $st.Table.Controls.Add($script:CmbStartupMode, 1, 1)
    [void](Add-Lbl $st.Table 'searchTab.urlLabel' 2 1)
    $script:TxtStartupUrl = New-Object System.Windows.Forms.TextBox
    $script:TxtStartupUrl.Dock = 'Fill'; $script:TxtStartupUrl.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 0); $script:TxtStartupUrl.Font = Get-BfoUiFont -Size 8.5 -Mono
    $st.Table.Controls.Add($script:TxtStartupUrl, 3, 1)
    $sh = New-Object System.Windows.Forms.Label; $sh.AutoSize = $true; $sh.ForeColor = $script:Clr.Slate; $sh.MaximumSize = New-Object System.Drawing.Size(800, 0); $sh.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
    [void](Set-Loc $sh 'searchTab.startupHelp'); [void](Set-LocFont $sh -Size 8.5)
    $st.Table.Controls.Add($sh, 0, 2); $st.Table.SetColumnSpan($sh, 4)
    $flow.Controls.Add($st.Box)

    $note = New-Object System.Windows.Forms.Label
    $note.AutoSize = $true; $note.MaximumSize = New-Object System.Drawing.Size(860, 0); $note.ForeColor = (New-Rgb 120 60 30); $note.Margin = New-Object System.Windows.Forms.Padding(6, 0, 0, 12)
    [void](Set-Loc $note 'searchTab.conflictNote'); [void](Set-LocFont $note -Size 8.5)
    $flow.Controls.Add($note)

    # -- extensions / shortcuts (these open Brave; nothing is force-installed)
    $ex = New-Section 'ext.section'
    $intro = New-Object System.Windows.Forms.Label; $intro.AutoSize = $true; $intro.MaximumSize = New-Object System.Drawing.Size(800, 0); $intro.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
    [void](Set-Loc $intro 'ext.intro'); [void](Set-LocFont $intro -Size 8.5)
    $ex.Table.Controls.Add($intro, 0, 0); $ex.Table.SetColumnSpan($intro, 4)
    $warn = New-Object System.Windows.Forms.Label; $warn.AutoSize = $true; $warn.MaximumSize = New-Object System.Drawing.Size(800, 0); $warn.ForeColor = (New-Rgb 130 70 20); $warn.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 8)
    [void](Set-Loc $warn 'ext.warn'); [void](Set-LocFont $warn -Size 8.5)
    $ex.Table.Controls.Add($warn, 0, 1); $ex.Table.SetColumnSpan($warn, 4)
    $row = New-Object System.Windows.Forms.FlowLayoutPanel; $row.AutoSize = $true; $row.WrapContents = $true; $row.Margin = New-Object System.Windows.Forms.Padding(0)
    $bUbo = New-BfoButton 'ext.uboLite' 'Default' 200
    $bUbo.Add_Click({ Invoke-Guarded 'Open uBlock Origin Lite' { [void](Open-InBrave 'https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh') } })
    $bShields = New-BfoButton 'ext.shields' 'Default' 200
    $bShields.Add_Click({ Invoke-Guarded 'Open Shields settings' { [void](Open-InBrave 'brave://settings/shields') } })
    $bBit = New-BfoButton 'ext.bitwarden' 'Default' 200
    $bBit.Add_Click({ Invoke-Guarded 'Open Bitwarden' { [void](Open-InBrave 'https://chromewebstore.google.com/detail/bitwarden-password-manage/nngceckbapebfimnlniiiahkandclblb') } })
    $row.Controls.AddRange([System.Windows.Forms.Control[]]@($bUbo, $bShields, $bBit))
    $ex.Table.Controls.Add($row, 0, 2); $ex.Table.SetColumnSpan($row, 4)
    $flow.Controls.Add($ex.Box)

    # combo contents + wiring
    Set-ComboLabels -Combo $script:CmbSearchEngine -Ids $script:SearchEngineIds -LabelKeys $script:SearchEngineLabelKeys
    Set-ComboLabels -Combo $script:CmbNtpDest      -Ids $script:DestinationIds  -LabelKeys $script:DestinationLabelKeys
    Set-ComboLabels -Combo $script:CmbStartupMode  -Ids $script:StartupModeIds  -LabelKeys $script:StartupModeLabelKeys

    $script:ChkSearchOverride.Add_CheckedChanged({ if (-not $script:SuppressSelectionEvents) { $script:Overrides.Search.Enabled = $script:ChkSearchOverride.Checked; Update-OverrideControlStates; Update-Chrome } })
    $script:CmbSearchEngine.Add_SelectedIndexChanged({ if (-not $script:SuppressSelectionEvents) { $script:Overrides.Search.EngineId = Get-ComboId $script:CmbSearchEngine $script:SearchEngineIds; Update-OverrideControlStates; Update-Chrome } })
    $script:TxtCustomSearchUrl.Add_TextChanged({ if (-not $script:SuppressSelectionEvents) { $script:Overrides.Search.CustomUrl = $script:TxtCustomSearchUrl.Text; Update-Chrome } })
    $script:ChkNtpOverride.Add_CheckedChanged({ if (-not $script:SuppressSelectionEvents) { $script:Overrides.Ntp.Enabled = $script:ChkNtpOverride.Checked; Update-OverrideControlStates; Update-Chrome } })
    $script:CmbNtpDest.Add_SelectedIndexChanged({ if (-not $script:SuppressSelectionEvents) { $script:Overrides.Ntp.DestinationId = Get-ComboId $script:CmbNtpDest $script:DestinationIds; Update-OverrideControlStates; Update-Chrome } })
    $script:TxtNtpCustomUrl.Add_TextChanged({ if (-not $script:SuppressSelectionEvents) { $script:Overrides.Ntp.CustomUrl = $script:TxtNtpCustomUrl.Text; Update-Chrome } })
    $script:ChkStartupOverride.Add_CheckedChanged({ if (-not $script:SuppressSelectionEvents) { $script:Overrides.Startup.Enabled = $script:ChkStartupOverride.Checked; Update-OverrideControlStates; Update-Chrome } })
    $script:CmbStartupMode.Add_SelectedIndexChanged({ if (-not $script:SuppressSelectionEvents) { $script:Overrides.Startup.ModeId = Get-ComboId $script:CmbStartupMode $script:StartupModeIds; Update-OverrideControlStates; Update-Chrome } })
    $script:TxtStartupUrl.Add_TextChanged({ if (-not $script:SuppressSelectionEvents) { $script:Overrides.Startup.Urls = $script:TxtStartupUrl.Text; Update-Chrome } })
    Sync-OverrideControls
    return $panel
}

# Custom-URL boxes are enabled purely as a function of the model: derived state,
# safe to recompute at any time (after import, load, or a language switch).
function Update-OverrideControlStates {
    if (-not $script:TxtCustomSearchUrl) { return }
    $script:TxtCustomSearchUrl.Enabled = ($script:Overrides.Search.Enabled -and $script:Overrides.Search.EngineId -eq 'custom')
    $script:CmbSearchEngine.Enabled    = $script:Overrides.Search.Enabled
    $script:TxtNtpCustomUrl.Enabled    = ($script:Overrides.Ntp.Enabled -and $script:Overrides.Ntp.DestinationId -eq 'custom')
    $script:CmbNtpDest.Enabled         = $script:Overrides.Ntp.Enabled
    $mode = $script:StartupModes[$script:Overrides.Startup.ModeId]
    $script:TxtStartupUrl.Enabled      = ($script:Overrides.Startup.Enabled -and $mode -and $mode.UsesURL -and -not $mode.FixedURL)
    $script:CmbStartupMode.Enabled     = $script:Overrides.Startup.Enabled
}

function Sync-OverrideControls {
    if (-not $script:ChkSearchOverride) { return }
    Push-SuppressSelectionEvents
    try {
        $script:ChkSearchOverride.Checked = [bool]$script:Overrides.Search.Enabled
        [void](Set-ComboId $script:CmbSearchEngine $script:SearchEngineIds $script:Overrides.Search.EngineId)
        $script:TxtCustomSearchUrl.Text = "$($script:Overrides.Search.CustomUrl)"
        $script:ChkNtpOverride.Checked = [bool]$script:Overrides.Ntp.Enabled
        [void](Set-ComboId $script:CmbNtpDest $script:DestinationIds $script:Overrides.Ntp.DestinationId)
        $script:TxtNtpCustomUrl.Text = "$($script:Overrides.Ntp.CustomUrl)"
        $script:ChkStartupOverride.Checked = [bool]$script:Overrides.Startup.Enabled
        [void](Set-ComboId $script:CmbStartupMode $script:StartupModeIds $script:Overrides.Startup.ModeId)
        $script:TxtStartupUrl.Text = "$($script:Overrides.Startup.Urls)"
    } finally { Pop-SuppressSelectionEvents }
    Update-OverrideControlStates
}
#endregion


#region UI: scriptlets page (expert) ----------------------------------------------------
# Optional expert tool: view Brave's built-in adblock scriptlet rules and comment
# individual rules out. It is never touched by a preset or by Apply.
$script:ScriptletsBuilt = $false
$script:ScriptletsPanel = $null

function New-ScriptletsPage {
    # Only the empty container exists at startup; Build-ScriptletsPage fills it the
    # first time the page is opened, so the list view costs nothing until needed.
    $panel = New-Ctl 'Panel' @{ Dock = 'Fill'; BackColor = $script:Clr.White; Visible = $false }
    $script:ScriptletsPanel = $panel
    return $panel
}

function New-ScriptletButton {
    param([string]$Key, [int]$Width, [string]$Style = 'Default')
    $b = New-BfoButton $Key $Style $Width
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 6)
    return $b
}

function Build-ScriptletsPage {
    if ($script:ScriptletsBuilt) { return }
    $panel = $script:ScriptletsPanel
    $panel.SuspendLayout()
    # The page keeps a usable minimum height and scrolls when the window is shorter.
    $panel.AutoScroll = $true
    $panel.AutoScrollMinSize = New-Object System.Drawing.Size(760, 520)
    $t = New-Ctl 'TableLayoutPanel' @{ Dock = 'Fill'; ColumnCount = 1; RowCount = 6; BackColor = $script:Clr.White; Padding = (New-Object System.Windows.Forms.Padding(14, 4, 14, 8)) } $panel
    [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    foreach ($h in 'AutoSize', 'AutoSize', 'AutoSize', 'Percent', 'AutoSize', 'AutoSize') {
        if ($h -eq 'Percent') { [void]$t.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100))) }
        else { [void]$t.RowStyles.Add((New-Object System.Windows.Forms.RowStyle($h))) }
    }

    # 0 - risk banner
    $risk = New-Ctl 'Label' @{ AutoSize = $true; MaximumSize = (New-Object System.Drawing.Size(1000, 0)); ForeColor = (New-Rgb 130 70 20); BackColor = $script:Clr.AmberSoft; Padding = (New-Object System.Windows.Forms.Padding(8, 6, 8, 6)); Margin = (New-Object System.Windows.Forms.Padding(0, 0, 0, 8)); Dock = 'Fill' }
    [void](Set-Loc $risk 'scriptlet.risk'); [void](Set-LocFont $risk -Size 8.5 -Semibold)
    $t.Controls.Add($risk, 0, 0)

    # 1 - folder row
    $rootRow = New-Ctl 'TableLayoutPanel' @{ Dock = 'Fill'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; ColumnCount = 6; RowCount = 1; BackColor = $script:Clr.White }
    [void]$rootRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
    [void]$rootRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    foreach ($i in 1..4) { [void]$rootRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize'))) }
    $lblRoot = New-Ctl 'Label' @{ AutoSize = $true; Margin = (New-Object System.Windows.Forms.Padding(0, 8, 8, 0)) }
    [void](Set-Loc $lblRoot 'scriptlet.rootLabel'); [void](Set-LocFont $lblRoot -Size 9)
    $rootRow.Controls.Add($lblRoot, 0, 0)
    $script:TxtScriptletRoot = New-Ctl 'TextBox' @{ Dock = 'Fill'; Margin = (New-Object System.Windows.Forms.Padding(0, 4, 8, 0)); Text = (Get-ScriptletDefaultRoot) }
    $script:TxtScriptletRoot.Font = Get-BfoUiFont -Size 8.5 -Mono
    $rootRow.Controls.Add($script:TxtScriptletRoot, 1, 0)
    $bAuto = New-ScriptletButton 'scriptlet.autoPath' 80
    $bAuto.Add_Click({ Invoke-Guarded 'Auto path' { $script:TxtScriptletRoot.Text = Get-ScriptletDefaultRoot; Write-Log "Scriptlet User Data path set to: $($script:TxtScriptletRoot.Text)" } })
    $bBrowse = New-ScriptletButton 'scriptlet.browse' 80
    $bBrowse.Add_Click({
        Invoke-Guarded 'Browse' {
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = T 'dialog.browseUserData'
            if (Test-Path -LiteralPath $script:TxtScriptletRoot.Text) { $dlg.SelectedPath = $script:TxtScriptletRoot.Text }
            if ($dlg.ShowDialog() -eq 'OK') { $script:TxtScriptletRoot.Text = $dlg.SelectedPath; Write-Log "Scriptlet User Data path set manually: $($dlg.SelectedPath)" }
        }
    })
    $script:BtnScriptletScan = New-ScriptletButton 'scriptlet.scan' 80 'Primary'
    $script:BtnScriptletScan.Add_Click({ Invoke-Guarded 'Scan' { Invoke-ScriptletScan } })
    $bOpen = New-ScriptletButton 'scriptlet.openFolder' 100
    $bOpen.Add_Click({
        Invoke-Guarded 'Open folder' {
            if (Test-Path -LiteralPath $script:TxtScriptletRoot.Text) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:TxtScriptletRoot.Text) }
            else { [void](Show-Message -Text (T 'msg.scriptlet.folderMissing') -Title (T 'msg.title.scriptlet') -Icon 'Warning') }
        }
    })
    $rootRow.Controls.Add($bAuto, 2, 0); $rootRow.Controls.Add($bBrowse, 3, 0); $rootRow.Controls.Add($script:BtnScriptletScan, 4, 0); $rootRow.Controls.Add($bOpen, 5, 0)
    $t.Controls.Add($rootRow, 0, 1)

    # 2 - search row
    $searchRow = New-Ctl 'FlowLayoutPanel' @{ Dock = 'Fill'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $true; BackColor = $script:Clr.White }
    $lblSearch = New-Ctl 'Label' @{ AutoSize = $true; Margin = (New-Object System.Windows.Forms.Padding(0, 8, 8, 0)) } $searchRow
    [void](Set-Loc $lblSearch 'scriptlet.searchLabel'); [void](Set-LocFont $lblSearch -Size 9)
    $script:TxtScriptletSearch = New-Ctl 'TextBox' @{ Width = 300; Margin = (New-Object System.Windows.Forms.Padding(0, 4, 8, 0)) } $searchRow
    $script:TxtScriptletSearch.Font = Get-BfoUiFont -Size 8.5 -Mono
    $script:TxtScriptletSearch.Add_TextChanged({ Start-ScriptletFilterDelay })
    $script:TxtScriptletSearch.Add_KeyDown({
        if ($_.KeyCode -eq 'Enter') {
            if ($script:ScriptletFilterTimer) { $script:ScriptletFilterTimer.Stop() }
            Update-ScriptletListView
            $_.SuppressKeyPress = $true
        }
    })
    $script:BtnScriptletFilter = New-ScriptletButton 'scriptlet.filter' 70
    $script:BtnScriptletFilter.Add_Click({ Invoke-Guarded 'Filter' { if ($script:ScriptletFilterTimer) { $script:ScriptletFilterTimer.Stop() }; Update-ScriptletListView } })
    $searchRow.Controls.Add($script:BtnScriptletFilter)
    $script:ChkScriptletDisabledOnly = New-Ctl 'CheckBox' @{ AutoSize = $true; Margin = (New-Object System.Windows.Forms.Padding(8, 6, 12, 0)) } $searchRow
    [void](Set-Loc $script:ChkScriptletDisabledOnly 'scriptlet.disabledOnly'); [void](Set-LocFont $script:ChkScriptletDisabledOnly -Size 9)
    $script:ChkScriptletDisabledOnly.Add_CheckedChanged({ Update-ScriptletListView })
    $t.Controls.Add($searchRow, 0, 2)

    $script:ScriptletFilterTimer = New-Object System.Windows.Forms.Timer
    $script:ScriptletFilterTimer.Interval = 250
    $script:ScriptletFilterTimer.Add_Tick({ $script:ScriptletFilterTimer.Stop(); Invoke-Guarded 'Filter' { Update-ScriptletListView } })

    # 3 - the list
    $lv = New-Ctl 'ListView' @{ Dock = 'Fill'; View = 'Details'; FullRowSelect = $true; GridLines = $true; MultiSelect = $true; HideSelection = $false; CheckBoxes = $true; Margin = (New-Object System.Windows.Forms.Padding(0, 6, 0, 6)) }
    $script:ScriptletList = $lv
    $lv.Add_SizeChanged({ Resize-ScriptletColumns })
    $lv.Add_ItemChecked({
        param($sender, $e)
        if (-not $script:SuppressScriptletStatusEvents) {
            Set-ScriptletRecordChecked -Record $e.Item.Tag -Checked $e.Item.Checked
            Update-ScriptletStatusText
        }
    })
    foreach ($col in @(@('scriptlet.col.pick', 96), @('scriptlet.col.domain', 190), @('scriptlet.col.scriptlet', 190), @('scriptlet.col.arguments', 260), @('scriptlet.col.source', 180), @('scriptlet.col.line', 55), @('scriptlet.col.rawRule', 520))) {
        [void]$lv.Columns.Add((T $col[0]), $col[1])
    }
    $t.Controls.Add($lv, 0, 3)

    # 4 - status + progress
    $statusRow = New-Ctl 'TableLayoutPanel' @{ Dock = 'Fill'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; ColumnCount = 2; RowCount = 1; BackColor = $script:Clr.White }
    [void]$statusRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$statusRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 320)))
    $script:LblScriptletStatus = New-Ctl 'Label' @{ AutoSize = $true; ForeColor = $script:Clr.Slate; Margin = (New-Object System.Windows.Forms.Padding(0, 2, 8, 0)); MaximumSize = (New-Object System.Drawing.Size(900, 0)) }
    [void](Set-Loc $script:LblScriptletStatus 'scriptlet.statusIdle'); [void](Set-LocFont $script:LblScriptletStatus -Size 9)
    $statusRow.Controls.Add($script:LblScriptletStatus, 0, 0)
    $script:ScriptletProgress = New-Ctl 'ProgressBar' @{ Dock = 'Fill'; Minimum = 0; Maximum = 1000; Value = 0; Style = 'Continuous'; Margin = (New-Object System.Windows.Forms.Padding(0, 4, 0, 4)) }
    $statusRow.Controls.Add($script:ScriptletProgress, 1, 0)
    $t.Controls.Add($statusRow, 0, 4)

    # 5 - actions
    $actions = New-Ctl 'FlowLayoutPanel' @{ Dock = 'Fill'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $true; BackColor = $script:Clr.White }
    $script:ChkScriptletAdvanced = New-Ctl 'CheckBox' @{ AutoSize = $true; ForeColor = (New-Rgb 150 60 60); Margin = (New-Object System.Windows.Forms.Padding(0, 6, 16, 0)) } $actions
    [void](Set-Loc $script:ChkScriptletAdvanced 'scriptlet.advancedMode'); [void](Set-LocFont $script:ChkScriptletAdvanced -Size 9)
    $script:ChkScriptletAffectDuplicates = New-Ctl 'CheckBox' @{ AutoSize = $true; Checked = $true; Margin = (New-Object System.Windows.Forms.Padding(0, 6, 12, 0)) } $actions
    [void](Set-Loc $script:ChkScriptletAffectDuplicates 'scriptlet.affectDupes'); [void](Set-LocFont $script:ChkScriptletAffectDuplicates -Size 9)
    [void](Set-LocTooltip $script:ChkScriptletAffectDuplicates 'scriptlet.tipAffectDupes')
    $script:BtnScriptletCheckVisible = New-ScriptletButton 'scriptlet.checkFiltered' 120
    $script:BtnScriptletCheckVisible.Add_Click({ Invoke-Guarded 'Check filtered' { Set-ScriptletVisibleChecks $true } })
    [void](Set-LocTooltip $script:BtnScriptletCheckVisible 'scriptlet.tipCheckFiltered')
    $script:BtnScriptletClearChecks = New-ScriptletButton 'scriptlet.clearChecks' 100
    $script:BtnScriptletClearChecks.Add_Click({ Invoke-Guarded 'Clear checks' { Set-ScriptletVisibleChecks $false } })
    $script:BtnScriptletDisable = New-ScriptletButton 'scriptlet.disableChecked' 120 'Danger'
    $script:BtnScriptletDisable.Add_Click({ Invoke-Guarded 'Disable scriptlets' { Invoke-ScriptletDisable } })
    $script:BtnScriptletEnable = New-ScriptletButton 'scriptlet.enableChecked' 120
    $script:BtnScriptletEnable.Add_Click({ Invoke-Guarded 'Enable scriptlets' { Invoke-ScriptletEnable } })
    $bDetails = New-ScriptletButton 'scriptlet.viewSelected' 110
    $bDetails.Add_Click({ Invoke-Guarded 'View scriptlet' { Show-ScriptletDetails } })
    $bBackup = New-ScriptletButton 'scriptlet.backupAll' 120
    $bBackup.Add_Click({ Invoke-Guarded 'Backup scriptlets' { Invoke-ScriptletBackupAll } })
    $bRestoreSel = New-ScriptletButton 'scriptlet.restoreSelected' 150
    $bRestoreSel.Add_Click({ Invoke-Guarded 'Restore scriptlets' { Invoke-ScriptletRestoreSelected } })
    $bRestoreAll = New-ScriptletButton 'scriptlet.restoreAll' 140
    $bRestoreAll.Add_Click({ Invoke-Guarded 'Restore scriptlets' { Invoke-ScriptletRestoreAll } })
    $bCsv = New-ScriptletButton 'scriptlet.exportCsv' 130
    $bCsv.Add_Click({ Invoke-Guarded 'Export CSV' { Invoke-ScriptletExportCsv } })
    $bExportPrefs = New-ScriptletButton 'scriptlet.exportPrefs' 140
    $bExportPrefs.Add_Click({ Invoke-Guarded 'Export preferences' { Invoke-ScriptletExportPrefs } })
    $script:BtnScriptletImportPrefs = New-ScriptletButton 'scriptlet.importPrefs' 160
    $script:BtnScriptletImportPrefs.Add_Click({ Invoke-Guarded 'Import preferences' { Invoke-ScriptletImportPrefs } })
    $actions.Controls.AddRange([System.Windows.Forms.Control[]]@($script:BtnScriptletCheckVisible, $script:BtnScriptletClearChecks, $script:BtnScriptletDisable, $script:BtnScriptletEnable, $bDetails, $bBackup, $bRestoreSel, $bRestoreAll, $bCsv, $bExportPrefs, $script:BtnScriptletImportPrefs))
    $t.Controls.Add($actions, 0, 5)


    $panel.ResumeLayout($true)
    $script:ScriptletsBuilt = $true
    Update-ScriptletLocalizedText
}

# ---- Button actions (same behaviour as before, now testable functions) ---------------
function Invoke-ScriptletDisable {
    $records = @(Get-SelectedScriptletRecords)
    if ($records.Count -eq 0) { [void](Show-Message -Text (T 'msg.scriptlet.selectFirst') -Title (T 'msg.title.scriptlet')); return }
    if (-not (Test-ScriptletAdvancedWriteAllowed)) { return }
    $ans = Show-Message -Text (T 'msg.scriptlet.confirmDisable' @($records.Count, $script:ScriptletDisablePrefix)) -Title (T 'msg.title.scriptlet') -Buttons 'YesNo' -Icon 'Warning'
    if ($ans -ne 'Yes') { return }
    try {
        $changed = Set-ScriptletRuleState -Records $records -Enable:$false -AffectDuplicates:$script:ChkScriptletAffectDuplicates.Checked
        Write-Log "Scriptlets disabled: $changed line(s)." 'OK'
        Invoke-ScriptletScan
    } catch {
        Write-Log "Scriptlet disable failed: $_" 'ERR'
        [void](Show-Message -Text (T 'msg.scriptlet.disableFailed' @("$_")) -Title (T 'msg.title.scriptlet') -Icon 'Error')
    }
}

function Invoke-ScriptletEnable {
    $records = @(Get-SelectedScriptletRecords)
    if ($records.Count -eq 0) { [void](Show-Message -Text (T 'msg.scriptlet.selectFirst') -Title (T 'msg.title.scriptlet')); return }
    if (-not (Test-ScriptletAdvancedWriteAllowed)) { return }
    try {
        $changed = Set-ScriptletRuleState -Records $records -Enable:$true -AffectDuplicates:$script:ChkScriptletAffectDuplicates.Checked
        Write-Log "Scriptlets enabled: $changed line(s)." 'OK'
        Invoke-ScriptletScan
    } catch {
        Write-Log "Scriptlet enable failed: $_" 'ERR'
        [void](Show-Message -Text (T 'msg.scriptlet.enableFailed' @("$_")) -Title (T 'msg.title.scriptlet') -Icon 'Error')
    }
}

function Show-ScriptletDetails {
    $records = @(Get-SelectedScriptletRecords)
    if ($records.Count -eq 0) { [void](Show-Message -Text (T 'msg.scriptlet.selectOne') -Title (T 'msg.title.scriptlet')); return }
    $report = New-Object System.Text.StringBuilder
    foreach ($r in $records) {
        [void]$report.AppendLine("Enabled: $($r.Enabled)")
        [void]$report.AppendLine("Domain: $($r.Domain)")
        [void]$report.AppendLine("Scriptlet: $($r.Scriptlet)")
        [void]$report.AppendLine("Arguments: $($r.Arguments)")
        [void]$report.AppendLine("Source: $($r.Source) $($r.Version)")
        [void]$report.AppendLine("File: $($r.File)")
        [void]$report.AppendLine("Line: $($r.LineNumber)")
        [void]$report.AppendLine("Rule: $($r.Rule)")
        [void]$report.AppendLine('')
    }
    Show-TextReport -Title (T 'report.scriptletTitle') -Text ($report.ToString()) -DefaultFileName ("brave-free-origin-scriptlet-details-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Invoke-ScriptletBackupAll {
    try {
        $files = @($script:ScriptletRules | Select-Object -ExpandProperty File -Unique)
        if ($files.Count -eq 0) { [void](Show-Message -Text (T 'msg.scriptlet.scanFirst') -Title (T 'msg.title.scriptlet')); return }
        foreach ($file in $files) { [void](Backup-ScriptletFile -File $file) }
        [void](Show-Message -Text (T 'msg.scriptlet.backupDone' @($files.Count)) -Title (T 'msg.title.scriptlet'))
    } catch {
        Write-Log "Scriptlet backup failed: $_" 'ERR'
        [void](Show-Message -Text (T 'msg.scriptlet.backupFailed' @("$_")) -Title (T 'msg.title.scriptlet') -Icon 'Error')
    }
}

function Invoke-ScriptletRestoreSelected {
    $records = @(Get-SelectedScriptletRecords)
    if ($records.Count -eq 0) { [void](Show-Message -Text (T 'msg.scriptlet.restoreSelectFile') -Title (T 'msg.title.scriptlet')); return }
    if (-not (Test-ScriptletAdvancedWriteAllowed)) { return }
    $files = @($records | Select-Object -ExpandProperty File -Unique)
    if ((Show-Message -Text (T 'msg.scriptlet.confirmRestoreSel' @($files.Count)) -Title (T 'msg.title.scriptlet') -Buttons 'YesNo' -Icon 'Warning') -ne 'Yes') { return }
    try {
        foreach ($file in $files) { Restore-ScriptletBackup -File $file }
        Write-Log "Restored $($files.Count) scriptlet list file(s) from backup." 'OK'
        Invoke-ScriptletScan
    } catch {
        Write-Log "Scriptlet restore selected failed: $_" 'ERR'
        [void](Show-Message -Text (T 'msg.scriptlet.restoreFailed' @("$_")) -Title (T 'msg.title.scriptlet') -Icon 'Error')
    }
}

function Invoke-ScriptletRestoreAll {
    if (-not (Test-ScriptletAdvancedWriteAllowed)) { return }
    if ((Show-Message -Text (T 'msg.scriptlet.confirmRestoreAll' @($script:TxtScriptletRoot.Text)) -Title (T 'msg.title.scriptlet') -Buttons 'YesNo' -Icon 'Warning') -ne 'Yes') { return }
    try {
        $count = Restore-AllScriptletBackups -Root $script:TxtScriptletRoot.Text.Trim()
        Write-Log "Restored $count scriptlet backup file(s)." 'OK'
        Invoke-ScriptletScan
    } catch {
        Write-Log "Scriptlet restore all failed: $_" 'ERR'
        [void](Show-Message -Text (T 'msg.scriptlet.restoreAllFailed' @("$_")) -Title (T 'msg.title.scriptlet') -Icon 'Error')
    }
}

function Invoke-ScriptletExportCsv {
    if (-not $script:ScriptletVisibleRules -or $script:ScriptletVisibleRules.Count -eq 0) { [void](Show-Message -Text (T 'msg.scriptlet.nothingVisible') -Title (T 'msg.title.scriptlet')); return }
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = '{0} (*.csv)|*.csv' -f (T 'dialog.filter.csv')
    $sfd.FileName = "brave-free-origin-scriptlets-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    if ($sfd.ShowDialog() -ne 'OK') { return }
    $script:ScriptletVisibleRules |
        Select-Object Enabled, Domain, Scriptlet, Arguments, Source, Version, ComponentId, File, LineNumber, Rule |
        Export-Csv -LiteralPath $sfd.FileName -NoTypeInformation -Encoding UTF8
    Write-Log "Scriptlet CSV exported: $($sfd.FileName)" 'OK'
}

function Invoke-ScriptletExportPrefs {
    if (-not $script:ScriptletRules -or $script:ScriptletRules.Count -eq 0) { [void](Show-Message -Text (T 'msg.scriptlet.noRulesLoaded') -Title (T 'msg.title.scriptlet')); return }
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = '{0} (*.json)|*.json' -f (T 'dialog.filter.scriptletPrefs')
    $sfd.FileName = "brave-free-origin-disabled-scriptlets-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    if ($sfd.ShowDialog() -ne 'OK') { return }
    try {
        $count = Export-ScriptletDisabledPreferences -File $sfd.FileName
        Write-Log "Disabled scriptlet prefs exported: $count rule(s)." 'OK'
    } catch {
        [void](Show-Message -Text (T 'msg.scriptlet.exportFailed' @("$_")) -Title (T 'msg.title.scriptlet') -Icon 'Error')
    }
}

function Invoke-ScriptletImportPrefs {
    if (-not (Test-ScriptletAdvancedWriteAllowed)) { return }
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = '{0} (*.json)|*.json' -f (T 'dialog.filter.scriptletPrefs')
    if ($ofd.ShowDialog() -ne 'OK') { return }
    if ((Show-Message -Text (T 'msg.scriptlet.confirmReapply' @($script:TxtScriptletRoot.Text)) -Title (T 'msg.title.scriptlet') -Buttons 'YesNo' -Icon 'Warning') -ne 'Yes') { return }
    try {
        $changed = Import-ScriptletPreferencesAndReapply -PrefsFile $ofd.FileName -Root $script:TxtScriptletRoot.Text.Trim()
        Write-Log "Reapplied disabled scriptlet prefs: $changed line(s)." 'OK'
        Invoke-ScriptletScan
    } catch {
        Write-Log "Scriptlet preference reapply failed: $_" 'ERR'
        [void](Show-Message -Text (T 'msg.scriptlet.reapplyFailed' @("$_")) -Title (T 'msg.title.scriptlet') -Icon 'Error')
    }
}
#endregion


#region UI: dialogs ----------------------------------------------------------------------
function New-BfoDialog {
    param([string]$Title, [int]$Width = 720, [int]$Height = 520, [int]$MinWidth = 520, [int]$MinHeight = 360)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.StartPosition = 'CenterParent'
    $f.Size = New-Object System.Drawing.Size($Width, $Height)
    $f.MinimumSize = New-Object System.Drawing.Size($MinWidth, $MinHeight)
    $f.Font = Get-BfoUiFont -Size 9
    $f.BackColor = $script:Clr.White
    $f.ShowInTaskbar = $false
    $f.KeyPreview = $true
    $f.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $this.Close() } })
    if ($script:IsRtl) { $f.RightToLeft = 'Yes'; $f.RightToLeftLayout = $true }
    return $f
}

# Preview / Verify / details: a scrollable read-only report with Copy and Save.
function Show-TextReport {
    param([string]$Title, [string]$Text, [string]$DefaultFileName = 'brave-free-origin-report.txt')
    if ($script:SelfTestMode) { $script:SelfTestReports += , @($Title, $Text); return }
    $rf = New-BfoDialog -Title $Title -Width 780 -Height 580
    $bar = New-Ctl 'FlowLayoutPanel' @{ Dock = 'Bottom'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $false; BackColor = $script:Clr.Fog; Padding = (New-Object System.Windows.Forms.Padding(10, 8, 10, 8)) } $rf
    $tb = New-Ctl 'TextBox' @{ Multiline = $true; ReadOnly = $true; ScrollBars = 'Both'; WordWrap = $false; Dock = 'Fill'; Text = $Text; BorderStyle = 'None'; BackColor = $script:Clr.White } $rf
    $tb.Font = Get-BfoUiFont -Size 9 -Mono
    $tb.SelectionStart = 0; $tb.SelectionLength = 0
    $copy = New-BfoButton 'report.copy' 'Default' 90
    $copy.Add_Click({ if ($tb.Text) { [System.Windows.Forms.Clipboard]::SetText($tb.Text) } })
    $save = New-BfoButton 'report.save' 'Default' 110
    $save.Add_Click({
        Invoke-Guarded 'Save report' {
            $sfd = New-Object System.Windows.Forms.SaveFileDialog
            $sfd.Filter = '{0} (*.txt)|*.txt' -f (T 'dialog.filter.textReport')
            $sfd.FileName = $DefaultFileName
            $sfd.InitialDirectory = Get-BackupDirectory
            if ($sfd.ShowDialog() -eq 'OK') {
                [System.IO.File]::WriteAllText($sfd.FileName, $tb.Text, (New-Object System.Text.UTF8Encoding($true)))
                Write-Log "Report saved: $($sfd.FileName)" 'OK'
            }
        }
    })
    $close = New-BfoButton 'report.close' 'Default' 90
    $close.Add_Click({ $rf.Close() })
    $bar.Controls.AddRange([System.Windows.Forms.Control[]]@($copy, $save, $close))
    $tb.BringToFront()
    [void]$rf.ShowDialog($script:Form)
    $rf.Dispose()
}
$script:SelfTestReports = @()

function Show-HelpDialog {
    if ($script:SelfTestMode) { return }
    $d = New-BfoDialog -Title (T 'help.title') -Width 760 -Height 640 -MinWidth 560 -MinHeight 420
    $close = New-Ctl 'FlowLayoutPanel' @{ Dock = 'Bottom'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; BackColor = $script:Clr.Fog; Padding = (New-Object System.Windows.Forms.Padding(10, 8, 10, 8)) } $d
    $bIssues = New-BfoButton 'help.reportIssue' 'Default' 150
    $bIssues.Add_Click({ Invoke-Guarded 'Open issues' { Start-Process ($script:ProjectUrl + '/issues') } })
    $bLog = New-BfoButton 'help.openLog' 'Default' 140
    $bLog.Add_Click({ Invoke-Guarded 'Open log' { if (Test-Path -LiteralPath $script:LogFile) { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $script:LogFile) } } })
    $bClose = New-BfoButton 'report.close' 'Primary' 90
    $bClose.Add_Click({ $d.Close() })
    $close.Controls.AddRange([System.Windows.Forms.Control[]]@($bIssues, $bLog, $bClose))
    $scroll = New-Ctl 'Panel' @{ Dock = 'Fill'; AutoScroll = $true; BackColor = $script:Clr.White; Padding = (New-Object System.Windows.Forms.Padding(20, 14, 20, 14)) } $d
    $flow = New-Ctl 'FlowLayoutPanel' @{ Dock = 'Top'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; FlowDirection = 'TopDown'; WrapContents = $false; BackColor = $script:Clr.White } $scroll
    $braveVersion = (Get-BraveInfo (Get-PrimaryChannel)).Version
    $sections = @(
        @('help.what.title',   'help.what.body',   @()),
        @('help.tick.title',   'help.tick.body',   @()),
        @('help.status.title', 'help.status.body', @()),
        @('help.undo.title',   'help.undo.body',   @((Get-BackupDirectory))),
        @('help.managed.title','help.managed.body',@()),
        @('help.compat.title', 'help.compat.body', @($script:CatalogBrave, $script:CatalogBraveMajor, $script:CatalogDate, $(if ($braveVersion) { $braveVersion } else { '-' })))
    )
    foreach ($s in $sections) {
        $h = New-Ctl 'Label' @{ AutoSize = $true; ForeColor = $script:Clr.Ink; Margin = (New-Object System.Windows.Forms.Padding(0, 10, 0, 2)); Text = (T $s[0]) } $flow
        $h.Font = Get-BfoUiFont -Size 10.5 -Semibold
        $b = New-Ctl 'Label' @{ AutoSize = $true; MaximumSize = (New-Object System.Drawing.Size(660, 0)); ForeColor = $script:Clr.Slate; Margin = (New-Object System.Windows.Forms.Padding(0, 0, 0, 4)); Text = (T $s[1] $s[2]) } $flow
        $b.Font = Get-BfoUiFont -Size 9
    }
    $foot = New-Ctl 'Label' @{ AutoSize = $true; MaximumSize = (New-Object System.Drawing.Size(660, 0)); ForeColor = $script:Clr.Mist; Margin = (New-Object System.Windows.Forms.Padding(0, 14, 0, 0)); Text = (T 'help.footer' @($script:AppVersion, $script:ProjectUrl, $script:LogFile)) } $flow
    $foot.Font = Get-BfoUiFont -Size 8.5
    [void]$d.ShowDialog($script:Form)
    $d.Dispose()
}

# Shown after Apply: what happened, and the obvious next steps.
function Show-ApplyResult {
    param($Result, [string]$BackupFile)
    if ($script:SelfTestMode) { $script:SelfTestLastResult = $Result; return }
    $failed = $Result.Failures.Count
    $d = New-BfoDialog -Title (T 'msg.title.app') -Width 560 -Height $(if ($failed) { 470 } else { 330 }) -MinWidth 460 -MinHeight 280
    $d.StartPosition = 'CenterParent'
    $bar = New-Ctl 'FlowLayoutPanel' @{ Dock = 'Bottom'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; WrapContents = $true; BackColor = $script:Clr.Fog; Padding = (New-Object System.Windows.Forms.Padding(10, 8, 10, 8)) } $d
    $bVerify = New-BfoButton 'result.verify' 'Default' 100
    $bVerify.Add_Click({ $d.Close(); Invoke-Guarded 'Verify' { Invoke-VerifyAction } })
    $bPolicy = New-BfoButton 'util.openPolicy' 'Default' 150
    $bPolicy.Add_Click({ Invoke-Guarded 'Open policy page' { [void](Open-InBrave 'brave://policy') } })
    $bClose = New-BfoButton 'report.close' 'Primary' 90
    $bClose.Add_Click({ $d.Close() })
    $bar.Controls.AddRange([System.Windows.Forms.Control[]]@($bVerify, $bPolicy, $bClose))
    $body = New-Ctl 'Panel' @{ Dock = 'Fill'; AutoScroll = $true; Padding = (New-Object System.Windows.Forms.Padding(20, 16, 20, 12)); BackColor = $script:Clr.White } $d
    $flow = New-Ctl 'FlowLayoutPanel' @{ Dock = 'Top'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; FlowDirection = 'TopDown'; WrapContents = $false; BackColor = $script:Clr.White } $body
    $head = New-Ctl 'Label' @{ AutoSize = $true; Text = $(if ($failed) { T 'result.partial' } else { T 'result.done' }); ForeColor = $(if ($failed) { $script:Clr.Red } else { $script:Clr.Green }) } $flow
    $head.Font = Get-BfoUiFont -Size 12 -Semibold
    $lines = @((T 'result.counts' @($Result.Added, $Result.Changed, $Result.Cleared, $Result.Kept)))
    if ($Result.System -gt 0) { $lines += (T 'result.system' @($Result.System)) }
    if ($BackupFile) { $lines += (T 'result.backup' @($BackupFile)) }
    $lines += ''
    $lines += (T 'result.restart')
    $txt = New-Ctl 'Label' @{ AutoSize = $true; MaximumSize = (New-Object System.Drawing.Size(490, 0)); ForeColor = $script:Clr.Ink; Text = ($lines -join "`r`n"); Margin = (New-Object System.Windows.Forms.Padding(0, 8, 0, 0)) } $flow
    if ($failed) {
        $fl = New-Ctl 'Label' @{ AutoSize = $true; MaximumSize = (New-Object System.Drawing.Size(490, 0)); ForeColor = $script:Clr.Red; Margin = (New-Object System.Windows.Forms.Padding(0, 10, 0, 0))
            Text = ((T 'result.failures' @($failed)) + "`r`n" + (($Result.Failures | Select-Object -First 8) -join "`r`n")) } $flow
    }
    [void]$d.ShowDialog($script:Form)
    $d.Dispose()
}
$script:SelfTestLastResult = $null
#endregion

#region UI: actions --------------------------------------------------------------------------
function Set-CustomMode {
    if ($script:SuppressSelectionEvents) { return }
    $script:ActiveProfile = 'Custom'
}

function Update-ModeInfo {
    if (-not $script:LblModeInfo) { return }
    $key = if ($script:ActiveProfile) { $script:ActiveProfile } else { 'Custom' }
    $name = T "preset.$key.name"
    $risk = T "preset.$key.risk"
    $count = @($script:Items | Where-Object { $_.Kind -eq 'Policy' -and $_.Checked }).Count
    $script:LblModeInfo.Text = T 'mode.info' @($name, $risk, $count, (T "preset.$key.description"))
}

function Update-PendingSummary {
    if (-not $script:LblPending) { return }
    $add = 0; $change = 0; $clear = 0; $problem = $false
    try {
        $desired = Get-DesiredPolicyMap
        $snap = $script:Snapshot
        if (-not $snap) { $snap = Read-PolicySnapshot -Path $script:PolicyKeyPath; $script:Snapshot = $snap }
        foreach ($op in (Get-RegistryOps -Desired $desired -Snapshot $snap)) {
            switch ($op.Action) { 'Add' { $add++ } 'Change' { $change++ } 'Clear' { $clear++ } }
        }
        if (Get-StartupUrlOp -Desired $desired -Snapshot $snap) { $change++ }
    } catch { $problem = $true }
    $system = 0
    foreach ($i in $script:Items) { if (($i.Kind -eq 'Task' -or $i.Kind -eq 'Service') -and $i.Loaded -and $i.Checked -ne $i.Baseline) { $system++ } }
    $total = $add + $change + $clear + $system
    if ($problem) { $script:LblPending.Text = T 'bar.problem'; $script:LblPending.ForeColor = $script:Clr.Red }
    elseif ($total -eq 0) { $script:LblPending.Text = T 'bar.none'; $script:LblPending.ForeColor = $script:Clr.Slate }
    else { $script:LblPending.Text = T 'bar.pending' @($total, ($add + $system), $change, $clear); $script:LblPending.ForeColor = $script:Clr.Ink }
}

# One call after any change of state refreshes everything derived from it.
function Update-Chrome {
    if (-not $script:FormReady) { return }
    Update-PendingSummary
    Update-NavCounts
    Update-PresetStrip
    Update-ModeInfo
}

function Update-BraveInfo {
    $info = Get-BraveInfo (Get-PrimaryChannel)
    if ($info.Installed) {
        $scope = if ($info.Scope -eq 'user') { T 'header.scope.user' } else { T 'header.scope.machine' }
        $script:LblBrave.Text = T 'header.braveDetected' @($info.Version, $scope)
        $others = @(Get-DetectedChannels | Where-Object { $_ -ne $info.Channel } | ForEach-Object { '{0} {1}' -f $_, (Get-BraveInfo $_).Version })
        $tip = T 'header.policiesShared'
        if ($others.Count -gt 0) { $tip += "`r`n" + (T 'header.alsoInstalled' @(($others -join ', '))) }
        $script:ToolTip.SetToolTip($script:LblBrave, $tip)
    } else {
        $script:LblBrave.Text = T 'header.braveNotFound'
    }
    if ($script:LblCompat) {
        $note = ''
        if ($info.Major -gt $script:CatalogBraveMajor) { $note = T 'header.compat.newer' @($info.Major, $script:CatalogBraveMajor) }
        elseif ($info.Major -gt 0 -and $info.Major -lt ($script:CatalogBraveMajor - 12)) { $note = T 'header.compat.older' @($info.Major, $script:CatalogBraveMajor) }
        $script:LblCompat.Text = $note
        $script:LblCompat.Visible = [bool]$note
        $script:HeaderTable.RowStyles[3] = $(if ($note) { New-Object System.Windows.Forms.RowStyle('AutoSize') } else { New-Object System.Windows.Forms.RowStyle('Absolute', 0) })
    }
}

function Invoke-PresetClick {
    param([string]$Key)
    Push-SuppressSelectionEvents
    try { Set-PresetChecks -Preset $Key } finally { Pop-SuppressSelectionEvents }
    Update-AllItemViews
    Update-Filter
    Update-Chrome
    Write-Log ("Loaded mode: {0}" -f (TEn "preset.$Key.name"))
}

function Invoke-LoadCurrentState {
    Push-SuppressSelectionEvents
    try {
        Import-CurrentPolicyState
        Update-HostsCache
        Sync-OverrideControls
    } finally { Pop-SuppressSelectionEvents }
    Update-AllItemViews
    Update-Filter
    Update-Chrome
    Write-Log 'Loaded current system state.'
}

function Invoke-PreviewAction {
    try { $plan = New-ApplyPlan }
    catch { [void](Show-Message -Text $_.Exception.Message -Title (T 'msg.title.error') -Icon 'Warning'); Select-NavPage 'overrides'; return }
    Show-TextReport -Title (T 'report.previewTitle') -Text (New-ApplyPlanReport $plan) -DefaultFileName ("brave-free-origin-apply-preview-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Invoke-VerifyAction {
    Show-TextReport -Title (T 'report.verifyTitle') -Text (New-VerifyReport) -DefaultFileName ("brave-free-origin-verify-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Invoke-ApplyAction {
    try { $plan = New-ApplyPlan }
    catch { [void](Show-Message -Text $_.Exception.Message -Title (T 'msg.title.error') -Icon 'Warning'); Select-NavPage 'overrides'; return }

    if (-not (Test-PlanHasChanges $plan)) {
        [void](Show-Message -Text (T 'msg.apply.nothing') -Title (T 'msg.title.app'))
        return
    }
    if (@($plan.System | Where-Object { $_.Action -eq 'Disable' }).Count -gt 0) {
        $ans = Show-Message -Text (T 'msg.updater.confirm') -Title (T 'msg.title.updater') -Buttons 'YesNo' -Icon 'Warning' -Default 'Button2'
        if ($ans -ne 'Yes') { return }
    }
    $backupFile = $null
    if ($script:ChkBackup.Checked) {
        $b = Export-PolicyBackup
        if (-not $b.Ok) {
            Write-Log "Backup failed: $($b.Reason)" 'ERR'
            $ans = Show-Message -Text (T 'msg.backup.failed' @($b.Reason)) -Title (T 'msg.title.app') -Buttons 'YesNo' -Icon 'Warning' -Default 'Button2'
            if ($ans -ne 'Yes') { return }
        } elseif ($b.File) { $backupFile = $b.File; Write-Log "Backup saved: $($b.File)" 'OK' }
    }
    $script:Form.UseWaitCursor = $true
    try { $result = Invoke-ApplyPlan $plan } finally { $script:Form.UseWaitCursor = $false }
    Write-Log ("Done. Added {0}, changed {1}, cleared {2}, {3} system change(s), {4} failure(s)." -f $result.Added, $result.Changed, $result.Cleared, $result.System, $result.Failures.Count) 'DONE'

    # Re-read reality so every row shows its true state after the write.
    $script:Snapshot = Read-PolicySnapshot -Path $script:PolicyKeyPath
    if ($script:UpdaterLoaded -and $result.System -gt 0) { Import-CurrentSystemState -Refresh }
    Update-AllItemViews
    Update-Chrome
    Show-ApplyResult -Result $result -BackupFile $backupFile
}

function Invoke-RestoreAction {
    $f = Get-ForeignPolicyValues
    $foreign = @($f.Values) + @($f.SubKeys | ForEach-Object { "($_)" })
    $removeForeign = $false
    if ($foreign.Count -gt 0) {
        $sample = ($foreign | Select-Object -First 8) -join ', '
        $ans = Show-Message -Text (T 'msg.restore.confirmForeign' @($foreign.Count, $sample)) -Title (T 'msg.title.fullRestore') -Buttons 'YesNoCancel' -Icon 'Warning' -Default 'Button1'
        if ($ans -eq 'Cancel') { return }
        $removeForeign = ($ans -eq 'No')
    } else {
        if ((Show-Message -Text (T 'msg.restore.confirm') -Title (T 'msg.title.fullRestore') -Buttons 'YesNo' -Icon 'Warning') -ne 'Yes') { return }
    }
    if ($script:ChkBackup.Checked) {
        $b = Export-PolicyBackup
        if (-not $b.Ok) {
            Write-Log "Backup failed: $($b.Reason)" 'ERR'
            if ((Show-Message -Text (T 'msg.backup.failed' @($b.Reason)) -Title (T 'msg.title.app') -Buttons 'YesNo' -Icon 'Warning' -Default 'Button2') -ne 'Yes') { return }
        }
    }
    $failures = @(Invoke-FullRestore -RemoveForeign $removeForeign)
    Push-SuppressSelectionEvents
    try {
        foreach ($item in $script:Items) { Set-ItemChecked $item $false }
        $script:Overrides.Search.Enabled = $false; $script:Overrides.Ntp.Enabled = $false; $script:Overrides.Startup.Enabled = $false
        Sync-OverrideControls
    } finally { Pop-SuppressSelectionEvents }
    $script:ActiveProfile = 'None'
    $script:Snapshot = Read-PolicySnapshot -Path $script:PolicyKeyPath
    if ($script:UpdaterLoaded) { Import-CurrentSystemState -Refresh }
    Update-HostsCache
    Update-AllItemViews
    Update-Filter
    Update-Chrome
    if ($failures.Count -gt 0) {
        [void](Show-Message -Text ((T 'msg.restore.partial' @($failures.Count)) + "`r`n`r`n" + (($failures | Select-Object -First 6) -join "`r`n")) -Title (T 'msg.title.fullRestore') -Icon 'Warning')
    } else {
        [void](Show-Message -Text (T 'msg.restore.done') -Title (T 'msg.title.app'))
    }
    Write-Log 'Full restore completed. Restart Brave to see stock behavior.' 'DONE'
}

function Invoke-ExportConfig {
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = '{0} (*.json)|*.json' -f (T 'dialog.filter.config')
    $sfd.FileName = "brave-free-origin-config-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    $sfd.InitialDirectory = Get-BackupDirectory
    if ($sfd.ShowDialog() -ne 'OK') { return }
    $json = (New-ConfigObject) | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($sfd.FileName, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log "Config exported: $($sfd.FileName)" 'OK'
}

function Invoke-ImportConfig {
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = '{0} (*.json)|*.json' -f (T 'dialog.filter.config')
    $ofd.InitialDirectory = Get-BackupDirectory
    if ($ofd.ShowDialog() -ne 'OK') { return }
    try { $cfg = [System.IO.File]::ReadAllText($ofd.FileName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json }
    catch { [void](Show-Message -Text (T 'msg.config.badJson' @("$_")) -Title (T 'msg.title.importError') -Icon 'Error'); return }
    Push-SuppressSelectionEvents
    try { $unknown = Import-ConfigObject $cfg; Sync-OverrideControls } finally { Pop-SuppressSelectionEvents }
    Update-AllItemViews
    Update-Filter
    Update-Chrome
    Write-Log ("Config imported from {0} (schema {1}, app {2}, {3} unknown entr{4} skipped)" -f $ofd.FileName, $(if ($cfg.schemaVersion) { $cfg.schemaVersion } else { 1 }), $cfg.appVersion, $unknown, $(if ($unknown -eq 1) { 'y' } else { 'ies' })) 'OK'
    [void](Show-Message -Text (T 'msg.config.imported') -Title (T 'msg.title.imported'))
}

function New-ToolsMenu {
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Font = Get-BfoUiFont -Size 9
    $menu.ShowImageMargin = $false
    $entries = @(
        @('tools.load',    { Invoke-Guarded 'Load current state' { Invoke-LoadCurrentState } }),
        @('util.verify',   { Invoke-Guarded 'Verify' { Invoke-VerifyAction } }),
        @('util.openPolicy', { Invoke-Guarded 'Open policy page' { [void](Open-InBrave 'brave://policy') } }),
        @('-', $null),
        @('util.export',   { Invoke-Guarded 'Export config' { Invoke-ExportConfig } }),
        @('util.import',   { Invoke-Guarded 'Import config' { Invoke-ImportConfig } }),
        @('-', $null),
        @('tools.backups', { Invoke-Guarded 'Open backups' { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f (Get-BackupDirectory)) } }),
        @('tools.log',     { Invoke-Guarded 'Toggle log' { Switch-LogPanel } }),
        @('tools.help',    { Invoke-Guarded 'Help' { Show-HelpDialog } }),
        @('-', $null),
        @('util.close',    { $script:Form.Close() })
    )
    $script:ToolsMenuItems = @()
    foreach ($e in $entries) {
        if ($e[0] -eq '-') { [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)); continue }
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text = T $e[0]
        $mi.Tag = $e[0]
        $mi.Padding = New-Object System.Windows.Forms.Padding(4, 5, 4, 5)
        $action = $e[1]
        $mi.Add_Click($action)
        [void]$menu.Items.Add($mi)
        $script:ToolsMenuItems += $mi
    }
    return $menu
}

function Update-ToolsMenuText {
    foreach ($mi in $script:ToolsMenuItems) { $mi.Text = T $mi.Tag }
    if ($script:ToolsMenu) { $script:ToolsMenu.Font = Get-BfoUiFont -Size 9; $script:ToolsMenu.RightToLeft = $(if ($script:IsRtl) { 'Yes' } else { 'No' }) }
}

function Switch-LogPanel {
    $script:LogPanel.Visible = -not $script:LogPanel.Visible
    $script:BtnLogToggle.Text = if ($script:LogPanel.Visible) { T 'status.hideLog' } else { T 'status.showLog' }
}
#endregion


#region Startup ---------------------------------------------------------------
# Language first, so the window is built in the right script, font and direction
# instead of being built in English and re-texted. Order: -Lang, saved choice,
# Windows display language, same language family, English.
$script:BfoSettings = Get-BfoSettings -Path $script:SettingsPath
$script:LocaleList  = @(Get-AvailableLocales)
$startupLocale = Resolve-StartupLocale -Requested $Lang -Saved "$($script:BfoSettings['language'])"
if ($startupLocale -ne 'en-US') { [void](Set-BfoLocale -Code $startupLocale) }
if ($script:BfoSettings.ContainsKey('showTechnical')) { $script:ShowTechnical = ConvertTo-BoolStrict $script:BfoSettings['showTechnical'] }

Initialize-PolicyCatalog
Initialize-Items

# ---- Window ------------------------------------------------------------------
$form = New-MainForm
$script:Form = $form
if ($script:IsRtl) { $form.RightToLeft = 'Yes'; $form.RightToLeftLayout = $true }

$headerPanel = New-HeaderPanel
$sidebar     = New-Sidebar
$actionBar   = New-ActionBar
$script:LogPanel = New-LogPanel
$statusStrip = New-StatusStrip

$content = New-Ctl 'Panel' @{ Dock = 'Fill'; BackColor = $script:Clr.White }
$pageHost = New-Ctl 'Panel' @{ Dock = 'Fill'; BackColor = $script:Clr.White }
$script:PageHost = $pageHost
$topParts = New-ContentTop
$content.Controls.Add($pageHost)
$content.Controls.Add($topParts[1])      # bulk links bar
$content.Controls.Add($topParts[0])      # page title + search
$pageHost.BringToFront()

foreach ($p in $script:PageOrder) {
    $panel = switch ($p.Kind) {
        'grid'       { New-GridPage $p.Id }
        'updater'    { New-UpdaterPage }
        'hosts'      { New-HostsPage }
        'overrides'  { New-OverridesPage }
        'scriptlets' { New-ScriptletsPage }
    }
    $script:PagePanels[$p.Id] = $panel
    $pageHost.Controls.Add($panel)
}

# Dock order: the last control added docks first (nearest the edge), Fill last.
$form.Controls.Add($content)
$form.Controls.Add($sidebar)
$form.Controls.Add($headerPanel)
$form.Controls.Add($actionBar)
$form.Controls.Add($script:LogPanel)
$form.Controls.Add($statusStrip)
$content.BringToFront()
$form.ResumeLayout($true)   # New-MainForm suspended layout while the window was being assembled

# ---- Language picker -----------------------------------------------------------
foreach ($loc in $script:LocaleList) { [void]$script:LanguageCombo.Items.Add($loc.Name) }
for ($i = 0; $i -lt $script:LocaleList.Count; $i++) {
    if ($script:LocaleList[$i].Code -eq $script:CurrentLocale) { $script:LanguageCombo.SelectedIndex = $i; break }
}
if ($script:LanguageCombo.SelectedIndex -lt 0) { $script:LanguageCombo.SelectedIndex = 0 }

function Update-LocaleNote {
    $entry = @($script:LocaleList | Where-Object { $_.Code -eq $script:CurrentLocale })
    if ($entry.Count -gt 0 -and -not $entry[0].Reviewed -and $script:CurrentLocale -ne 'en-US') { $script:LblLocaleNote.Text = T 'header.unreviewedLocale' }
    else { $script:LblLocaleNote.Text = '' }
}
Update-LocaleNote

# ---- Direction, fonts and text after a language switch ----------------------------------
function Set-UiDirection {
    param([bool]$Rtl)
    $want = if ($Rtl) { [System.Windows.Forms.RightToLeft]::Yes } else { [System.Windows.Forms.RightToLeft]::No }
    if ($script:Form.RightToLeft -eq $want -and $script:Form.RightToLeftLayout -eq $Rtl) { return }
    $script:Form.SuspendLayout()
    try { $script:Form.RightToLeft = $want; $script:Form.RightToLeftLayout = $Rtl }
    finally { $script:Form.ResumeLayout($true) }
}

# A language switch is a pure re-text: it must not move one tick, one combo
# selection or the active preset, so the whole pass runs with the handlers muted
# and the active preset is captured and restored around it.
function Update-UiLanguage {
    $keepProfile = $script:ActiveProfile
    $script:Form.SuspendLayout()
    Push-SuppressSelectionEvents
    try {
        Set-UiDirection $script:IsRtl
        $script:Form.Font = Get-BfoUiFont -Size 9
        foreach ($binding in $script:I18nBindings) {
            try {
                if ($binding.Kind -eq 'Tooltip') { $script:ToolTip.SetToolTip($binding.Control, (T $binding.Key $binding.Args)); continue }
                $bindArgs = $binding.Args
                if ($binding.ArgsScript) { $bindArgs = @(& $binding.ArgsScript) }
                $binding.Control.($binding.Property) = T $binding.Key $bindArgs
            } catch { }
        }
        Update-LocalizedFonts
        Update-ToolsMenuText
        Set-ComboLabels -Combo $script:CmbSearchEngine -Ids $script:SearchEngineIds -LabelKeys $script:SearchEngineLabelKeys
        Set-ComboLabels -Combo $script:CmbNtpDest      -Ids $script:DestinationIds  -LabelKeys $script:DestinationLabelKeys
        Set-ComboLabels -Combo $script:CmbStartupMode  -Ids $script:StartupModeIds  -LabelKeys $script:StartupModeLabelKeys
        foreach ($g in $script:Grids.Values) {
            Set-GridFonts $g
            Update-GridHeaders $g
            $g.SuspendLayout()
            foreach ($row in $g.Rows) { if ($row.Tag) { Update-ItemTexts $row.Tag; Update-ItemView $row.Tag } }
            $g.ResumeLayout()
            $script:GridsDirty[$g.Name] = $true
        }
        Build-Nav
        if ($script:CurrentPageId) {
            Select-NavPage $script:CurrentPageId
            $script:LblPageTitle.Text = Get-PageTitle $script:CurrentPageId
            $script:LblPageIntro.Text = Get-PageIntro $script:CurrentPageId
        }
        Update-BraveInfo
        Update-ScriptletLocalizedText
        Update-LocaleNote
        $script:BtnLogToggle.Text = if ($script:LogPanel.Visible) { T 'status.hideLog' } else { T 'status.showLog' }
    } finally {
        Pop-SuppressSelectionEvents
        $script:Form.ResumeLayout($true)
    }
    $script:ActiveProfile = $keepProfile
    Update-OverrideControlStates
    Update-Filter
    Update-Chrome
    Update-GridColumnVisibility
    Start-RowHeightTimer
}

$script:LanguageCombo.Add_SelectedIndexChanged({
    if ($script:SuppressSelectionEvents) { return }
    $i = $script:LanguageCombo.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:LocaleList.Count) { return }
    $code = $script:LocaleList[$i].Code
    if ($code -eq $script:CurrentLocale) { return }
    Invoke-Guarded 'Change language' {
        [void](Set-BfoLocale -Code $code)
        Update-UiLanguage
        Set-BfoSetting 'language' $code
        Write-Log (T 'msg.language.switched' @($script:LocaleList[$i].Name)) 'OK'
    }
})

# ---- Buttons and menus -----------------------------------------------------------------
$script:ToolsMenu = New-ToolsMenu
Update-ToolsMenuText
$script:BtnTools.Add_Click({ $script:ToolsMenu.Show($script:BtnTools, (New-Object System.Drawing.Point(0, $script:BtnTools.Height))) })
$script:BtnPreview.Add_Click({ Invoke-Guarded 'Preview changes' { Invoke-PreviewAction } })
$script:BtnApply.Add_Click({ Invoke-Guarded 'Apply to Brave' { Invoke-ApplyAction } })
$script:BtnRestore.Add_Click({ Invoke-Guarded 'Restore stock' { Invoke-RestoreAction } })
$script:BtnLogToggle.Add_Click({ Invoke-Guarded 'Toggle log' { Switch-LogPanel } })
$form.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::F1) { Invoke-Guarded 'Help' { Show-HelpDialog }; $_.Handled = $true }
    elseif ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::F) { $script:TxtFilter.Focus(); $script:TxtFilter.SelectAll(); $_.Handled = $true }
})
$form.Add_FormClosing({ Remove-TempShortcuts })
$form.Add_SizeChanged({
    # Copy the keys first: assigning to a hashtable while enumerating its own Keys throws "Collection was modified".
    foreach ($k in @($script:GridsDirty.Keys)) { $script:GridsDirty[$k] = $true }
    Update-GridColumnVisibility
    Start-RowHeightTimer
})

# ---- Initial state ------------------------------------------------------------------------
Build-Nav
Update-BraveInfo
Update-GridColumnVisibility
$script:FormReady = $true
Show-Page $script:PolicyPageOrder[0]
Select-NavPage $script:PolicyPageOrder[0]

$form.Add_Shown({
    # The window is started from a hidden, elevated process; make sure it comes to the front rather than opening behind other windows.
    try { $script:Form.Activate() } catch { }
    Invoke-Guarded 'Startup' {
        Write-Log ("Brave Free Origin v{0} - running as administrator, OK." -f $script:AppVersion)
        $info = Get-BraveInfo (Get-PrimaryChannel)
        Write-Log ("Brave version: {0} ({1} install)" -f $(if ($info.Version) { $info.Version } else { 'not found' }), $info.Scope)
        Write-Log ("UI locale: {0}" -f $script:CurrentLocale)
        Invoke-LoadCurrentState
        Update-GridColumnVisibility
        Show-Page $script:PolicyPageOrder[0]
    }
})

if ($script:SelfTestMode) {
    # Maintainer hook: run the test script inside the finished app, then leave.
    # No window is shown, no UAC prompt was raised, and nothing outside the
    # sandbox (HKCU test hive, temp hosts file, in-memory tasks) was touched.
    $script:SelfTestExit = 0
    . $SelfTest
    Remove-TempShortcuts
    exit $script:SelfTestExit
}
[void]$form.ShowDialog()
#endregion
