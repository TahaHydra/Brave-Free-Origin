# ============================================================================
#  Brave Debullshitinator Pro - GUI edition for Windows
#  Applies Brave Browser group policies via the registry with a checkbox UI.
#  Source policies researched from brave/brave-core and Chromium enterprise docs.
# ============================================================================

#region Elevation -------------------------------------------------------------
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $args
    exit
}
#endregion

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:BravePolicyPath = 'HKLM:\Software\Policies\BraveSoftware\Brave'

#region Policy Data -----------------------------------------------------------
# Each policy: Name, Type (DWORD/STRING), ApplyValue (what to write when ticked),
#              Recommended (true = tick by default in "Recommended" preset),
#              MaxPrivacy (tick for "Maximum Privacy"), Description
$script:Policies = [ordered]@{
    'Brave Features' = @(
        @{Name='BraveRewardsDisabled';         Type='DWORD';  ApplyValue=1; Recommended=$true;  MaxPrivacy=$true;  Description='Disable Brave Rewards (BAT ads/tips) and hide all Rewards UI.'},
        @{Name='BraveWalletDisabled';          Type='DWORD';  ApplyValue=1; Recommended=$true;  MaxPrivacy=$true;  Description='Disable the built-in crypto wallet (ETH/BTC/SOL/FIL/ZEC).'},
        @{Name='BraveVPNDisabled';             Type='DWORD';  ApplyValue=1; Recommended=$true;  MaxPrivacy=$true;  Description='Disable Brave VPN integration and all VPN UI.'},
        @{Name='BraveAIChatEnabled';           Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable Leo AI Chat assistant.'},
        @{Name='BraveNewsDisabled';            Type='DWORD';  ApplyValue=1; Recommended=$true;  MaxPrivacy=$true;  Description='Disable Brave News feed on the new tab page.'},
        @{Name='BraveTalkDisabled';            Type='DWORD';  ApplyValue=1; Recommended=$true;  MaxPrivacy=$true;  Description='Disable Brave Talk (Jitsi-based video calls).'},
        @{Name='BraveWaybackMachineEnabled';   Type='DWORD';  ApplyValue=0; Recommended=$false; MaxPrivacy=$true;  Description='Disable the "Check Wayback Machine" prompt on 404 pages.'},
        @{Name='BravePlaylistEnabled';         Type='DWORD';  ApplyValue=0; Recommended=$false; MaxPrivacy=$false; Description='Disable Playlist feature (save videos/audio).'},
        @{Name='BraveSpeedreaderEnabled';      Type='DWORD';  ApplyValue=0; Recommended=$false; MaxPrivacy=$false; Description='Disable Speedreader reading-mode feature.'},
        @{Name='TorDisabled';                  Type='DWORD';  ApplyValue=1; Recommended=$true;  MaxPrivacy=$false; Description='Disable "Private Window with Tor". (Brave Tor is not recommended over real Tor Browser.)'},
        @{Name='IPFSEnabled';                  Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable IPFS protocol support.'},
        @{Name='WebTorrentDisabled';           Type='DWORD';  ApplyValue=1; Recommended=$true;  MaxPrivacy=$true;  Description='Disable WebTorrent / magnet link integration.'}
    )
    'Privacy / Telemetry' = @(
        @{Name='BraveP3AEnabled';                             Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable P3A privacy-preserving product analytics.'},
        @{Name='BraveStatsPingEnabled';                       Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable anonymous daily/weekly/monthly usage ping.'},
        @{Name='BraveWebDiscoveryEnabled';                    Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable Web Discovery Project search index contribution.'},
        @{Name='MetricsReportingEnabled';                     Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable Chromium UMA crash/usage metrics.'},
        @{Name='BraveGlobalPrivacyControlEnabled';            Type='DWORD';  ApplyValue=1; Recommended=$true;  MaxPrivacy=$true;  Description='Enable Sec-GPC "do not sell/share" signal. (Leave ON for privacy.)'},
        @{Name='BraveReduceLanguageEnabled';                  Type='DWORD';  ApplyValue=1; Recommended=$true;  MaxPrivacy=$true;  Description='Reduce language-preference fingerprinting. (Leave ON for privacy.)'},
        @{Name='BraveTrackingQueryParametersFilteringEnabled';Type='DWORD';  ApplyValue=1; Recommended=$true;  MaxPrivacy=$true;  Description='Strip tracking params (utm_, fbclid, etc.) from URLs. (Leave ON for privacy.)'},
        @{Name='BraveDeAmpEnabled';                           Type='DWORD';  ApplyValue=1; Recommended=$true;  MaxPrivacy=$true;  Description='Bypass Google AMP pages to reach publisher directly. (Leave ON for privacy.)'},
        @{Name='BraveDebouncingEnabled';                      Type='DWORD';  ApplyValue=1; Recommended=$true;  MaxPrivacy=$true;  Description='Protect against bounce-tracking redirect chains. (Leave ON for privacy.)'},
        @{Name='DefaultBraveFingerprintingV2Setting';         Type='DWORD';  ApplyValue=3; Recommended=$true;  MaxPrivacy=$true;  Description='Set fingerprint protection to Standard (3). 1=Off.'},
        @{Name='DefaultBraveAdblockSetting';                  Type='DWORD';  ApplyValue=2; Recommended=$true;  MaxPrivacy=$true;  Description='Force default ad-blocking to Block (2). 1=Allow.'},
        @{Name='DefaultBraveHttpsUpgradeSetting';             Type='DWORD';  ApplyValue=2; Recommended=$false; MaxPrivacy=$true;  Description='Force HTTPS upgrade to Strict (2). 3=Standard, 1=Disabled.'},
        @{Name='DefaultBraveReferrersSetting';                Type='DWORD';  ApplyValue=2; Recommended=$true;  MaxPrivacy=$true;  Description='Cap cross-site referrers to strict-origin-when-cross-origin (2).'},
        @{Name='DefaultBraveRemember1PStorageSetting';        Type='DWORD';  ApplyValue=2; Recommended=$false; MaxPrivacy=$true;  Description='Forget first-party storage on tab close (2). 1=Remember.'},
        @{Name='ChromeVariations';                            Type='DWORD';  ApplyValue=2; Recommended=$true;  MaxPrivacy=$true;  Description='Opt out of all Chromium field trials/experiments (2). 1=critical only, 0=all.'},
        @{Name='CloudReportingEnabled';                       Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable enterprise cloud reporting.'},
        @{Name='UserFeedbackAllowed';                         Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable the "Send feedback" UI that uploads diagnostics to Brave/Google.'}
    )
    'Autofill / Passwords' = @(
        @{Name='PasswordManagerEnabled';        Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable built-in password manager (use Bitwarden / Proton Pass instead).'},
        @{Name='PasswordLeakDetectionEnabled';  Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable leaked-credential check (avoids sending hashed pw to Google).'},
        @{Name='AutofillAddressEnabled';        Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable autofill of addresses / contact info.'},
        @{Name='AutofillCreditCardEnabled';     Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable autofill of credit cards.'},
        @{Name='PaymentMethodQueryEnabled';     Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Prevent sites from querying for saved payment methods.'},
        @{Name='AutoplayAllowed';               Type='DWORD';  ApplyValue=0; Recommended=$false; MaxPrivacy=$true;  Description='Block autoplaying media site-wide.'}
    )
    'Search / Suggestions' = @(
        @{Name='SearchSuggestEnabled';                        Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable search-engine autosuggest in the omnibox.'},
        @{Name='UrlKeyedAnonymizedDataCollectionEnabled';     Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable "Make searches and browsing better" URL reporting.'},
        @{Name='SpellCheckServiceEnabled';                    Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable the enhanced (cloud) spellcheck service.'},
        @{Name='SpellcheckEnabled';                           Type='DWORD';  ApplyValue=0; Recommended=$false; MaxPrivacy=$false; Description='Disable local spellcheck entirely.'},
        @{Name='TranslateEnabled';                            Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable the "translate this page" Google prompt.'},
        @{Name='AlternateErrorPagesEnabled';                  Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable Google-hosted suggestion page on DNS errors.'}
    )
    'Safety / Updates' = @(
        @{Name='SafeBrowsingProtectionLevel';         Type='DWORD';  ApplyValue=1; Recommended=$true;  MaxPrivacy=$false; Description='Set Safe Browsing to Standard (1). 0=Off, 2=Enhanced (sends more to Google).'},
        @{Name='SafeBrowsingExtendedReportingEnabled';Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable sending extra info to Google Safe Browsing.'},
        @{Name='SafeBrowsingDeepScanningEnabled';     Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable uploading downloads to Google for deep scan.'},
        @{Name='SafeBrowsingSurveysEnabled';          Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable Safe Browsing user surveys.'},
        @{Name='ComponentUpdatesEnabled';             Type='DWORD';  ApplyValue=0; Recommended=$false; MaxPrivacy=$false; Description='Disable Chromium component updates (e.g. Widevine). Only tick if you know what this breaks.'},
        @{Name='DefaultBrowserSettingEnabled';        Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable the "make default browser" prompt.'},
        @{Name='ChromeCleanupEnabled';                Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable the software-cleanup scanner (harmless on Brave).'},
        @{Name='ChromeCleanupReportingEnabled';       Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable reporting from the cleanup scanner.'}
    )
    'AI / GenAI' = @(
        @{Name='GenAiDefaultSettings';      Type='DWORD';  ApplyValue=2; Recommended=$true;  MaxPrivacy=$true;  Description='Disable ALL upstream Chromium GenAI features (2).'},
        @{Name='HelpMeWriteSettings';       Type='DWORD';  ApplyValue=2; Recommended=$true;  MaxPrivacy=$true;  Description='Disable "Help me write" compose features.'},
        @{Name='TabOrganizerSettings';      Type='DWORD';  ApplyValue=2; Recommended=$true;  MaxPrivacy=$true;  Description='Disable AI Tab Organizer.'},
        @{Name='CreateThemesSettings';      Type='DWORD';  ApplyValue=2; Recommended=$true;  MaxPrivacy=$true;  Description='Disable AI-generated themes.'},
        @{Name='HistorySearchSettings';     Type='DWORD';  ApplyValue=2; Recommended=$true;  MaxPrivacy=$true;  Description='Disable AI-powered history search.'},
        @{Name='DevToolsGenAiSettings';     Type='DWORD';  ApplyValue=2; Recommended=$true;  MaxPrivacy=$true;  Description='Disable GenAI features inside DevTools.'}
    )
    'Web Services / Background' = @(
        @{Name='BackgroundModeEnabled';           Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Stop Brave from running in the background after window close.'},
        @{Name='NetworkPredictionOptions';        Type='DWORD';  ApplyValue=2; Recommended=$true;  MaxPrivacy=$true;  Description='Never prefetch DNS/TCP/SSL (2). 0/1 = predict.'},
        @{Name='CloudPrintSubmitEnabled';         Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable legacy cloud-print submissions.'},
        @{Name='BuiltInDnsClientEnabled';         Type='DWORD';  ApplyValue=0; Recommended=$false; MaxPrivacy=$false; Description='Use OS resolver instead of async DoH client. Only tick if you want OS DNS.'},
        @{Name='DnsOverHttpsMode';                Type='STRING'; ApplyValue='automatic'; Recommended=$true;  MaxPrivacy=$true;  Description='Allow DoH ("automatic"). Set to "secure" to force, "off" to disable.'},
        @{Name='WebRtcEventLogCollectionAllowed'; Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Block upload of WebRTC event logs to Google.'},
        @{Name='SyncDisabled';                    Type='DWORD';  ApplyValue=1; Recommended=$false; MaxPrivacy=$true;  Description='Disable profile sync entirely.'},
        @{Name='SigninAllowed';                   Type='DWORD';  ApplyValue=0; Recommended=$false; MaxPrivacy=$true;  Description='Disable Google/Brave account sign-in.'},
        @{Name='BrowserSignin';                   Type='DWORD';  ApplyValue=0; Recommended=$false; MaxPrivacy=$true;  Description='Fully disable sign-in UI (0). 1=allow, 2=force.'},
        @{Name='PromotionalTabsEnabled';          Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable the welcome/promo new-tab content.'},
        @{Name='WelcomePageOnOSUpgradeEnabled';   Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable the "welcome back after OS upgrade" tab.'},
        @{Name='ImportAutofillFormData';          Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Block autofill import on first run.'},
        @{Name='ImportBookmarks';                 Type='DWORD';  ApplyValue=0; Recommended=$false; MaxPrivacy=$true;  Description='Block bookmark import prompt on first run.'},
        @{Name='ImportHistory';                   Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Block history import on first run.'},
        @{Name='ImportSavedPasswords';            Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Block password import on first run.'},
        @{Name='ImportSearchEngine';              Type='DWORD';  ApplyValue=0; Recommended=$false; MaxPrivacy=$true;  Description='Block search-engine import on first run.'}
    )
    'Performance / Startup' = @(
        @{Name='QuicAllowed';                     Type='DWORD';  ApplyValue=1;          Recommended=$true;  MaxPrivacy=$true;  Description='Enable QUIC / HTTP/3 protocol. Faster TLS handshake, lower latency.'},
        @{Name='HighEfficiencyModeEnabled';       Type='DWORD';  ApplyValue=1;          Recommended=$true;  MaxPrivacy=$true;  Description='Memory Saver: sleep inactive tabs to reclaim RAM/CPU.'},
        @{Name='BatterySaverModeAvailability';    Type='DWORD';  ApplyValue=2;          Recommended=$true;  MaxPrivacy=$true;  Description='Allow Battery Saver on low battery (2). 1=always on unplugged, 0=disabled.'},
        @{Name='HardwareAccelerationModeEnabled'; Type='DWORD';  ApplyValue=1;          Recommended=$true;  MaxPrivacy=$true;  Description='Force GPU hardware acceleration. Big gain for video/scrolling.'},
        @{Name='MediaRouterEnabled';              Type='DWORD';  ApplyValue=0;          Recommended=$true;  MaxPrivacy=$true;  Description='Disable Google Cast / Media Router. Stops background mDNS discovery and memory overhead.'},
        @{Name='DiskCacheSize';                   Type='DWORD';  ApplyValue=262144000;  Recommended=$true;  MaxPrivacy=$false; Description='Cap disk cache at 250 MB (value in bytes). Prevents unbounded cache growth on SSDs.'},
        @{Name='BrowserLabsEnabled';              Type='DWORD';  ApplyValue=0;          Recommended=$true;  MaxPrivacy=$true;  Description='Hide the Labs / experimental features icon in the toolbar.'},
        @{Name='RestoreOnStartup';                Type='DWORD';  ApplyValue=5;          Recommended=$true;  MaxPrivacy=$true;  Description='Open blank new-tab on launch (5). Faster than restoring last session (1).'},
        @{Name='HomepageIsNewTabPage';            Type='DWORD';  ApplyValue=0;          Recommended=$true;  MaxPrivacy=$true;  Description='Decouple home button from the bloated NTP.'},
        @{Name='HomepageLocation';                Type='STRING'; ApplyValue='about:blank'; Recommended=$true;  MaxPrivacy=$true;  Description='Blank homepage = fastest possible startup.'},
        @{Name='NewTabPageLocation';              Type='STRING'; ApplyValue='about:blank'; Recommended=$false; MaxPrivacy=$true;  Description='Force new tab page to about:blank. Kills all NTP bloat.'},
        @{Name='NTPCustomBackgroundEnabled';      Type='DWORD';  ApplyValue=0;          Recommended=$true;  MaxPrivacy=$true;  Description='Disable the custom new-tab-page background (stops wallpaper download).'},
        @{Name='ShowHomeButton';                  Type='DWORD';  ApplyValue=0;          Recommended=$false; MaxPrivacy=$false; Description='Hide the Home button (tiny UI/render win).'}
    )
    'UI Bloat / Extras' = @(
        @{Name='LiveCaptionEnabled';              Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable Live Caption (stops background download of speech-recognition model).'},
        @{Name='AccessibilityImageLabelsEnabled'; Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable cloud image-description service (sends images to Google).'},
        @{Name='LensDesktopNTPSearchEnabled';     Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Hide Google Lens search box on new tab page.'},
        @{Name='LensRegionSearchEnabled';         Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Disable right-click Google Lens region search.'},
        @{Name='LensOverlaySettings';             Type='DWORD';  ApplyValue=1; Recommended=$true;  MaxPrivacy=$true;  Description='Disable the Lens overlay feature (1 = disabled).'},
        @{Name='ReadingListEnabled';              Type='DWORD';  ApplyValue=0; Recommended=$true;  MaxPrivacy=$true;  Description='Remove the Reading List UI.'},
        @{Name='PromptForDownloadLocation';       Type='DWORD';  ApplyValue=0; Recommended=$false; MaxPrivacy=$false; Description='Auto-save to Downloads without prompting. Set 1 if you prefer prompts.'},
        @{Name='BookmarkBarEnabled';              Type='DWORD';  ApplyValue=0; Recommended=$false; MaxPrivacy=$false; Description='Hide bookmark bar globally (small render win). Unticking lets user toggle.'}
    )
}

$script:ScheduledTasks = @(
    @{Name='BraveSoftwareUpdateTaskMachineCore'; Description='Hourly "core" update check launched by Brave Omaha.'},
    @{Name='BraveSoftwareUpdateTaskMachineUA';   Description='The actual version-check/download task.'}
)

$script:Services = @(
    @{Name='brave';                   Description='Brave Update Service - main Omaha update service.'},
    @{Name='bravem';                  Description='Brave Update Service (medium-integrity on-demand helper).'},
    @{Name='BraveElevationService';   Description='Brave Elevation Service - helper used by Omaha for per-machine updates.'},
    @{Name='BraveVPNService';         Description='Brave VPN Service (present only if VPN feature installed).'},
    @{Name='BraveVpnWireguardService';Description='Brave VPN Wireguard Service (present only if VPN feature installed).'}
)
#endregion

#region Helpers ---------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    if ($script:LogBox) {
        $script:LogBox.AppendText("$line`r`n")
        $script:LogBox.SelectionStart = $script:LogBox.Text.Length
        $script:LogBox.ScrollToCaret()
    }
}

function Get-ExistingPolicy {
    param([string]$Name)
    try {
        $v = Get-ItemProperty -Path $script:BravePolicyPath -Name $Name -ErrorAction Stop
        return $v.$Name
    } catch { return $null }
}

function Set-PolicyValue {
    param([string]$Name, [string]$Type, $Value)
    if (-not (Test-Path $script:BravePolicyPath)) {
        New-Item -Path $script:BravePolicyPath -Force | Out-Null
    }
    $regType = if ($Type -eq 'DWORD') { 'DWord' } else { 'String' }
    New-ItemProperty -Path $script:BravePolicyPath -Name $Name -Value $Value -PropertyType $regType -Force | Out-Null
}

function Remove-PolicyValue {
    param([string]$Name)
    try {
        Remove-ItemProperty -Path $script:BravePolicyPath -Name $Name -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Export-Backup {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $env:USERPROFILE 'Documents\Brave-Free-Origin-Backups'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $file = Join-Path $dir "brave-policies-backup-$stamp.reg"
    $regKey = 'HKLM\Software\Policies\BraveSoftware'
    $result = & reg.exe EXPORT $regKey $file /y 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Backup saved: $file" 'OK'
        return $file
    } else {
        Write-Log "Backup skipped (no existing policies)." 'INFO'
        return $null
    }
}

function Test-BraveInstalled {
    $paths = @(
        "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe",
        "$env:ProgramFiles(x86)\BraveSoftware\Brave-Browser\Application\brave.exe",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe"
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $p } }
    return $null
}

function Get-BraveVersion {
    $exe = Test-BraveInstalled
    if ($exe) {
        try { return (Get-Item $exe).VersionInfo.FileVersion } catch { return 'unknown' }
    }
    return 'not installed'
}
#endregion

#region GUI Build -------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Brave Free Origin v1.4  -  the free answer to Brave Origin's paywalled minimal mode"
$form.Size = New-Object System.Drawing.Size(1180, 900)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(1080, 820)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

$braveVer = Get-BraveVersion
$script:SuppressSelectionEvents = $false
$script:ActiveProfile = 'Custom'
$script:MinimalPolicies = @(
    'BraveRewardsDisabled','BraveWalletDisabled','BraveVPNDisabled',
    'BraveAIChatEnabled','PasswordManagerEnabled'
)
$script:OriginPolicies = @(
    'BraveAIChatEnabled',
    'BraveNewsDisabled',
    'BraveP3AEnabled',
    'BravePlaylistEnabled',
    'BraveRewardsDisabled',
    'BraveSpeedreaderEnabled',
    'BraveStatsPingEnabled',
    'BraveTalkDisabled',
    'BraveVPNDisabled',
    'BraveWalletDisabled',
    'BraveWaybackMachineEnabled',
    'BraveWebDiscoveryEnabled',
    'MetricsReportingEnabled',
    'TorDisabled'
)
$script:PerformancePolicies = @(
    $script:OriginPolicies +
    @(
        'BackgroundModeEnabled',
        'BrowserLabsEnabled',
        'CloudPrintSubmitEnabled',
        'DiskCacheSize',
        'HardwareAccelerationModeEnabled',
        'HighEfficiencyModeEnabled',
        'HomepageIsNewTabPage',
        'HomepageLocation',
        'IPFSEnabled',
        'LiveCaptionEnabled',
        'MediaRouterEnabled',
        'NetworkPredictionOptions',
        'NewTabPageLocation',
        'NTPCustomBackgroundEnabled',
        'PromotionalTabsEnabled',
        'QuicAllowed',
        'ReadingListEnabled',
        'RestoreOnStartup',
        'WebRtcEventLogCollectionAllowed',
        'WebTorrentDisabled',
        'WelcomePageOnOSUpgradeEnabled'
    )
) | Select-Object -Unique
$script:MaxPrivacyPolicies = @(
    foreach ($cat in $script:Policies.Keys) {
        foreach ($policy in $script:Policies[$cat]) {
            if ($policy.MaxPrivacy) { $policy.Name }
        }
    }
) | Select-Object -Unique
$script:MaxPerformancePolicies = @(
    $script:MaxPrivacyPolicies +
    $script:PerformancePolicies +
    @(
        'BookmarkBarEnabled',
        'PromptForDownloadLocation',
        'ShowHomeButton',
        'SpellcheckEnabled'
    )
) | Select-Object -Unique
$script:ProfileDisplayNames = @{
    'Minimal'        = 'Quick Debloat'
    'Recommended'    = 'Recommended'
    'Origin'         = 'Origin Mode'
    'Performance'    = 'Privacy + Boost'
    'MaxPerformance' = 'Max Performance'
    'MaxPrivacy'     = 'Max Privacy'
    'None'           = 'Stock / None'
    'CurrentState'   = 'Current State'
    'Custom'         = 'Custom'
}
$script:ProfileDescriptions = @{
    'Minimal'      = 'Quick debloat. Removes the loudest commercial extras without changing the whole browser.'
    'Recommended'  = 'Balanced daily-driver setup. Good privacy, lighter UI, keeps core compatibility and media-friendly defaults.'
    'Origin'       = 'Matches Brave Origin''s stripped-down idea from April 2026: off by default for Leo, Rewards, Wallet, VPN, News, Talk, Tor, Wayback, Web Discovery, and related stats.'
    'Performance'  = 'Privacy + Boost. Origin-style debloat plus startup and latency tuning for a leaner browser during gaming, streaming, or music use.'
    'MaxPerformance' = 'Full fusion mode: Origin Mode, Privacy + Boost, and the strong privacy set combined, plus a few extra UI trims. This is the closest thing to an all-in gamer build.'
    'MaxPrivacy'   = 'Aggressive lockdown. Great for hard privacy, but it can disable sync, sign-in, imports, and Brave update services.'
    'None'         = 'Stock behavior. Nothing selected, nothing will be enforced.'
    'CurrentState' = 'Read from this PC. Shows what is already disabled right now.'
    'Custom'       = 'Hand-picked mix. Use the tabs below to build your own Brave loadout.'
}
$script:ProfileRisks = @{
    'Minimal'      = 'Low risk'
    'Recommended'  = 'Low risk'
    'Origin'       = 'Low risk'
    'Performance'  = 'Medium risk'
    'MaxPerformance' = 'High risk'
    'MaxPrivacy'   = 'High risk'
    'None'         = 'No changes'
    'CurrentState' = 'Read only'
    'Custom'       = 'Depends on your picks'
}

function Get-PresetPayload {
    param([string]$Preset)

    switch ($Preset) {
        'Recommended' {
            return @{
                Policies = @(
                    foreach ($cat in $script:Policies.Keys) {
                        foreach ($policy in $script:Policies[$cat]) {
                            if ($policy.Recommended) { $policy.Name }
                        }
                    }
                )
                Tasks    = @($script:ScheduledTasks.Name)
                Services = @()
            }
        }
        'MaxPrivacy' {
            return @{
                Policies = @($script:MaxPrivacyPolicies)
                Tasks    = @($script:ScheduledTasks.Name)
                Services = @($script:Services.Name)
            }
        }
        'Minimal' {
            return @{
                Policies = @($script:MinimalPolicies)
                Tasks    = @()
                Services = @()
            }
        }
        'Origin' {
            return @{
                Policies = @($script:OriginPolicies)
                Tasks    = @()
                Services = @()
            }
        }
        'Performance' {
            return @{
                Policies = @($script:PerformancePolicies)
                Tasks    = @($script:ScheduledTasks.Name)
                Services = @()
            }
        }
        'MaxPerformance' {
            return @{
                Policies = @($script:MaxPerformancePolicies)
                Tasks    = @($script:ScheduledTasks.Name)
                Services = @($script:Services.Name)
            }
        }
        default {
            return @{
                Policies = @()
                Tasks    = @()
                Services = @()
            }
        }
    }
}

function Update-SelectionSummary {
    if (-not $script:ModeLabel) { return }

    $selectedPolicies = @($script:CheckBoxes | Where-Object { $_.Checked })
    $selectedTasks = @($script:TaskCheckBoxes | Where-Object { $_.Checked })
    $selectedServices = @($script:ServiceCheckBoxes | Where-Object { $_.Checked })
    $modeKey = if ([string]::IsNullOrWhiteSpace($script:ActiveProfile)) { 'Custom' } else { $script:ActiveProfile }
    $modeLabel = if ($script:ProfileDisplayNames.ContainsKey($modeKey)) { $script:ProfileDisplayNames[$modeKey] } else { $modeKey }

    $script:ModeLabel.Text = "Mode: $modeLabel"
    $script:SelectionLabel.Text = "Policies: $($selectedPolicies.Count) / $($script:CheckBoxes.Count)"
    $script:SystemLabel.Text = "System: $($selectedTasks.Count) tasks, $($selectedServices.Count) services"
    $script:RiskLabel.Text = "Risk: $($script:ProfileRisks[$modeKey])"
    $script:ModeDescription.Text = $script:ProfileDescriptions[$modeKey]
}

function Set-CustomMode {
    if ($script:SuppressSelectionEvents) { return }
    $script:ActiveProfile = 'Custom'
    Update-SelectionSummary
}

function Apply-Preset {
    param([string]$Preset)

    $payload = Get-PresetPayload -Preset $Preset
    $script:SuppressSelectionEvents = $true

    foreach ($cb in $script:CheckBoxes) {
        $policyName = $cb.Tag.Policy.Name
        $cb.Checked = $payload.Policies -contains $policyName
    }
    foreach ($cb in $script:TaskCheckBoxes) {
        $cb.Checked = $payload.Tasks -contains $cb.Tag.Name
    }
    foreach ($cb in $script:ServiceCheckBoxes) {
        $cb.Checked = $payload.Services -contains $cb.Tag.Name
    }

    $script:SuppressSelectionEvents = $false
    $script:ActiveProfile = $Preset
    Update-SelectionSummary
    $presetLabel = if ($script:ProfileDisplayNames.ContainsKey($Preset)) { $script:ProfileDisplayNames[$Preset] } else { $Preset }
    Write-Log "Loaded mode: $presetLabel"
}

# Header panel
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 112
$header.BackColor = [System.Drawing.Color]::FromArgb(22, 27, 34)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'Brave Free Origin'
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
$titleLabel.Location = New-Object System.Drawing.Point(18, 10)
$titleLabel.AutoSize = $true
$header.Controls.Add($titleLabel)

$subLabel = New-Object System.Windows.Forms.Label
$subLabel.Text = "Strip out the AI, crypto, VPN, promo junk, and background clutter Brave stuffed in, then tune it for a lighter desktop footprint."
$subLabel.ForeColor = [System.Drawing.Color]::Gainsboro
$subLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$subLabel.Location = New-Object System.Drawing.Point(20, 43)
$subLabel.Size = New-Object System.Drawing.Size(760, 18)
$header.Controls.Add($subLabel)

$metaLabel = New-Object System.Windows.Forms.Label
$metaLabel.Text = "Brave detected: $braveVer    |    Target: HKLM\Software\Policies\BraveSoftware\Brave"
$metaLabel.ForeColor = [System.Drawing.Color]::LightSteelBlue
$metaLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$metaLabel.Location = New-Object System.Drawing.Point(20, 70)
$metaLabel.Size = New-Object System.Drawing.Size(780, 18)
$header.Controls.Add($metaLabel)

$originNote = New-Object System.Windows.Forms.Label
$originNote.Text = 'Context: Brave described Origin on April 16, 2026 as a minimalist build, then put that stripped-down idea behind a paywall. This is the free local version.'
$originNote.ForeColor = [System.Drawing.Color]::FromArgb(255, 212, 153)
$originNote.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$originNote.Location = New-Object System.Drawing.Point(20, 88)
$originNote.Size = New-Object System.Drawing.Size(950, 18)
$header.Controls.Add($originNote)

$form.Controls.Add($header)

# Tooltip
$tt = New-Object System.Windows.Forms.ToolTip
$tt.AutoPopDelay = 30000
$tt.InitialDelay = 300
$tt.ReshowDelay  = 300

# Mode deck
$modePanel = New-Object System.Windows.Forms.Panel
$modePanel.Location = New-Object System.Drawing.Point(10, 122)
$modePanel.Size = New-Object System.Drawing.Size(1145, 126)
$modePanel.Anchor = 'Top, Left, Right'
$modePanel.BackColor = [System.Drawing.Color]::White
$modePanel.BorderStyle = 'FixedSingle'
$form.Controls.Add($modePanel)

$modeIntro = New-Object System.Windows.Forms.Label
$modeIntro.Text = 'Pick a one-click mode, then tweak the tabs below if you want to go deeper.'
$modeIntro.Location = New-Object System.Drawing.Point(14, 10)
$modeIntro.Size = New-Object System.Drawing.Size(620, 18)
$modeIntro.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$modePanel.Controls.Add($modeIntro)

$buttonSpecs = @(
    @{Text='Quick Debloat';   Mode='Minimal';        X=14;  Width=104; Color=[System.Drawing.Color]::FromArgb(235, 236, 240)},
    @{Text='Recommended';     Mode='Recommended';    X=124; Width=104; Color=[System.Drawing.Color]::FromArgb(220, 238, 222)},
    @{Text='Origin Mode';     Mode='Origin';         X=234; Width=104; Color=[System.Drawing.Color]::FromArgb(250, 232, 210)},
    @{Text='Privacy + Boost'; Mode='Performance';    X=344; Width=108; Color=[System.Drawing.Color]::FromArgb(218, 231, 248)},
    @{Text='Max Performance'; Mode='MaxPerformance'; X=458; Width=118; Color=[System.Drawing.Color]::FromArgb(255, 224, 224)},
    @{Text='Max Privacy';     Mode='MaxPrivacy';     X=582; Width=100; Color=[System.Drawing.Color]::FromArgb(229, 220, 240)},
    @{Text='Stock / None';    Mode='None';           X=688; Width=100; Color=[System.Drawing.Color]::FromArgb(241, 241, 241)}
)
foreach ($spec in $buttonSpecs) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $spec.Text
    $btn.Size = New-Object System.Drawing.Size($spec.Width, 30)
    $btn.Location = New-Object System.Drawing.Point($spec.X, 34)
    $btn.BackColor = $spec.Color
    $btn.Tag = $spec.Mode
    $btn.Add_Click({ Apply-Preset $this.Tag })
    $modePanel.Controls.Add($btn)
}

$script:ModeLabel = New-Object System.Windows.Forms.Label
$script:ModeLabel.Location = New-Object System.Drawing.Point(14, 78)
$script:ModeLabel.Size = New-Object System.Drawing.Size(170, 18)
$script:ModeLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$modePanel.Controls.Add($script:ModeLabel)

$script:SelectionLabel = New-Object System.Windows.Forms.Label
$script:SelectionLabel.Location = New-Object System.Drawing.Point(190, 78)
$script:SelectionLabel.Size = New-Object System.Drawing.Size(150, 18)
$modePanel.Controls.Add($script:SelectionLabel)

$script:SystemLabel = New-Object System.Windows.Forms.Label
$script:SystemLabel.Location = New-Object System.Drawing.Point(346, 78)
$script:SystemLabel.Size = New-Object System.Drawing.Size(190, 18)
$modePanel.Controls.Add($script:SystemLabel)

$script:RiskLabel = New-Object System.Windows.Forms.Label
$script:RiskLabel.Location = New-Object System.Drawing.Point(542, 78)
$script:RiskLabel.Size = New-Object System.Drawing.Size(130, 18)
$script:RiskLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$modePanel.Controls.Add($script:RiskLabel)

$script:ModeDescription = New-Object System.Windows.Forms.Label
$script:ModeDescription.Location = New-Object System.Drawing.Point(678, 72)
$script:ModeDescription.Size = New-Object System.Drawing.Size(440, 36)
$script:ModeDescription.ForeColor = [System.Drawing.Color]::DimGray
$script:ModeDescription.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$modePanel.Controls.Add($script:ModeDescription)

# Tab control
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(10, 256)
$tabs.Size = New-Object System.Drawing.Size(1145, 410)
$tabs.Anchor = 'Top, Left, Right, Bottom'
$form.Controls.Add($tabs)

# Track every checkbox so we can iterate on apply/reset
$script:CheckBoxes = @()

foreach ($cat in $script:Policies.Keys) {
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = $cat
    $tab.AutoScroll = $true
    $tab.BackColor = [System.Drawing.Color]::White

    $selAll = New-Object System.Windows.Forms.LinkLabel
    $selAll.Text = 'Select all'
    $selAll.Location = New-Object System.Drawing.Point(10, 8)
    $selAll.AutoSize = $true
    $selAll.Tag = $cat
    $selAll.Add_LinkClicked({
        $myCat = $this.Tag
        $script:SuppressSelectionEvents = $true
        foreach ($cb in $script:CheckBoxes) {
            if ($cb.Tag.Category -eq $myCat) { $cb.Checked = $true }
        }
        $script:SuppressSelectionEvents = $false
        $script:ActiveProfile = 'Custom'
        Update-SelectionSummary
    })
    $tab.Controls.Add($selAll)

    $selNone = New-Object System.Windows.Forms.LinkLabel
    $selNone.Text = 'Select none'
    $selNone.Location = New-Object System.Drawing.Point(90, 8)
    $selNone.AutoSize = $true
    $selNone.Tag = $cat
    $selNone.Add_LinkClicked({
        $myCat = $this.Tag
        $script:SuppressSelectionEvents = $true
        foreach ($cb in $script:CheckBoxes) {
            if ($cb.Tag.Category -eq $myCat) { $cb.Checked = $false }
        }
        $script:SuppressSelectionEvents = $false
        $script:ActiveProfile = 'Custom'
        Update-SelectionSummary
    })
    $tab.Controls.Add($selNone)

    $y = 35
    foreach ($p in $script:Policies[$cat]) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = "$($p.Name)    =>  $($p.ApplyValue)"
        $cb.Location = New-Object System.Drawing.Point(15, $y)
        $cb.Size = New-Object System.Drawing.Size(450, 20)
        $cb.Font = New-Object System.Drawing.Font('Consolas', 9)
        $cb.Tag = @{Policy = $p; Category = $cat}
        $cb.Add_CheckedChanged({ Set-CustomMode })
        $tt.SetToolTip($cb, $p.Description)
        $tab.Controls.Add($cb)
        $script:CheckBoxes += $cb

        $desc = New-Object System.Windows.Forms.Label
        $desc.Text = $p.Description
        $desc.Location = New-Object System.Drawing.Point(475, ($y + 2))
        $desc.Size = New-Object System.Drawing.Size(630, 30)
        $desc.ForeColor = [System.Drawing.Color]::DimGray
        $desc.Font = New-Object System.Drawing.Font('Segoe UI', 8)
        $tab.Controls.Add($desc)

        $y += 28
    }
    $tabs.TabPages.Add($tab)
}

# ---- System tab: scheduled tasks + services --------------------------------
$sysTab = New-Object System.Windows.Forms.TabPage
$sysTab.Text = 'System (Tasks / Services)'
$sysTab.AutoScroll = $true
$sysTab.BackColor = [System.Drawing.Color]::White

$sysIntro = New-Object System.Windows.Forms.Label
$sysIntro.Text = "Background updaters matter most for the Privacy + Boost, Max Performance, and Max Privacy modes. Disabling services is the riskiest step because it can block Brave auto-updates."
$sysIntro.Location = New-Object System.Drawing.Point(10, 8)
$sysIntro.Size = New-Object System.Drawing.Size(1080, 30)
$sysIntro.ForeColor = [System.Drawing.Color]::FromArgb(120, 50, 50)
$sysTab.Controls.Add($sysIntro)

$script:TaskCheckBoxes = @()
$y = 50
$taskHdr = New-Object System.Windows.Forms.Label
$taskHdr.Text = 'Scheduled Tasks'
$taskHdr.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$taskHdr.Location = New-Object System.Drawing.Point(10, $y)
$taskHdr.AutoSize = $true
$sysTab.Controls.Add($taskHdr)
$y += 28
foreach ($t in $script:ScheduledTasks) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $t.Name
    $cb.Location = New-Object System.Drawing.Point(15, $y)
    $cb.Size = New-Object System.Drawing.Size(450, 20)
    $cb.Font = New-Object System.Drawing.Font('Consolas', 9)
    $cb.Tag = $t
    $cb.Add_CheckedChanged({ Set-CustomMode })
    $tt.SetToolTip($cb, $t.Description)
    $sysTab.Controls.Add($cb)
    $script:TaskCheckBoxes += $cb

    $desc = New-Object System.Windows.Forms.Label
    $desc.Text = $t.Description
    $desc.Location = New-Object System.Drawing.Point(475, ($y + 2))
    $desc.Size = New-Object System.Drawing.Size(630, 30)
    $desc.ForeColor = [System.Drawing.Color]::DimGray
    $desc.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $sysTab.Controls.Add($desc)
    $y += 28
}

$script:ServiceCheckBoxes = @()
$y += 15
$svcHdr = New-Object System.Windows.Forms.Label
$svcHdr.Text = 'Windows Services'
$svcHdr.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$svcHdr.Location = New-Object System.Drawing.Point(10, $y)
$svcHdr.AutoSize = $true
$sysTab.Controls.Add($svcHdr)
$y += 28
foreach ($s in $script:Services) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $s.Name
    $cb.Location = New-Object System.Drawing.Point(15, $y)
    $cb.Size = New-Object System.Drawing.Size(450, 20)
    $cb.Font = New-Object System.Drawing.Font('Consolas', 9)
    $cb.Tag = $s
    $cb.Add_CheckedChanged({ Set-CustomMode })
    $tt.SetToolTip($cb, $s.Description)
    $sysTab.Controls.Add($cb)
    $script:ServiceCheckBoxes += $cb

    $desc = New-Object System.Windows.Forms.Label
    $desc.Text = $s.Description
    $desc.Location = New-Object System.Drawing.Point(475, ($y + 2))
    $desc.Size = New-Object System.Drawing.Size(630, 30)
    $desc.ForeColor = [System.Drawing.Color]::DimGray
    $desc.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $sysTab.Controls.Add($desc)
    $y += 28
}

$tabs.TabPages.Add($sysTab)

# ---- Utility buttons --------------------------------------------------------
$utilityPanel = New-Object System.Windows.Forms.Panel
$utilityPanel.Location = New-Object System.Drawing.Point(10, 676)
$utilityPanel.Size = New-Object System.Drawing.Size(1145, 40)
$utilityPanel.Anchor = 'Left, Right, Bottom'
$form.Controls.Add($utilityPanel)

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = 'Load current state'
$btnLoad.Size = New-Object System.Drawing.Size(145, 30)
$btnLoad.Location = New-Object System.Drawing.Point(0, 5)
$btnLoad.Add_Click({
    $script:SuppressSelectionEvents = $true
    foreach ($cb in $script:CheckBoxes) {
        $p = $cb.Tag.Policy
        $cur = Get-ExistingPolicy $p.Name
        $cb.Checked = ($null -ne $cur -and "$cur" -eq "$($p.ApplyValue)")
    }
    foreach ($cb in $script:TaskCheckBoxes) {
        $t = $cb.Tag
        $task = Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue
        $cb.Checked = ($task -and $task.State -eq 'Disabled')
    }
    foreach ($cb in $script:ServiceCheckBoxes) {
        $s = $cb.Tag
        $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
        $cb.Checked = ($svc -and $svc.StartType -eq 'Disabled')
    }
    $script:SuppressSelectionEvents = $false
    $script:ActiveProfile = 'CurrentState'
    Update-SelectionSummary
    Write-Log 'Loaded current system state.'
})
$utilityPanel.Controls.Add($btnLoad)

$btnOpenBrave = New-Object System.Windows.Forms.Button
$btnOpenBrave.Text = 'Open brave://policy'
$btnOpenBrave.Size = New-Object System.Drawing.Size(150, 30)
$btnOpenBrave.Location = New-Object System.Drawing.Point(155, 5)
$btnOpenBrave.Add_Click({
    $exe = Test-BraveInstalled
    if ($exe) { Start-Process $exe 'brave://policy' }
    else { [System.Windows.Forms.MessageBox]::Show('Brave not found on this machine.', 'Info') | Out-Null }
})
$utilityPanel.Controls.Add($btnOpenBrave)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = 'Close'
$btnClose.Size = New-Object System.Drawing.Size(95, 30)
$btnClose.Location = New-Object System.Drawing.Point(315, 5)
$btnClose.Add_Click({ $form.Close() })
$utilityPanel.Controls.Add($btnClose)

$flowLabel = New-Object System.Windows.Forms.Label
$flowLabel.Text = 'Suggested flow: pick a mode -> tweak categories -> apply -> restart Brave -> verify at brave://policy'
$flowLabel.Location = New-Object System.Drawing.Point(430, 11)
$flowLabel.Size = New-Object System.Drawing.Size(690, 18)
$flowLabel.ForeColor = [System.Drawing.Color]::DimGray
$utilityPanel.Controls.Add($flowLabel)

# ---- Action buttons ---------------------------------------------------------
$actionPanel = New-Object System.Windows.Forms.Panel
$actionPanel.Location = New-Object System.Drawing.Point(10, 720)
$actionPanel.Size = New-Object System.Drawing.Size(1145, 44)
$actionPanel.Anchor = 'Left, Right, Bottom'
$form.Controls.Add($actionPanel)

$chkBackup = New-Object System.Windows.Forms.CheckBox
$chkBackup.Text = 'Backup existing policies before applying'
$chkBackup.Checked = $true
$chkBackup.Location = New-Object System.Drawing.Point(0, 12)
$chkBackup.Size = New-Object System.Drawing.Size(270, 20)
$actionPanel.Controls.Add($chkBackup)

$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text = 'Apply to Brave'
$btnApply.Size = New-Object System.Drawing.Size(150, 34)
$btnApply.Location = New-Object System.Drawing.Point(300, 4)
$btnApply.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 63)
$btnApply.ForeColor = [System.Drawing.Color]::White
$btnApply.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$btnApply.Add_Click({
    if ($chkBackup.Checked) { [void](Export-Backup) }

    $applied = 0
    $cleared = 0
    foreach ($cb in $script:CheckBoxes) {
        $p = $cb.Tag.Policy
        if ($cb.Checked) {
            try {
                Set-PolicyValue -Name $p.Name -Type $p.Type -Value $p.ApplyValue
                Write-Log "SET $($p.Name) = $($p.ApplyValue)" 'OK'
                $applied++
            } catch {
                Write-Log "FAIL $($p.Name): $_" 'ERR'
            }
        } else {
            if (Remove-PolicyValue -Name $p.Name) {
                Write-Log "CLEARED $($p.Name)" 'OK'
                $cleared++
            }
        }
    }

    foreach ($cb in $script:TaskCheckBoxes) {
        $t = $cb.Tag
        try {
            if ($cb.Checked) {
                Disable-ScheduledTask -TaskName $t.Name -ErrorAction Stop | Out-Null
                Write-Log "DISABLED task $($t.Name)" 'OK'
            } else {
                $existing = Get-ScheduledTask -TaskName $t.Name -ErrorAction SilentlyContinue
                if ($existing -and $existing.State -eq 'Disabled') {
                    Enable-ScheduledTask -TaskName $t.Name -ErrorAction Stop | Out-Null
                    Write-Log "ENABLED task $($t.Name)" 'OK'
                }
            }
        } catch {
            Write-Log "Task $($t.Name): $_" 'WARN'
        }
    }

    foreach ($cb in $script:ServiceCheckBoxes) {
        $s = $cb.Tag
        try {
            $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
            if (-not $svc) {
                Write-Log "Service $($s.Name) not present - skipped." 'INFO'
                continue
            }
            if ($cb.Checked) {
                if ($svc.Status -eq 'Running') { Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue }
                Set-Service -Name $s.Name -StartupType Disabled -ErrorAction Stop
                Write-Log "DISABLED service $($s.Name)" 'OK'
            } else {
                if ($svc.StartType -eq 'Disabled') {
                    Set-Service -Name $s.Name -StartupType Manual -ErrorAction Stop
                    Write-Log "RESET service $($s.Name) to Manual" 'OK'
                }
            }
        } catch {
            Write-Log "Service $($s.Name): $_" 'WARN'
        }
    }

    Update-SelectionSummary
    Write-Log "Done. Applied $applied policies, cleared $cleared. Restart Brave to take effect." 'DONE'
    $activeModeLabel = if ($script:ProfileDisplayNames.ContainsKey($script:ActiveProfile)) { $script:ProfileDisplayNames[$script:ActiveProfile] } else { $script:ActiveProfile }
    [System.Windows.Forms.MessageBox]::Show(
        "Mode: $activeModeLabel`r`nApplied $applied policies, cleared $cleared.`r`n`r`nRestart Brave to see changes.`r`nVerify at: brave://policy",
        'Brave Free Origin',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
})
$actionPanel.Controls.Add($btnApply)

$btnRemoveAll = New-Object System.Windows.Forms.Button
$btnRemoveAll.Text = 'Remove ALL policies'
$btnRemoveAll.Size = New-Object System.Drawing.Size(160, 34)
$btnRemoveAll.Location = New-Object System.Drawing.Point(460, 4)
$btnRemoveAll.BackColor = [System.Drawing.Color]::FromArgb(150, 60, 60)
$btnRemoveAll.ForeColor = [System.Drawing.Color]::White
$btnRemoveAll.Add_Click({
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "This will delete the entire HKLM\Software\Policies\BraveSoftware\Brave key.`r`nBrave returns to stock behaviour. Continue?",
        'Confirm',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($ans -ne 'Yes') { return }
    if ($chkBackup.Checked) { [void](Export-Backup) }
    try {
        Remove-Item -Path $script:BravePolicyPath -Recurse -Force -ErrorAction Stop
        Write-Log 'Removed entire Brave policy key.' 'OK'
    } catch {
        Write-Log "Remove-Item: $_" 'ERR'
    }
    $script:SuppressSelectionEvents = $true
    foreach ($cb in $script:CheckBoxes) { $cb.Checked = $false }
    foreach ($cb in $script:TaskCheckBoxes) { $cb.Checked = $false }
    foreach ($cb in $script:ServiceCheckBoxes) { $cb.Checked = $false }
    $script:SuppressSelectionEvents = $false
    $script:ActiveProfile = 'None'
    Update-SelectionSummary
})
$actionPanel.Controls.Add($btnRemoveAll)

# ---- Log box ----------------------------------------------------------------
$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Location = New-Object System.Drawing.Point(10, 770)
$script:LogBox.Size = New-Object System.Drawing.Size(1145, 90)
$script:LogBox.Multiline = $true
$script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.ReadOnly = $true
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$script:LogBox.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 18)
$script:LogBox.ForeColor = [System.Drawing.Color]::LightGreen
$script:LogBox.Anchor = 'Left, Right, Bottom'
$form.Controls.Add($script:LogBox)

Update-SelectionSummary

# ---- Startup ---------------------------------------------------------------
$form.Add_Shown({
    Write-Log 'Running as administrator - OK.'
    Write-Log "Brave version: $braveVer"
    Write-Log 'Loading current policy state...'
    $btnLoad.PerformClick()
})

[void]$form.ShowDialog()
