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

# ---- Multi-channel support (v1.5) -------------------------------------------
# Each Brave channel keeps its own policy hive. Default target is Stable.
# If user picks "All installed channels", every detected install gets the apply.
$script:Channels = [ordered]@{
    'Stable'  = @{
        Path = 'HKLM:\Software\Policies\BraveSoftware\Brave'
        InstallProbes = @(
            "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe",
            "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe",
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe"
        )
    }
    'Beta'    = @{
        Path = 'HKLM:\Software\Policies\BraveSoftware\Brave-Beta'
        InstallProbes = @(
            "$env:ProgramFiles\BraveSoftware\Brave-Browser-Beta\Application\brave.exe",
            "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser-Beta\Application\brave.exe",
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser-Beta\Application\brave.exe"
        )
    }
    'Nightly' = @{
        Path = 'HKLM:\Software\Policies\BraveSoftware\Brave-Nightly'
        InstallProbes = @(
            "$env:ProgramFiles\BraveSoftware\Brave-Browser-Nightly\Application\brave.exe",
            "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser-Nightly\Application\brave.exe",
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser-Nightly\Application\brave.exe"
        )
    }
    'Dev'     = @{
        Path = 'HKLM:\Software\Policies\BraveSoftware\Brave-Dev'
        InstallProbes = @(
            "$env:ProgramFiles\BraveSoftware\Brave-Browser-Dev\Application\brave.exe",
            "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser-Dev\Application\brave.exe",
            "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser-Dev\Application\brave.exe"
        )
    }
}
$script:TargetChannels = @('Stable')

function Get-DetectedChannels {
    $found = @()
    foreach ($name in $script:Channels.Keys) {
        foreach ($probe in $script:Channels[$name].InstallProbes) {
            if (Test-Path $probe) { $found += $name; break }
        }
    }
    return $found
}

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

# ---- Hosts blocklist groups (v1.5) ------------------------------------------
# DNS-level kill switch via the Windows hosts file. Conservative on purpose -
# only the two safest groups are pre-ticked. Anything that could break browsing
# or Brave updates is off by default with a warning label.
$script:HostsBlocks = @(
    @{Name='Brave P3A telemetry';     Recommended=$true;  Domains=@('p3a.brave.com','p3a-creative.brave.com','p2a.brave.com','p2a-creative.brave.com');                Description='Privacy-preserving analytics endpoints. Pure telemetry, never user-facing. Safe to block.'},
    @{Name='Brave Variations';        Recommended=$true;  Domains=@('variations.brave.com','go-updater.brave.com');                                                    Description='Field-trial / experiment config. Safe to block - matches ChromeVariations=2 policy.'},
    @{Name='Brave Stats ping';        Recommended=$true;  Domains=@('laptop-updates.brave.com');                                                                       Description='Daily/weekly/monthly anonymous usage ping. Safe to block.'},
    @{Name='Brave Rewards / BAT';     Recommended=$false; Domains=@('rewards.brave.com','grant.rewards.brave.com','creators.brave.com');                               Description='Brave Rewards (BAT) servers. Block ONLY if you do not use Rewards. Will break the feature if you turn it on later.'},
    @{Name='Brave News CDN';          Recommended=$false; Domains=@('brave-today-cdn.brave.com','brave-today.brave.com');                                              Description='News content CDN. Block ONLY if you have disabled News - unblocking is needed if you ever re-enable it.'},
    @{Name='Component Updates';       Recommended=$false; Domains=@('componentupdater.brave.com','brave-core-ext.s3.brave.com');                                       Description='WARNING: blocking this stops Widevine/CRX/iOS-style components from updating. Use only if ComponentUpdatesEnabled is also off.'},
    @{Name='Web Discovery';           Recommended=$false; Domains=@('search.anonymous.brave.com','wdp.brave.com');                                                     Description='Web Discovery Project endpoints. Already covered by BraveWebDiscoveryEnabled policy; only useful if policy is bypassed.'}
)
$script:HostsSentinelStart = '# === Brave-Free-Origin START - managed block, do not edit between sentinels ==='
$script:HostsSentinelEnd   = '# === Brave-Free-Origin END ==='
$script:HostsFile = "$env:WINDIR\System32\drivers\etc\hosts"

# ---- Search engines (v1.6) -------------------------------------------------
# Used for the optional "force default search engine via policy" feature.
# {searchTerms} is the standard Chromium placeholder Brave fills in.
$script:SearchEngines = [ordered]@{
    'Brave Search'   = @{ URL='https://search.brave.com/search?q={searchTerms}';     Suggest='https://search.brave.com/api/suggest?q={searchTerms}';                       Keyword='brave';     Home='https://search.brave.com' }
    'DuckDuckGo'     = @{ URL='https://duckduckgo.com/?q={searchTerms}';             Suggest='https://duckduckgo.com/ac/?q={searchTerms}&type=list';                      Keyword='ddg';       Home='https://duckduckgo.com' }
    'Startpage'      = @{ URL='https://www.startpage.com/do/search?q={searchTerms}';  Suggest='';                                                                          Keyword='startpage'; Home='https://www.startpage.com' }
    'Qwant'          = @{ URL='https://www.qwant.com/?q={searchTerms}';               Suggest='https://api.qwant.com/api/suggest?q={searchTerms}';                         Keyword='qwant';     Home='https://www.qwant.com' }
    'Ecosia'         = @{ URL='https://www.ecosia.org/search?q={searchTerms}';        Suggest='https://ac.ecosia.org/?q={searchTerms}';                                    Keyword='ecosia';    Home='https://www.ecosia.org' }
    'Mojeek'         = @{ URL='https://www.mojeek.com/search?q={searchTerms}';        Suggest='';                                                                          Keyword='mojeek';    Home='https://www.mojeek.com' }
    'Kagi (paid)'    = @{ URL='https://kagi.com/search?q={searchTerms}';              Suggest='https://kagi.com/api/autosuggest?q={searchTerms}';                          Keyword='kagi';      Home='https://kagi.com' }
    'Google'         = @{ URL='https://www.google.com/search?q={searchTerms}';        Suggest='https://www.google.com/complete/search?output=chrome&q={searchTerms}';     Keyword='google';    Home='https://www.google.com' }
    'Bing'           = @{ URL='https://www.bing.com/search?q={searchTerms}';          Suggest='https://www.bing.com/osjson.aspx?query={searchTerms}';                      Keyword='bing';      Home='https://www.bing.com' }
    'Yandex'         = @{ URL='https://yandex.com/search/?text={searchTerms}';        Suggest='https://suggest.yandex.com/suggest-ff.cgi?part={searchTerms}';             Keyword='yandex';    Home='https://yandex.com' }
    'Custom...'      = @{ URL='';                                                     Suggest='';                                                                          Keyword='custom';    Home='';                                IsCustom=$true }
}

# Destination presets for "new tab" and "startup specific page" dropdowns.
# Anything '__SEARCH__' resolves at apply-time to the chosen engine's home URL.
$script:DestinationOptions = [ordered]@{
    'Blank page (about:blank)'                  = 'about:blank'
    'Default new tab page (do not override)'    = '__SKIP__'
    'Match the search engine I picked above'    = '__SEARCH__'
    'Brave Search homepage'                     = 'https://search.brave.com'
    'DuckDuckGo homepage'                       = 'https://duckduckgo.com'
    'Google homepage'                           = 'https://www.google.com'
    'Custom URL...'                             = '__CUSTOM__'
}

# Startup behavior modes (RestoreOnStartup policy values).
$script:StartupModes = [ordered]@{
    'Open the new tab page'        = @{ Code=5; UsesURL=$false }
    'Restore my last session'      = @{ Code=1; UsesURL=$false }
    'Open a blank page'            = @{ Code=4; UsesURL=$true; FixedURL='about:blank' }
    'Open a specific page or set'  = @{ Code=4; UsesURL=$true; FixedURL=$null }
}
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

# ---- Hosts file helpers (v1.5) ----------------------------------------------
function Backup-HostsFile {
    if (-not (Test-Path $script:HostsFile)) { return $null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $env:USERPROFILE 'Documents\Brave-Free-Origin-Backups'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $file = Join-Path $dir "hosts-backup-$stamp.bak"
    Copy-Item $script:HostsFile $file -Force
    Write-Log "Hosts backup saved: $file" 'OK'
    return $file
}

function Get-HostsCurrentDomains {
    if (-not (Test-Path $script:HostsFile)) { return @() }
    $lines = Get-Content $script:HostsFile -ErrorAction SilentlyContinue
    $inBlock = $false
    $domains = @()
    foreach ($line in $lines) {
        if ($line -eq $script:HostsSentinelStart) { $inBlock = $true; continue }
        if ($line -eq $script:HostsSentinelEnd)   { $inBlock = $false; continue }
        if ($inBlock -and $line -match '^\s*0\.0\.0\.0\s+(\S+)') {
            $domains += $Matches[1]
        }
    }
    return $domains
}

function Set-HostsBlockDomains {
    param([string[]]$Domains)
    [void](Backup-HostsFile)

    # Read all lines, strip out our existing sentinel block (if any)
    $lines = if (Test-Path $script:HostsFile) { Get-Content $script:HostsFile } else { @() }
    $kept = New-Object System.Collections.ArrayList
    $skipping = $false
    foreach ($line in $lines) {
        if ($line -eq $script:HostsSentinelStart) { $skipping = $true; continue }
        if ($line -eq $script:HostsSentinelEnd)   { $skipping = $false; continue }
        if (-not $skipping) { [void]$kept.Add($line) }
    }

    # Trim trailing blank lines from existing content for tidiness
    while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) {
        $kept.RemoveAt($kept.Count - 1)
    }

    if ($Domains -and $Domains.Count -gt 0) {
        [void]$kept.Add('')
        [void]$kept.Add($script:HostsSentinelStart)
        [void]$kept.Add("# Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') by Brave Free Origin. Remove via the GUI.")
        foreach ($d in ($Domains | Sort-Object -Unique)) {
            [void]$kept.Add("0.0.0.0 $d")
        }
        [void]$kept.Add($script:HostsSentinelEnd)
    }

    # ASCII encoding - matches what Windows expects for hosts. Some AVs flag UTF-16 hosts.
    Set-Content -Path $script:HostsFile -Value $kept -Encoding ASCII -Force

    # Flush DNS so the change takes effect immediately for new connections
    & ipconfig.exe /flushdns | Out-Null
    Write-Log "Hosts block written: $($Domains.Count) domain(s). DNS cache flushed." 'OK'
}

function Clear-HostsBlock {
    Set-HostsBlockDomains -Domains @()
    Write-Log 'Hosts sentinel block removed.' 'OK'
}
# -----------------------------------------------------------------------------

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
$form.Text = "Brave Free Origin v1.7  -  the free answer to Brave Origin's paywalled minimal mode"
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
    'TorDisabled',
    # Shields / privacy-engine policies - keeping ad-block ON is a *performance* win
    # (fewer requests, less DOM, less JS). It's also Brave's identity. Origin Mode
    # and everything that derives from it (Privacy + Boost) now enforces these.
    'DefaultBraveAdblockSetting',
    'DefaultBraveFingerprintingV2Setting',
    'DefaultBraveReferrersSetting',
    'BraveTrackingQueryParametersFilteringEnabled',
    'BraveDeAmpEnabled',
    'BraveDebouncingEnabled'
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

    # Hosts groups: only auto-tick a group when the corresponding feature is
    # ALSO disabled by policy in this preset. No orphan blocks.
    $hostsAlwaysSafe   = @('Brave P3A telemetry','Brave Variations','Brave Stats ping','Web Discovery')
    $hostsRewards      = @('Brave Rewards / BAT')
    $hostsNews         = @('Brave News CDN')
    $hostsComponents   = @('Component Updates')

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
                Hosts    = $hostsAlwaysSafe + $hostsRewards + $hostsNews
            }
        }
        'MaxPrivacy' {
            return @{
                Policies = @($script:MaxPrivacyPolicies)
                Tasks    = @($script:ScheduledTasks.Name)
                Services = @($script:Services.Name)
                Hosts    = $hostsAlwaysSafe + $hostsRewards + $hostsNews + $hostsComponents
            }
        }
        'Minimal' {
            return @{
                Policies = @($script:MinimalPolicies)
                Tasks    = @()
                Services = @()
                Hosts    = $hostsAlwaysSafe + $hostsRewards   # Quick disables Rewards, leaves News on
            }
        }
        'Origin' {
            return @{
                Policies = @($script:OriginPolicies)
                Tasks    = @()
                Services = @()
                Hosts    = $hostsAlwaysSafe + $hostsRewards + $hostsNews   # Origin disables both
            }
        }
        'Performance' {
            return @{
                Policies = @($script:PerformancePolicies)
                Tasks    = @($script:ScheduledTasks.Name)
                Services = @()
                Hosts    = $hostsAlwaysSafe + $hostsRewards + $hostsNews
            }
        }
        'MaxPerformance' {
            return @{
                Policies = @($script:MaxPerformancePolicies)
                Tasks    = @($script:ScheduledTasks.Name)
                Services = @($script:Services.Name)
                Hosts    = $hostsAlwaysSafe + $hostsRewards + $hostsNews + $hostsComponents
            }
        }
        default {
            return @{
                Policies = @()
                Tasks    = @()
                Services = @()
                Hosts    = @()
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
    # Hosts checkboxes (created later in the GUI; guard if not yet built)
    if ($script:HostsCheckBoxes) {
        foreach ($cb in $script:HostsCheckBoxes) {
            $cb.Checked = $payload.Hosts -contains $cb.Tag.Name
        }
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
$metaLabel.Text = "Brave detected: $braveVer"
$metaLabel.ForeColor = [System.Drawing.Color]::LightSteelBlue
$metaLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$metaLabel.Location = New-Object System.Drawing.Point(20, 70)
$metaLabel.Size = New-Object System.Drawing.Size(280, 18)
$header.Controls.Add($metaLabel)

# Channel selector (multi-channel support)
$detectedChannels = Get-DetectedChannels
$channelLabel = New-Object System.Windows.Forms.Label
$channelLabel.Text = 'Target channel:'
$channelLabel.ForeColor = [System.Drawing.Color]::LightSteelBlue
$channelLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$channelLabel.Location = New-Object System.Drawing.Point(310, 70)
$channelLabel.Size = New-Object System.Drawing.Size(95, 18)
$header.Controls.Add($channelLabel)

$script:ChannelCombo = New-Object System.Windows.Forms.ComboBox
$script:ChannelCombo.Location = New-Object System.Drawing.Point(405, 67)
$script:ChannelCombo.Size = New-Object System.Drawing.Size(220, 22)
$script:ChannelCombo.DropDownStyle = 'DropDownList'
$script:ChannelCombo.FlatStyle = 'Flat'
foreach ($name in $script:Channels.Keys) {
    $marker = if ($detectedChannels -contains $name) { '  (installed)' } else { '  (not installed)' }
    [void]$script:ChannelCombo.Items.Add("$name$marker")
}
if ($detectedChannels.Count -gt 1) { [void]$script:ChannelCombo.Items.Add('All installed channels') }
$script:ChannelCombo.SelectedIndex = 0
$header.Controls.Add($script:ChannelCombo)

$script:TargetPathLabel = New-Object System.Windows.Forms.Label
$script:TargetPathLabel.Text = "-> $($script:Channels['Stable'].Path)"
$script:TargetPathLabel.ForeColor = [System.Drawing.Color]::Gray
$script:TargetPathLabel.Font = New-Object System.Drawing.Font('Consolas', 8)
$script:TargetPathLabel.Location = New-Object System.Drawing.Point(635, 70)
$script:TargetPathLabel.Size = New-Object System.Drawing.Size(500, 18)
$header.Controls.Add($script:TargetPathLabel)

$script:ChannelCombo.Add_SelectedIndexChanged({
    $sel = $script:ChannelCombo.SelectedItem.ToString()
    if ($sel -eq 'All installed channels') {
        $script:TargetChannels = Get-DetectedChannels
        if ($script:TargetChannels.Count -eq 0) { $script:TargetChannels = @('Stable') }
        $script:BravePolicyPath = $script:Channels[$script:TargetChannels[0]].Path
        $script:TargetPathLabel.Text = "-> $($script:TargetChannels -join ', ') ($($script:TargetChannels.Count) hives)"
    } else {
        $name = ($sel -split '  ')[0]
        $script:TargetChannels = @($name)
        $script:BravePolicyPath = $script:Channels[$name].Path
        $script:TargetPathLabel.Text = "-> $($script:Channels[$name].Path)"
    }
    Write-Log "Target channel(s): $($script:TargetChannels -join ', ')"
})

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

# ---- Hosts blocklist tab (v1.5) --------------------------------------------
# Independent from the main Apply button - has its own Apply/Remove inside the tab.
# Sentinel-tagged so revert is surgical. Auto-backs up hosts file before any write.
$hostsTab = New-Object System.Windows.Forms.TabPage
$hostsTab.Text = 'Hosts Blocklist (DNS-level)'
$hostsTab.AutoScroll = $true
$hostsTab.BackColor = [System.Drawing.Color]::White

$hostsIntro = New-Object System.Windows.Forms.Label
$hostsIntro.Text = "Optional second layer of defense: nullroute Brave telemetry domains in C:\Windows\System32\drivers\etc\hosts. Even if a policy is bypassed by an update, the network call still fails. Sentinel-tagged for clean revert. Backups land in Documents\Brave-Free-Origin-Backups."
$hostsIntro.Location = New-Object System.Drawing.Point(10, 8)
$hostsIntro.Size = New-Object System.Drawing.Size(1100, 36)
$hostsIntro.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 90)
$hostsTab.Controls.Add($hostsIntro)

$hostsWarn = New-Object System.Windows.Forms.Label
$hostsWarn.Text = 'Independent of the "Apply to Brave" button. Use the buttons in this tab to apply or remove the hosts block.'
$hostsWarn.Location = New-Object System.Drawing.Point(10, 44)
$hostsWarn.Size = New-Object System.Drawing.Size(1100, 18)
$hostsWarn.ForeColor = [System.Drawing.Color]::FromArgb(160, 70, 30)
$hostsWarn.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 8.5)
$hostsTab.Controls.Add($hostsWarn)

$script:HostsCheckBoxes = @()
$y = 70
foreach ($block in $script:HostsBlocks) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = "$($block.Name)  [$($block.Domains.Count) domain$(if($block.Domains.Count -ne 1){'s'})]"
    $cb.Location = New-Object System.Drawing.Point(15, $y)
    $cb.Size = New-Object System.Drawing.Size(360, 20)
    $cb.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $cb.Checked = [bool]$block.Recommended
    $cb.Tag = $block
    $tt.SetToolTip($cb, $block.Description)
    $hostsTab.Controls.Add($cb)
    $script:HostsCheckBoxes += $cb

    $desc = New-Object System.Windows.Forms.Label
    $desc.Text = $block.Description
    $desc.Location = New-Object System.Drawing.Point(385, ($y + 2))
    $desc.Size = New-Object System.Drawing.Size(720, 32)
    $desc.ForeColor = [System.Drawing.Color]::DimGray
    $desc.Font = New-Object System.Drawing.Font('Segoe UI', 8)
    $hostsTab.Controls.Add($desc)

    $domLabel = New-Object System.Windows.Forms.Label
    $domLabel.Text = ($block.Domains -join ', ')
    $domLabel.Location = New-Object System.Drawing.Point(35, ($y + 22))
    $domLabel.Size = New-Object System.Drawing.Size(340, 16)
    $domLabel.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $domLabel.Font = New-Object System.Drawing.Font('Consolas', 8)
    $hostsTab.Controls.Add($domLabel)

    $y += 44
}

$btnApplyHosts = New-Object System.Windows.Forms.Button
$btnApplyHosts.Text = 'Apply hosts blocks'
$btnApplyHosts.Size = New-Object System.Drawing.Size(160, 30)
$btnApplyHosts.Location = New-Object System.Drawing.Point(15, ($y + 10))
$btnApplyHosts.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 63)
$btnApplyHosts.ForeColor = [System.Drawing.Color]::White
$btnApplyHosts.Add_Click({
    $domains = @()
    foreach ($cb in $script:HostsCheckBoxes) {
        if ($cb.Checked) { $domains += $cb.Tag.Domains }
    }
    if ($domains.Count -eq 0) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            'No groups ticked. This will remove the existing hosts block (if any). Continue?',
            'Hosts blocklist', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }
    } else {
        $msg = "About to add $($domains.Count) entries to:`r`n$($script:HostsFile)`r`n`r`nA timestamped backup will be saved first. Continue?"
        $ans = [System.Windows.Forms.MessageBox]::Show($msg, 'Hosts blocklist', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }
    }
    try {
        Set-HostsBlockDomains -Domains $domains
        [System.Windows.Forms.MessageBox]::Show("Hosts file updated. $($domains.Count) domain(s) blocked.`r`nDNS cache flushed.", 'Done', 'OK', 'Information') | Out-Null
    } catch {
        Write-Log "Hosts apply failed: $_" 'ERR'
        [System.Windows.Forms.MessageBox]::Show("Failed: $_", 'Error', 'OK', 'Error') | Out-Null
    }
})
$hostsTab.Controls.Add($btnApplyHosts)

$btnClearHosts = New-Object System.Windows.Forms.Button
$btnClearHosts.Text = 'Remove hosts block'
$btnClearHosts.Size = New-Object System.Drawing.Size(160, 30)
$btnClearHosts.Location = New-Object System.Drawing.Point(185, ($y + 10))
$btnClearHosts.Add_Click({
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "Remove the Brave-Free-Origin sentinel block from hosts?`r`n(Your other hosts entries are not touched.)",
        'Hosts blocklist', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { return }
    try {
        Clear-HostsBlock
        foreach ($cb in $script:HostsCheckBoxes) { $cb.Checked = $false }
        [System.Windows.Forms.MessageBox]::Show('Sentinel block removed.', 'Done', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Failed: $_", 'Error', 'OK', 'Error') | Out-Null
    }
})
$hostsTab.Controls.Add($btnClearHosts)

$btnLoadHosts = New-Object System.Windows.Forms.Button
$btnLoadHosts.Text = 'Load current state'
$btnLoadHosts.Size = New-Object System.Drawing.Size(160, 30)
$btnLoadHosts.Location = New-Object System.Drawing.Point(355, ($y + 10))
$btnLoadHosts.Add_Click({
    $current = Get-HostsCurrentDomains
    foreach ($cb in $script:HostsCheckBoxes) {
        $blockDomains = $cb.Tag.Domains
        $allPresent = $true
        foreach ($d in $blockDomains) { if ($current -notcontains $d) { $allPresent = $false; break } }
        $cb.Checked = $allPresent
    }
    Write-Log "Hosts state loaded: $($current.Count) domain(s) currently blocked."
})
$hostsTab.Controls.Add($btnLoadHosts)

$btnOpenHosts = New-Object System.Windows.Forms.Button
$btnOpenHosts.Text = 'Open hosts file'
$btnOpenHosts.Size = New-Object System.Drawing.Size(140, 30)
$btnOpenHosts.Location = New-Object System.Drawing.Point(525, ($y + 10))
$btnOpenHosts.Add_Click({ Start-Process notepad.exe $script:HostsFile })
$hostsTab.Controls.Add($btnOpenHosts)

$tabs.TabPages.Add($hostsTab)

# ---- Search & Startup tab (v1.6) -------------------------------------------
# Three independent, opt-in sections. Each has its own "Override" checkbox.
# Off by default: Brave's user-chosen search engine and startup behavior stay
# untouched unless the user actively ticks an override.
$searchTab = New-Object System.Windows.Forms.TabPage
$searchTab.Text = 'Search & Startup'
$searchTab.AutoScroll = $true
$searchTab.BackColor = [System.Drawing.Color]::White

$searchIntro = New-Object System.Windows.Forms.Label
$searchIntro.Text = 'Pick the omnibox search engine and what opens when Brave launches / when you open a new tab. Each section is independent and only fires when its checkbox is ticked. Unticking + Apply removes the override.'
$searchIntro.Location = New-Object System.Drawing.Point(10, 8)
$searchIntro.Size = New-Object System.Drawing.Size(1100, 36)
$searchIntro.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 90)
$searchTab.Controls.Add($searchIntro)

# --- Section 1: Default search engine ---
$secSearch = New-Object System.Windows.Forms.GroupBox
$secSearch.Text = 'Default search engine (omnibox / address bar)'
$secSearch.Location = New-Object System.Drawing.Point(10, 50)
$secSearch.Size = New-Object System.Drawing.Size(1110, 110)
$secSearch.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$searchTab.Controls.Add($secSearch)

$script:ChkSearchOverride = New-Object System.Windows.Forms.CheckBox
$script:ChkSearchOverride.Text = 'Force a default search engine (writes DefaultSearchProvider* policies)'
$script:ChkSearchOverride.Location = New-Object System.Drawing.Point(15, 22)
$script:ChkSearchOverride.Size = New-Object System.Drawing.Size(530, 20)
$script:ChkSearchOverride.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$secSearch.Controls.Add($script:ChkSearchOverride)

$lblEngine = New-Object System.Windows.Forms.Label
$lblEngine.Text = 'Engine:'
$lblEngine.Location = New-Object System.Drawing.Point(35, 50)
$lblEngine.Size = New-Object System.Drawing.Size(60, 18)
$lblEngine.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$secSearch.Controls.Add($lblEngine)

$script:CmbSearchEngine = New-Object System.Windows.Forms.ComboBox
$script:CmbSearchEngine.Location = New-Object System.Drawing.Point(95, 47)
$script:CmbSearchEngine.Size = New-Object System.Drawing.Size(200, 22)
$script:CmbSearchEngine.DropDownStyle = 'DropDownList'
foreach ($name in $script:SearchEngines.Keys) { [void]$script:CmbSearchEngine.Items.Add($name) }
$script:CmbSearchEngine.SelectedIndex = 0
$secSearch.Controls.Add($script:CmbSearchEngine)

$lblCustomSearch = New-Object System.Windows.Forms.Label
$lblCustomSearch.Text = 'Custom search URL:'
$lblCustomSearch.Location = New-Object System.Drawing.Point(310, 50)
$lblCustomSearch.Size = New-Object System.Drawing.Size(115, 18)
$lblCustomSearch.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$secSearch.Controls.Add($lblCustomSearch)

$script:TxtCustomSearchUrl = New-Object System.Windows.Forms.TextBox
$script:TxtCustomSearchUrl.Location = New-Object System.Drawing.Point(425, 47)
$script:TxtCustomSearchUrl.Size = New-Object System.Drawing.Size(370, 22)
$script:TxtCustomSearchUrl.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$script:TxtCustomSearchUrl.Enabled = $false
$secSearch.Controls.Add($script:TxtCustomSearchUrl)

$searchHelp = New-Object System.Windows.Forms.Label
$searchHelp.Text = 'Custom must use {searchTerms} as the placeholder. Example: https://my-searx/search?q={searchTerms}'
$searchHelp.Location = New-Object System.Drawing.Point(35, 78)
$searchHelp.Size = New-Object System.Drawing.Size(900, 18)
$searchHelp.ForeColor = [System.Drawing.Color]::DimGray
$searchHelp.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$secSearch.Controls.Add($searchHelp)

$script:CmbSearchEngine.Add_SelectedIndexChanged({
    $isCustom = ($script:CmbSearchEngine.SelectedItem -eq 'Custom...')
    $script:TxtCustomSearchUrl.Enabled = $isCustom
})

# --- Section 2: New tab page ---
$secNtp = New-Object System.Windows.Forms.GroupBox
$secNtp.Text = 'New Tab Page'
$secNtp.Location = New-Object System.Drawing.Point(10, 168)
$secNtp.Size = New-Object System.Drawing.Size(1110, 90)
$secNtp.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$searchTab.Controls.Add($secNtp)

$script:ChkNtpOverride = New-Object System.Windows.Forms.CheckBox
$script:ChkNtpOverride.Text = 'Override new tab page (writes NewTabPageLocation policy)'
$script:ChkNtpOverride.Location = New-Object System.Drawing.Point(15, 22)
$script:ChkNtpOverride.Size = New-Object System.Drawing.Size(450, 20)
$script:ChkNtpOverride.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$secNtp.Controls.Add($script:ChkNtpOverride)

$lblNtpDest = New-Object System.Windows.Forms.Label
$lblNtpDest.Text = 'Open:'
$lblNtpDest.Location = New-Object System.Drawing.Point(35, 50)
$lblNtpDest.Size = New-Object System.Drawing.Size(50, 18)
$secNtp.Controls.Add($lblNtpDest)

$script:CmbNtpDest = New-Object System.Windows.Forms.ComboBox
$script:CmbNtpDest.Location = New-Object System.Drawing.Point(85, 47)
$script:CmbNtpDest.Size = New-Object System.Drawing.Size(310, 22)
$script:CmbNtpDest.DropDownStyle = 'DropDownList'
foreach ($name in $script:DestinationOptions.Keys) {
    if ($name -ne 'Default new tab page (do not override)') { [void]$script:CmbNtpDest.Items.Add($name) }
}
$script:CmbNtpDest.SelectedIndex = 0
$secNtp.Controls.Add($script:CmbNtpDest)

$lblNtpCustom = New-Object System.Windows.Forms.Label
$lblNtpCustom.Text = 'Custom URL:'
$lblNtpCustom.Location = New-Object System.Drawing.Point(410, 50)
$lblNtpCustom.Size = New-Object System.Drawing.Size(80, 18)
$secNtp.Controls.Add($lblNtpCustom)

$script:TxtNtpCustomUrl = New-Object System.Windows.Forms.TextBox
$script:TxtNtpCustomUrl.Location = New-Object System.Drawing.Point(490, 47)
$script:TxtNtpCustomUrl.Size = New-Object System.Drawing.Size(305, 22)
$script:TxtNtpCustomUrl.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$script:TxtNtpCustomUrl.Enabled = $false
$secNtp.Controls.Add($script:TxtNtpCustomUrl)

$script:CmbNtpDest.Add_SelectedIndexChanged({
    $isCustom = ($script:CmbNtpDest.SelectedItem -eq 'Custom URL...')
    $script:TxtNtpCustomUrl.Enabled = $isCustom
})

# --- Section 3: Startup behavior ---
$secStartup = New-Object System.Windows.Forms.GroupBox
$secStartup.Text = 'Startup Behavior (what opens when you launch Brave)'
$secStartup.Location = New-Object System.Drawing.Point(10, 266)
$secStartup.Size = New-Object System.Drawing.Size(1110, 110)
$secStartup.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$searchTab.Controls.Add($secStartup)

$script:ChkStartupOverride = New-Object System.Windows.Forms.CheckBox
$script:ChkStartupOverride.Text = 'Override startup behavior (writes RestoreOnStartup + RestoreOnStartupURLs policies)'
$script:ChkStartupOverride.Location = New-Object System.Drawing.Point(15, 22)
$script:ChkStartupOverride.Size = New-Object System.Drawing.Size(550, 20)
$script:ChkStartupOverride.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$secStartup.Controls.Add($script:ChkStartupOverride)

$lblStartMode = New-Object System.Windows.Forms.Label
$lblStartMode.Text = 'Mode:'
$lblStartMode.Location = New-Object System.Drawing.Point(35, 50)
$lblStartMode.Size = New-Object System.Drawing.Size(50, 18)
$secStartup.Controls.Add($lblStartMode)

$script:CmbStartupMode = New-Object System.Windows.Forms.ComboBox
$script:CmbStartupMode.Location = New-Object System.Drawing.Point(85, 47)
$script:CmbStartupMode.Size = New-Object System.Drawing.Size(310, 22)
$script:CmbStartupMode.DropDownStyle = 'DropDownList'
foreach ($name in $script:StartupModes.Keys) { [void]$script:CmbStartupMode.Items.Add($name) }
$script:CmbStartupMode.SelectedIndex = 0
$secStartup.Controls.Add($script:CmbStartupMode)

$lblStartUrl = New-Object System.Windows.Forms.Label
$lblStartUrl.Text = 'URL(s):'
$lblStartUrl.Location = New-Object System.Drawing.Point(410, 50)
$lblStartUrl.Size = New-Object System.Drawing.Size(60, 18)
$secStartup.Controls.Add($lblStartUrl)

$script:TxtStartupUrl = New-Object System.Windows.Forms.TextBox
$script:TxtStartupUrl.Location = New-Object System.Drawing.Point(470, 47)
$script:TxtStartupUrl.Size = New-Object System.Drawing.Size(325, 22)
$script:TxtStartupUrl.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$script:TxtStartupUrl.Enabled = $false
$secStartup.Controls.Add($script:TxtStartupUrl)

$startupHelp = New-Object System.Windows.Forms.Label
$startupHelp.Text = 'For "specific page or set", separate multiple URLs with a comma. Each opens in its own tab.'
$startupHelp.Location = New-Object System.Drawing.Point(35, 78)
$startupHelp.Size = New-Object System.Drawing.Size(900, 18)
$startupHelp.ForeColor = [System.Drawing.Color]::DimGray
$startupHelp.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$secStartup.Controls.Add($startupHelp)

$script:CmbStartupMode.Add_SelectedIndexChanged({
    $sel = $script:CmbStartupMode.SelectedItem
    $mode = $script:StartupModes[$sel]
    $script:TxtStartupUrl.Enabled = ($mode.UsesURL -and -not $mode.FixedURL)
})

# Conflict note
$conflictNote = New-Object System.Windows.Forms.Label
$conflictNote.Text = "Note: this tab is processed AFTER the Performance / Startup tab, so it cleanly overrides any 'NewTabPageLocation' / 'HomepageLocation' / 'RestoreOnStartup' values set there. Untick + Apply removes the override and lets your Performance tab values (or stock Brave) take back over."
$conflictNote.Location = New-Object System.Drawing.Point(10, 384)
$conflictNote.Size = New-Object System.Drawing.Size(1100, 36)
$conflictNote.ForeColor = [System.Drawing.Color]::FromArgb(120, 60, 30)
$conflictNote.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$searchTab.Controls.Add($conflictNote)

# --- Section 4: Extensions (manual installs, no force-push) -----------------
$secExt = New-Object System.Windows.Forms.GroupBox
$secExt.Text = 'Extensions (optional, manual install)'
$secExt.Location = New-Object System.Drawing.Point(10, 426)
$secExt.Size = New-Object System.Drawing.Size(1110, 130)
$secExt.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$searchTab.Controls.Add($secExt)

$extIntro = New-Object System.Windows.Forms.Label
$extIntro.Text = "Brave Shields is already a native ad/tracker blocker (same filter-list lineage as uBlock Origin, runs in-engine so slightly faster). We do NOT force-install anything - that would show a 'Managed by your organization' banner and lock the extension on. These buttons just open the install pages in Brave so you can decide."
$extIntro.Location = New-Object System.Drawing.Point(15, 22)
$extIntro.Size = New-Object System.Drawing.Size(1080, 36)
$extIntro.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$extIntro.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$secExt.Controls.Add($extIntro)

$extWarn = New-Object System.Windows.Forms.Label
$extWarn.Text = 'Caution: running uBlock Origin on top of Shields = double-blocking. Wastes CPU per tab and can break sites Shields handles fine. If you install uBO, consider switching Shields to Standard (not Aggressive) to reduce overlap.'
$extWarn.Location = New-Object System.Drawing.Point(15, 60)
$extWarn.Size = New-Object System.Drawing.Size(1080, 32)
$extWarn.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$extWarn.ForeColor = [System.Drawing.Color]::FromArgb(160, 70, 30)
$secExt.Controls.Add($extWarn)

$btnUboLite = New-Object System.Windows.Forms.Button
$btnUboLite.Text = 'Install uBlock Origin Lite (MV3)'
$btnUboLite.Size = New-Object System.Drawing.Size(220, 28)
$btnUboLite.Location = New-Object System.Drawing.Point(15, 95)
$btnUboLite.Add_Click({
    $exe = Test-BraveInstalled
    $url = 'https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh'
    if ($exe) { Start-Process $exe $url } else { Start-Process $url }
    Write-Log 'Opened uBlock Origin Lite install page.'
})
$secExt.Controls.Add($btnUboLite)

$btnShieldsSettings = New-Object System.Windows.Forms.Button
$btnShieldsSettings.Text = 'Open Brave Shields settings'
$btnShieldsSettings.Size = New-Object System.Drawing.Size(200, 28)
$btnShieldsSettings.Location = New-Object System.Drawing.Point(245, 95)
$btnShieldsSettings.Add_Click({
    $exe = Test-BraveInstalled
    if ($exe) { Start-Process $exe 'brave://settings/shields' } else { Write-Log 'Brave not found.' 'WARN' }
})
$secExt.Controls.Add($btnShieldsSettings)

$btnBitwarden = New-Object System.Windows.Forms.Button
$btnBitwarden.Text = 'Install Bitwarden (password manager)'
$btnBitwarden.Size = New-Object System.Drawing.Size(240, 28)
$btnBitwarden.Location = New-Object System.Drawing.Point(455, 95)
$btnBitwarden.Add_Click({
    $exe = Test-BraveInstalled
    $url = 'https://chromewebstore.google.com/detail/bitwarden-password-manage/nngceckbapebfimnlniiiahkandclblb'
    if ($exe) { Start-Process $exe $url } else { Start-Process $url }
    Write-Log 'Opened Bitwarden install page.'
})
$secExt.Controls.Add($btnBitwarden)

$tabs.TabPages.Add($searchTab)

# ---- Helpers: write search-engine + startup overrides into one channel ------
function Resolve-Destination {
    param([string]$DropdownLabel, [string]$CustomUrl, [string]$SearchEngineHome)
    $code = $script:DestinationOptions[$DropdownLabel]
    switch ($code) {
        '__SKIP__'   { return $null }
        '__SEARCH__' { return $SearchEngineHome }
        '__CUSTOM__' { return $CustomUrl.Trim() }
        default      { return $code }
    }
}

function Apply-SearchEngineOverride {
    param([string]$Path)
    # Always clear first so toggling off truly removes them
    foreach ($n in @('DefaultSearchProviderEnabled','DefaultSearchProviderName','DefaultSearchProviderKeyword','DefaultSearchProviderSearchURL','DefaultSearchProviderSuggestURL')) {
        try { Remove-ItemProperty -Path $Path -Name $n -ErrorAction Stop } catch {}
    }
    if (-not $script:ChkSearchOverride.Checked) { return $false }

    $engineKey = $script:CmbSearchEngine.SelectedItem
    $eng = $script:SearchEngines[$engineKey]
    $url = $eng.URL
    $sug = $eng.Suggest
    $name = $engineKey
    $keyword = $eng.Keyword
    if ($eng.IsCustom) {
        $url = $script:TxtCustomSearchUrl.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($url)) { Write-Log 'Search override skipped: custom URL is empty.' 'WARN'; return $false }
        if ($url -notmatch '\{searchTerms\}') { Write-Log 'Search override skipped: custom URL must contain {searchTerms}.' 'WARN'; return $false }
        $name = 'Custom Search'
    }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name 'DefaultSearchProviderEnabled'   -Value 1     -PropertyType DWord  -Force | Out-Null
    New-ItemProperty -Path $Path -Name 'DefaultSearchProviderName'      -Value $name -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $Path -Name 'DefaultSearchProviderKeyword'   -Value $keyword -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $Path -Name 'DefaultSearchProviderSearchURL' -Value $url  -PropertyType String -Force | Out-Null
    if ($sug) {
        New-ItemProperty -Path $Path -Name 'DefaultSearchProviderSuggestURL' -Value $sug -PropertyType String -Force | Out-Null
    }
    Write-Log "Search engine override -> $name" 'OK'
    return $true
}

function Apply-NtpOverride {
    param([string]$Path)
    # Clear first
    try { Remove-ItemProperty -Path $Path -Name 'NewTabPageLocation' -ErrorAction Stop } catch {}
    if (-not $script:ChkNtpOverride.Checked) { return $false }

    # Resolve destination
    $engineKey = $script:CmbSearchEngine.SelectedItem
    $engineHome = if ($script:SearchEngines[$engineKey].IsCustom) { '' } else { $script:SearchEngines[$engineKey].Home }
    $url = Resolve-Destination -DropdownLabel $script:CmbNtpDest.SelectedItem -CustomUrl $script:TxtNtpCustomUrl.Text -SearchEngineHome $engineHome
    if (-not $url) { Write-Log 'NTP override skipped: no resolvable URL.' 'WARN'; return $false }
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name 'NewTabPageLocation' -Value $url -PropertyType String -Force | Out-Null
    Write-Log "New tab page override -> $url" 'OK'
    return $true
}

function Apply-StartupOverride {
    param([string]$Path)
    # Clear first
    try { Remove-ItemProperty -Path $Path -Name 'RestoreOnStartup' -ErrorAction Stop } catch {}
    try { Remove-Item -Path (Join-Path $Path 'RestoreOnStartupURLs') -Recurse -Force -ErrorAction Stop } catch {}
    if (-not $script:ChkStartupOverride.Checked) { return $false }

    $modeKey = $script:CmbStartupMode.SelectedItem
    $mode = $script:StartupModes[$modeKey]
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name 'RestoreOnStartup' -Value $mode.Code -PropertyType DWord -Force | Out-Null

    if ($mode.UsesURL) {
        $listPath = Join-Path $Path 'RestoreOnStartupURLs'
        New-Item -Path $listPath -Force | Out-Null
        $urls = if ($mode.FixedURL) { @($mode.FixedURL) }
                else { ($script:TxtStartupUrl.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        if ($urls.Count -eq 0) { Write-Log 'Startup override skipped: no URL provided.' 'WARN'; return $false }
        $i = 1
        foreach ($u in $urls) {
            New-ItemProperty -Path $listPath -Name "$i" -Value $u -PropertyType String -Force | Out-Null
            $i++
        }
        Write-Log "Startup override -> code $($mode.Code), URLs: $($urls -join ', ')" 'OK'
    } else {
        Write-Log "Startup override -> $modeKey (code $($mode.Code))" 'OK'
    }
    return $true
}

# ---- Utility buttons --------------------------------------------------------
$utilityPanel = New-Object System.Windows.Forms.Panel
$utilityPanel.Location = New-Object System.Drawing.Point(10, 676)
$utilityPanel.Size = New-Object System.Drawing.Size(1145, 40)
$utilityPanel.Anchor = 'Left, Right, Bottom'
$form.Controls.Add($utilityPanel)

# Export config to JSON
$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = 'Export config'
$btnExport.Size = New-Object System.Drawing.Size(110, 30)
$btnExport.Location = New-Object System.Drawing.Point(420, 5)
$btnExport.Add_Click({
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = 'JSON config (*.json)|*.json'
    $sfd.FileName = "brave-free-origin-config-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    $sfd.InitialDirectory = Join-Path $env:USERPROFILE 'Documents\Brave-Free-Origin-Backups'
    if (-not (Test-Path $sfd.InitialDirectory)) { New-Item -ItemType Directory -Path $sfd.InitialDirectory | Out-Null }
    if ($sfd.ShowDialog() -ne 'OK') { return }

    $cfg = [ordered]@{
        version  = '1.6'
        exported = (Get-Date -Format 's')
        channel  = $script:TargetChannels
        profile  = $script:ActiveProfile
        policies = [ordered]@{}
        tasks    = [ordered]@{}
        services = [ordered]@{}
        hosts    = [ordered]@{}
        search   = [ordered]@{
            enabled    = [bool]$script:ChkSearchOverride.Checked
            engine     = "$($script:CmbSearchEngine.SelectedItem)"
            customUrl  = "$($script:TxtCustomSearchUrl.Text)"
        }
        ntp = [ordered]@{
            enabled    = [bool]$script:ChkNtpOverride.Checked
            destination= "$($script:CmbNtpDest.SelectedItem)"
            customUrl  = "$($script:TxtNtpCustomUrl.Text)"
        }
        startup = [ordered]@{
            enabled    = [bool]$script:ChkStartupOverride.Checked
            mode       = "$($script:CmbStartupMode.SelectedItem)"
            urls       = "$($script:TxtStartupUrl.Text)"
        }
    }
    foreach ($cb in $script:CheckBoxes)        { $cfg.policies[$cb.Tag.Policy.Name] = [bool]$cb.Checked }
    foreach ($cb in $script:TaskCheckBoxes)    { $cfg.tasks[$cb.Tag.Name]            = [bool]$cb.Checked }
    foreach ($cb in $script:ServiceCheckBoxes) { $cfg.services[$cb.Tag.Name]         = [bool]$cb.Checked }
    foreach ($cb in $script:HostsCheckBoxes)   { $cfg.hosts[$cb.Tag.Name]            = [bool]$cb.Checked }

    $cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $sfd.FileName -Encoding UTF8
    Write-Log "Config exported: $($sfd.FileName)" 'OK'
})
$utilityPanel.Controls.Add($btnExport)

# Import config from JSON
$btnImport = New-Object System.Windows.Forms.Button
$btnImport.Text = 'Import config'
$btnImport.Size = New-Object System.Drawing.Size(110, 30)
$btnImport.Location = New-Object System.Drawing.Point(535, 5)
$btnImport.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = 'JSON config (*.json)|*.json'
    $ofd.InitialDirectory = Join-Path $env:USERPROFILE 'Documents\Brave-Free-Origin-Backups'
    if ($ofd.ShowDialog() -ne 'OK') { return }
    try {
        $cfg = Get-Content $ofd.FileName -Raw | ConvertFrom-Json
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Bad JSON: $_", 'Import error', 'OK', 'Error') | Out-Null
        return
    }
    $script:SuppressSelectionEvents = $true
    if ($cfg.policies) {
        foreach ($cb in $script:CheckBoxes) {
            $name = $cb.Tag.Policy.Name
            if ($cfg.policies.PSObject.Properties.Name -contains $name) { $cb.Checked = [bool]$cfg.policies.$name }
        }
    }
    if ($cfg.tasks) {
        foreach ($cb in $script:TaskCheckBoxes) {
            $name = $cb.Tag.Name
            if ($cfg.tasks.PSObject.Properties.Name -contains $name) { $cb.Checked = [bool]$cfg.tasks.$name }
        }
    }
    if ($cfg.services) {
        foreach ($cb in $script:ServiceCheckBoxes) {
            $name = $cb.Tag.Name
            if ($cfg.services.PSObject.Properties.Name -contains $name) { $cb.Checked = [bool]$cfg.services.$name }
        }
    }
    if ($cfg.hosts) {
        foreach ($cb in $script:HostsCheckBoxes) {
            $name = $cb.Tag.Name
            if ($cfg.hosts.PSObject.Properties.Name -contains $name) { $cb.Checked = [bool]$cfg.hosts.$name }
        }
    }
    if ($cfg.search) {
        $script:ChkSearchOverride.Checked = [bool]$cfg.search.enabled
        if ($cfg.search.engine -and $script:CmbSearchEngine.Items.Contains($cfg.search.engine)) {
            $script:CmbSearchEngine.SelectedItem = $cfg.search.engine
        }
        if ($cfg.search.customUrl) { $script:TxtCustomSearchUrl.Text = $cfg.search.customUrl }
    }
    if ($cfg.ntp) {
        $script:ChkNtpOverride.Checked = [bool]$cfg.ntp.enabled
        if ($cfg.ntp.destination -and $script:CmbNtpDest.Items.Contains($cfg.ntp.destination)) {
            $script:CmbNtpDest.SelectedItem = $cfg.ntp.destination
        }
        if ($cfg.ntp.customUrl) { $script:TxtNtpCustomUrl.Text = $cfg.ntp.customUrl }
    }
    if ($cfg.startup) {
        $script:ChkStartupOverride.Checked = [bool]$cfg.startup.enabled
        if ($cfg.startup.mode -and $script:CmbStartupMode.Items.Contains($cfg.startup.mode)) {
            $script:CmbStartupMode.SelectedItem = $cfg.startup.mode
        }
        if ($cfg.startup.urls) { $script:TxtStartupUrl.Text = $cfg.startup.urls }
    }
    $script:SuppressSelectionEvents = $false
    $script:ActiveProfile = if ($cfg.profile) { "$($cfg.profile)" } else { 'Custom' }
    Update-SelectionSummary
    Write-Log "Config imported from $($ofd.FileName) (version $($cfg.version))" 'OK'
    [System.Windows.Forms.MessageBox]::Show(
        "Config loaded into checkboxes.`r`nClick 'Apply to Brave' (and the Hosts tab if needed) to commit.",
        'Imported', 'OK', 'Information') | Out-Null
})
$utilityPanel.Controls.Add($btnImport)

# Verify - read registry, compare to UI selections
$btnVerify = New-Object System.Windows.Forms.Button
$btnVerify.Text = 'Verify'
$btnVerify.Size = New-Object System.Drawing.Size(80, 30)
$btnVerify.Location = New-Object System.Drawing.Point(650, 5)
$btnVerify.Add_Click({
    $report = New-Object System.Text.StringBuilder
    foreach ($channel in $script:TargetChannels) {
        $path = $script:Channels[$channel].Path
        [void]$report.AppendLine("=== $channel  ($path) ===")
        if (-not (Test-Path $path)) {
            [void]$report.AppendLine('  (no policy key exists - nothing applied)')
            [void]$report.AppendLine('')
            continue
        }
        $matchCount = 0; $missingCount = 0; $mismatchCount = 0; $tickedCount = 0
        $missingList = @(); $mismatchList = @()
        foreach ($cb in $script:CheckBoxes) {
            if (-not $cb.Checked) { continue }
            $tickedCount++
            $p = $cb.Tag.Policy
            try {
                $cur = (Get-ItemProperty -Path $path -Name $p.Name -ErrorAction Stop).$($p.Name)
                if ("$cur" -eq "$($p.ApplyValue)") { $matchCount++ }
                else { $mismatchCount++; $mismatchList += "$($p.Name): registry=$cur, expected=$($p.ApplyValue)" }
            } catch {
                $missingCount++; $missingList += $p.Name
            }
        }
        [void]$report.AppendLine("  Ticked in UI: $tickedCount")
        [void]$report.AppendLine("  Match in registry: $matchCount")
        [void]$report.AppendLine("  Missing (not in registry): $missingCount")
        [void]$report.AppendLine("  Mismatch (wrong value): $mismatchCount")
        if ($missingList) {
            [void]$report.AppendLine('  -- missing:')
            foreach ($n in $missingList) { [void]$report.AppendLine("     - $n") }
        }
        if ($mismatchList) {
            [void]$report.AppendLine('  -- mismatch:')
            foreach ($n in $mismatchList) { [void]$report.AppendLine("     - $n") }
        }
        [void]$report.AppendLine('')
    }

    # Hosts state
    $hostsCurrent = Get-HostsCurrentDomains
    [void]$report.AppendLine("=== Hosts blocklist ===")
    [void]$report.AppendLine("  Currently blocked domains: $($hostsCurrent.Count)")
    if ($hostsCurrent.Count -gt 0) {
        foreach ($d in $hostsCurrent) { [void]$report.AppendLine("     - $d") }
    }
    [void]$report.AppendLine('')

    # Search / NTP / Startup overrides
    [void]$report.AppendLine('=== Search & Startup overrides ===')
    foreach ($channel in $script:TargetChannels) {
        $path = $script:Channels[$channel].Path
        [void]$report.AppendLine("  [$channel]")
        if (-not (Test-Path $path)) { [void]$report.AppendLine('     (no policy key - nothing set)'); continue }
        try {
            $se = (Get-ItemProperty -Path $path -Name 'DefaultSearchProviderEnabled' -ErrorAction Stop).DefaultSearchProviderEnabled
            $name = (Get-ItemProperty -Path $path -Name 'DefaultSearchProviderName' -ErrorAction SilentlyContinue).DefaultSearchProviderName
            $url  = (Get-ItemProperty -Path $path -Name 'DefaultSearchProviderSearchURL' -ErrorAction SilentlyContinue).DefaultSearchProviderSearchURL
            if ($se -eq 1) { [void]$report.AppendLine("     Search engine forced: $name ($url)") }
            else           { [void]$report.AppendLine('     Search engine override: not set') }
        } catch { [void]$report.AppendLine('     Search engine override: not set') }
        try {
            $ntp = (Get-ItemProperty -Path $path -Name 'NewTabPageLocation' -ErrorAction Stop).NewTabPageLocation
            [void]$report.AppendLine("     New tab page forced: $ntp")
        } catch { [void]$report.AppendLine('     New tab page override: not set') }
        try {
            $rc = (Get-ItemProperty -Path $path -Name 'RestoreOnStartup' -ErrorAction Stop).RestoreOnStartup
            $listPath = Join-Path $path 'RestoreOnStartupURLs'
            $urls = @()
            if (Test-Path $listPath) {
                $props = Get-ItemProperty -Path $listPath
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -match '^\d+$') { $urls += $p.Value }
                }
            }
            $extra = if ($urls.Count -gt 0) { " URLs: $($urls -join ', ')" } else { '' }
            [void]$report.AppendLine("     Startup forced: code $rc$extra")
        } catch { [void]$report.AppendLine('     Startup override: not set') }
    }

    # Show in a scrollable dialog
    $vf = New-Object System.Windows.Forms.Form
    $vf.Text = 'Verify - registry vs selections'
    $vf.Size = New-Object System.Drawing.Size(700, 520)
    $vf.StartPosition = 'CenterParent'
    $vt = New-Object System.Windows.Forms.TextBox
    $vt.Multiline = $true
    $vt.ReadOnly = $true
    $vt.ScrollBars = 'Vertical'
    $vt.Font = New-Object System.Drawing.Font('Consolas', 9)
    $vt.Dock = 'Fill'
    $vt.Text = $report.ToString()
    $vf.Controls.Add($vt)
    [void]$vf.ShowDialog()
})
$utilityPanel.Controls.Add($btnVerify)

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = 'Load current state'
$btnLoad.Size = New-Object System.Drawing.Size(145, 30)
$btnLoad.Location = New-Object System.Drawing.Point(0, 5)
$btnLoad.Add_Click({
    $script:SuppressSelectionEvents = $true
    # Read from the FIRST target channel (loading is single-source by design)
    $loadPath = $script:Channels[$script:TargetChannels[0]].Path
    $originalPath = $script:BravePolicyPath
    $script:BravePolicyPath = $loadPath
    foreach ($cb in $script:CheckBoxes) {
        $p = $cb.Tag.Policy
        $cur = Get-ExistingPolicy $p.Name
        $cb.Checked = ($null -ne $cur -and "$cur" -eq "$($p.ApplyValue)")
    }
    $script:BravePolicyPath = $originalPath
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
    # Hosts state
    if ($script:HostsCheckBoxes) {
        $current = Get-HostsCurrentDomains
        foreach ($cb in $script:HostsCheckBoxes) {
            $blockDomains = $cb.Tag.Domains
            $allPresent = $true
            foreach ($d in $blockDomains) { if ($current -notcontains $d) { $allPresent = $false; break } }
            $cb.Checked = $allPresent
        }
    }
    # Search engine override state
    if ($script:ChkSearchOverride) {
        $sePath = $loadPath
        $seEnabled = $false
        try {
            $val = (Get-ItemProperty -Path $sePath -Name 'DefaultSearchProviderEnabled' -ErrorAction Stop).DefaultSearchProviderEnabled
            $seEnabled = ($val -eq 1)
        } catch { $seEnabled = $false }
        $script:ChkSearchOverride.Checked = $seEnabled
        if ($seEnabled) {
            try {
                $url = (Get-ItemProperty -Path $sePath -Name 'DefaultSearchProviderSearchURL' -ErrorAction Stop).DefaultSearchProviderSearchURL
                $matched = $false
                foreach ($key in $script:SearchEngines.Keys) {
                    if (-not $script:SearchEngines[$key].IsCustom -and $script:SearchEngines[$key].URL -eq $url) {
                        $script:CmbSearchEngine.SelectedItem = $key
                        $matched = $true; break
                    }
                }
                if (-not $matched) {
                    $script:CmbSearchEngine.SelectedItem = 'Custom...'
                    $script:TxtCustomSearchUrl.Text = $url
                }
            } catch {}
        }
    }
    # NTP override state
    if ($script:ChkNtpOverride) {
        try {
            $ntpUrl = (Get-ItemProperty -Path $loadPath -Name 'NewTabPageLocation' -ErrorAction Stop).NewTabPageLocation
            $script:ChkNtpOverride.Checked = $true
            $matched = $false
            foreach ($k in $script:DestinationOptions.Keys) {
                if ($script:DestinationOptions[$k] -eq $ntpUrl) {
                    $script:CmbNtpDest.SelectedItem = $k; $matched = $true; break
                }
            }
            if (-not $matched) {
                $script:CmbNtpDest.SelectedItem = 'Custom URL...'
                $script:TxtNtpCustomUrl.Text = $ntpUrl
            }
        } catch { $script:ChkNtpOverride.Checked = $false }
    }
    # Startup override state
    if ($script:ChkStartupOverride) {
        try {
            $code = (Get-ItemProperty -Path $loadPath -Name 'RestoreOnStartup' -ErrorAction Stop).RestoreOnStartup
            $script:ChkStartupOverride.Checked = $true
            foreach ($k in $script:StartupModes.Keys) {
                if ($script:StartupModes[$k].Code -eq $code) { $script:CmbStartupMode.SelectedItem = $k; break }
            }
            $listPath = Join-Path $loadPath 'RestoreOnStartupURLs'
            if (Test-Path $listPath) {
                $props = Get-ItemProperty -Path $listPath
                $urls = @()
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -match '^\d+$') { $urls += $p.Value }
                }
                if ($urls.Count -gt 0) { $script:TxtStartupUrl.Text = ($urls -join ', ') }
            }
        } catch { $script:ChkStartupOverride.Checked = $false }
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
$flowLabel.Text = 'Pick mode -> tweak -> Apply -> restart Brave -> Verify'
$flowLabel.Location = New-Object System.Drawing.Point(740, 11)
$flowLabel.Size = New-Object System.Drawing.Size(400, 18)
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
    $originalPath = $script:BravePolicyPath
    foreach ($channel in $script:TargetChannels) {
        $script:BravePolicyPath = $script:Channels[$channel].Path
        Write-Log "--- Applying to channel: $channel ($($script:BravePolicyPath)) ---"
        foreach ($cb in $script:CheckBoxes) {
            $p = $cb.Tag.Policy
            if ($cb.Checked) {
                try {
                    Set-PolicyValue -Name $p.Name -Type $p.Type -Value $p.ApplyValue
                    Write-Log "[$channel] SET $($p.Name) = $($p.ApplyValue)" 'OK'
                    $applied++
                } catch {
                    Write-Log "[$channel] FAIL $($p.Name): $_" 'ERR'
                }
            } else {
                if (Remove-PolicyValue -Name $p.Name) {
                    Write-Log "[$channel] CLEARED $($p.Name)" 'OK'
                    $cleared++
                }
            }
        }

        # Search/NTP/Startup overrides run LAST so they always win over any
        # NewTabPageLocation/HomepageLocation/RestoreOnStartup ticks above.
        # Each helper clears its own keys first, so unticking + Apply truly removes them.
        if ($script:BravePolicyPath -and (Test-Path $script:BravePolicyPath)) {
            try { [void](Apply-SearchEngineOverride -Path $script:BravePolicyPath) } catch { Write-Log "[$channel] Search override: $_" 'ERR' }
            try { [void](Apply-NtpOverride          -Path $script:BravePolicyPath) } catch { Write-Log "[$channel] NTP override: $_" 'ERR' }
            try { [void](Apply-StartupOverride      -Path $script:BravePolicyPath) } catch { Write-Log "[$channel] Startup override: $_" 'ERR' }
        } elseif ($script:ChkSearchOverride.Checked -or $script:ChkNtpOverride.Checked -or $script:ChkStartupOverride.Checked) {
            # No policy key yet but overrides are requested - create the key and run them
            New-Item -Path $script:BravePolicyPath -Force | Out-Null
            try { [void](Apply-SearchEngineOverride -Path $script:BravePolicyPath) } catch { Write-Log "[$channel] Search override: $_" 'ERR' }
            try { [void](Apply-NtpOverride          -Path $script:BravePolicyPath) } catch { Write-Log "[$channel] NTP override: $_" 'ERR' }
            try { [void](Apply-StartupOverride      -Path $script:BravePolicyPath) } catch { Write-Log "[$channel] Startup override: $_" 'ERR' }
        }
    }
    $script:BravePolicyPath = $originalPath

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
    $targets = $script:TargetChannels -join ', '
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "This will delete the policy keys for: $targets`r`nBrave returns to stock behaviour for those channel(s). Continue?",
        'Confirm',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($ans -ne 'Yes') { return }
    if ($chkBackup.Checked) { [void](Export-Backup) }
    foreach ($channel in $script:TargetChannels) {
        $path = $script:Channels[$channel].Path
        try {
            if (Test-Path $path) {
                Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
                Write-Log "Removed policy key for $channel ($path)" 'OK'
            } else {
                Write-Log "$channel had no policy key - skipped." 'INFO'
            }
        } catch {
            Write-Log "Remove-Item [$channel]: $_" 'ERR'
        }
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
