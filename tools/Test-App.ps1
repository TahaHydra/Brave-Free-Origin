# ============================================================================
#  Brave Free Origin - self-test suite.
#
#  This script does not run on its own. The app dot-sources it inside its own
#  session when started with -SelfTest, in SANDBOX mode: policies go to a test
#  hive under HKCU, the hosts file is a temp file, scheduled tasks and services
#  are in-memory fakes, no UAC prompt is raised and no window is shown to the
#  user. Nothing about a real Brave install is read for writing.
#
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Brave-Free-Origin.ps1 `
#        -SelfTest .\tools\Test-App.ps1
#
#  Optional environment variables:
#    BFO_TEST_OUT     folder for the report and screenshots (default: %TEMP%\bfo-selftest)
#    BFO_TEST_SHOTS   1 = save a PNG of every page in every language
#
#  Exit code 0 = all tests passed, 1 = at least one failed.
# ============================================================================
$ErrorActionPreference = 'Continue'

$script:TestOut = if ($env:BFO_TEST_OUT) { $env:BFO_TEST_OUT } else { Join-Path ([System.IO.Path]::GetTempPath()) 'bfo-selftest' }
New-Item -ItemType Directory -Path $script:TestOut -Force | Out-Null
$script:Results = New-Object System.Collections.ArrayList
$script:WantShots = ($env:BFO_TEST_SHOTS -eq '1')
$sandboxRoot = 'HKCU:\Software\Brave-Free-Origin-SelfTest'

# ---- tiny framework ---------------------------------------------------------------
function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $failure = $null
    try { [void](& $Body) }
    catch {
        $where = (@("$($_.ScriptStackTrace)" -split "`n" | Select-Object -First 3) -join ' <- ') -replace 'at <ScriptBlock>, ', ''
        $failure = "$($_.Exception.Message)  [line $($_.InvocationInfo.ScriptLineNumber)] $where"
    }
    [void]$script:Results.Add([pscustomobject]@{ Name = $Name; Passed = ($null -eq $failure); Error = $failure; Ms = $sw.ElapsedMilliseconds })
    $mark = if ($null -eq $failure) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1}{2}" -f $mark, $Name, $(if ($failure) { "`n        $failure" } else { '' }))
}

function Test-Subset {
    param($Small, $Big)
    return (@($Small | Where-Object { $Big -notcontains $_ }).Count -eq 0)
}

function Reset-Sandbox {
    if (Test-Path -LiteralPath $sandboxRoot) { Remove-Item -LiteralPath $sandboxRoot -Recurse -Force }
    if (Test-Path -LiteralPath $script:HostsFile) { Remove-Item -LiteralPath $script:HostsFile -Force }
    $script:Snapshot = $null
    $script:FakeTasks = @(); $script:FakeServices = @(); $script:TaskCache = $null
    $script:HostsCurrent = @()
    foreach ($i in $script:Items) { Set-ItemChecked $i $false; $i.Loaded = $false; $i.Baseline = $null; $i.Detail = $null }
    $script:Overrides.Search  = @{ Enabled = $false; EngineId = 'brave'; CustomUrl = '' }
    $script:Overrides.Ntp     = @{ Enabled = $false; DestinationId = 'blank'; CustomUrl = '' }
    $script:Overrides.Startup = @{ Enabled = $false; ModeId = 'newTab'; Urls = '' }
    $script:ActiveProfile = 'Custom'
    $script:SelfTestDialogs = @(); $script:SelfTestReports = @()
    $script:SelfTestAnswers.Clear()
    $script:AppliedLedger = @{}; $script:AppliedUrls = @(); $script:ExistingMode = 'ask'
    $script:SelfTestExistingAnswers.Clear(); $script:SelfTestExistingDialogs = @()
}

function Get-Ticked { return @($script:Items | Where-Object { $_.Kind -eq 'Policy' -and $_.Checked } | ForEach-Object { $_.Id }) }

function Invoke-ApplyNow {
    $plan = New-ApplyPlan
    $result = Invoke-ApplyPlan $plan
    $script:Snapshot = Read-PolicySnapshot -Path $script:PolicyKeyPath
    return $result
}

function Find-MissingText {
    param($Control, [System.Collections.ArrayList]$Found)
    if ($Control.Text -and $Control.Text -match '!!') { [void]$Found.Add("$($Control.GetType().Name): $($Control.Text)") }
    foreach ($k in $Control.Controls) { Find-MissingText $k $Found }
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
Write-Host "Brave Free Origin self-test - v$($script:AppVersion), sandbox mode, PowerShell $($PSVersionTable.PSVersion)"

# =============================================================== 1. catalog integrity
Test-Case 'catalog: every policy has a title and a description in English' {
    foreach ($def in $script:PolicyByName.Values) {
        foreach ($part in 'title', 'description') {
            Assert ($script:EnglishStrings.ContainsKey("policy.$($def.Name).$part")) "missing policy.$($def.Name).$part"
        }
    }
}
Test-Case 'catalog: policy names are unique, types are valid, DWORD values are integers' {
    $names = @($script:PolicyTable | Where-Object { $_ -notmatch '^\s*(#|$)' } | ForEach-Object { $_.Split('|')[1] })
    Assert ($names.Count -eq @($names | Select-Object -Unique).Count) 'duplicate policy name in the table'
    foreach ($def in $script:PolicyByName.Values) {
        Assert ($def.Type -in 'DWORD', 'STRING') "$($def.Name): bad type $($def.Type)"
        if ($def.Type -eq 'DWORD') { Assert ($def.Value -is [int]) "$($def.Name): DWORD value is not an int" }
        else { Assert (-not [string]::IsNullOrWhiteSpace($def.Value)) "$($def.Name): empty string value" }
        Assert ($def.Kind -in 'Off', 'On', 'Set') "$($def.Name): bad kind $($def.Kind)"
        Assert ($def.Risk -in 'safe', 'low', 'medium', 'high') "$($def.Name): bad risk $($def.Risk)"
        Assert ($def.Presets -match '^([QORBXP]+|-)$') "$($def.Name): bad preset codes $($def.Presets)"
        Assert ($script:PolicyPageOrder -contains $def.Page) "$($def.Name): unknown page $($def.Page)"
    }
}
Test-Case 'catalog: no policy that Brave 154 no longer knows is offered' {
    $dead = 'WebTorrentDisabled', 'ChromeCleanupEnabled', 'ChromeCleanupReportingEnabled', 'TabOrganizerSettings', 'CloudPrintSubmitEnabled',
            'WelcomePageOnOSUpgradeEnabled', 'ReadingListEnabled', 'MediaRouterEnabled', 'IPFSEnabled', 'SigninAllowed', 'GenAiDefaultSettings',
            'PromotionalTabsEnabled', 'LensDesktopNTPSearchEnabled', 'LensRegionSearchEnabled', 'LensOverlaySettings'
    foreach ($d in $dead) { Assert (-not $script:PolicyByName.ContainsKey($d)) "$d must not be in the catalog" }
    Assert ($script:PolicyByName.ContainsKey('EnableMediaRouter')) 'EnableMediaRouter (the real Cast policy) is missing'
    Assert ($script:PolicyByName['BatterySaverModeAvailability'].Value -eq 1) 'BatterySaverModeAvailability must be 1 (2 is deprecated)'
}
Test-Case 'catalog: every policy the app writes is known to the Brave it was checked against (snapshot of its policy table)' {
    $snapshot = Join-Path (Split-Path -Parent $SelfTest) 'data\brave-policy-names.txt'
    Assert (Test-Path -LiteralPath $snapshot) 'tools\data\brave-policy-names.txt is missing; run tools\Export-BravePolicyNames.ps1'
    $known = @(Get-Content -LiteralPath $snapshot -Encoding UTF8 | Where-Object { $_ -and -not $_.StartsWith('#') })
    Assert ($known.Count -gt 300) "the snapshot only lists $($known.Count) names"
    $offered = @($script:PolicyByName.Keys) + @($script:OverridePolicyNames) + @('RestoreOnStartupURLs')
    $missing = @($offered | Where-Object { $known -notcontains $_ } | Select-Object -Unique)
    Assert ($missing.Count -eq 0) ("Brave $($script:CatalogBrave) does not know: " + ($missing -join ', ') + ' (a policy Brave does not know is silently ignored)')
    Assert ($script:CatalogBrave -and ((Get-Content -LiteralPath $snapshot -TotalCount 1) -match [regex]::Escape($script:CatalogBrave))) 'the snapshot was made from a different Brave than CatalogBrave says'
}
Test-Case 'catalog: pages, presets, risks, states and hosts groups all have strings' {
    foreach ($id in $script:PageOrder.Id) { foreach ($p in 'title', 'intro') { Assert ($script:EnglishStrings.ContainsKey("page.$id.$p")) "page.$id.$p" } }
    foreach ($k in $script:AllPresetKeys) { foreach ($p in 'name', 'description', 'risk') { Assert ($script:EnglishStrings.ContainsKey("preset.$k.$p")) "preset.$k.$p" } }
    foreach ($r in 'safe', 'low', 'medium', 'high') { Assert ($script:EnglishStrings.ContainsKey("risk.$r")) "risk.$r" }
    foreach ($s in 'active', 'willApply', 'willChange', 'willReplace', 'foreign', 'willRemove', 'notSet', 'enabled', 'disabled', 'willDisable', 'willEnable', 'missing', 'unknown', 'blocked', 'willBlock', 'willUnblock', 'notBlocked') {
        Assert ($script:EnglishStrings.ContainsKey("state.$s")) "state.$s"
    }
    foreach ($h in $script:HostsBlocks) { foreach ($p in 'name', 'description') { Assert ($script:EnglishStrings.ContainsKey("hosts.$($h.Id).$p")) "hosts.$($h.Id).$p" } }
    foreach ($t in $script:UpdaterTaskDefs)    { foreach ($p in 'title', 'description') { Assert ($script:EnglishStrings.ContainsKey("task.$($t.Id).$p")) "task.$($t.Id).$p" } }
    foreach ($s in $script:UpdaterServiceDefs) { foreach ($p in 'title', 'description') { Assert ($script:EnglishStrings.ContainsKey("service.$($s.Id).$p")) "service.$($s.Id).$p" } }
    foreach ($d in $script:PolicyByName.Values) { if ($d.Choices) { foreach ($c in $d.Choices.Keys) { Assert ($script:EnglishStrings.ContainsKey("policy.$($d.Name).choice.$c")) "choice $c of $($d.Name)" } } }
    foreach ($k in $script:PolicyByName.Values | Where-Object { $_.Kind -in 'Off', 'On', 'Set' } | ForEach-Object { $_.Kind } | Select-Object -Unique) { Assert ($script:EnglishStrings.ContainsKey("tip.ticked.$k")) "tip.ticked.$k" }
}
Test-Case 'catalog: hosts domains are well formed, unique, and no preset pre-ticks the dangerous groups' {
    $all = @()
    foreach ($h in $script:HostsBlocks) {
        foreach ($d in $h.Domains) { Assert ($d -match '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$') "bad domain $d"; $all += $d }
    }
    Assert ($all.Count -eq @($all | Select-Object -Unique).Count) 'a domain appears in two groups'
    foreach ($k in $script:PresetHosts.Keys) {
        Assert ($script:PresetHosts[$k] -notcontains 'components') "preset $k pre-ticks the components hosts group"
    }
    Assert ($script:HostsBlocks.Where({ $_.Id -eq 'variations' }).Domains -notcontains 'go-updater.brave.com') 'go-updater.brave.com is Brave''s component update server'
    Assert ($script:HostsBlocks.Where({ $_.Id -eq 'components' }).Domains -contains 'go-updater.brave.com') 'go-updater.brave.com belongs to the components group'
}

# =============================================================== 2. preset logic
$sel = @{}
foreach ($k in $script:PresetKeys) { $sel[$k] = @((Get-PresetSelection -Preset $k).Policies) }
Test-Case 'presets: Origin Mode is exactly the 16 policies Brave Origin switches off' {
    $origin = 'TorDisabled', 'BraveStatsPingEnabled', 'BraveP3AEnabled', 'BraveLocalAIEnabled', 'BraveRewardsDisabled', 'BraveWalletDisabled', 'BraveAIChatEnabled',
              'BraveNewsDisabled', 'BraveVPNDisabled', 'BraveTalkDisabled', 'BraveSpeedreaderEnabled', 'BravePlaylistEnabled', 'BraveWaybackMachineEnabled',
              'BraveWebDiscoveryEnabled', 'EmailAliasesEnabled', 'PsstEnabled'
    Assert (($sel.Origin.Count -eq 16) -and (Test-Subset $origin $sel.Origin)) "Origin has $($sel.Origin.Count) policies"
}
Test-Case 'presets: the ladder is coherent (Quick < Recommended < Boost < Max Performance; Recommended < Max Privacy)' {
    Assert (Test-Subset $sel.Minimal $sel.Recommended) 'Quick Debloat must be inside Recommended'
    Assert (Test-Subset $sel.Minimal $sel.Origin) 'Quick Debloat must be inside Origin Mode'
    Assert (Test-Subset $sel.Recommended $sel.Performance) 'Recommended must be inside Privacy + Boost'
    Assert (Test-Subset $sel.Origin $sel.Performance) 'Origin Mode must be inside Privacy + Boost'
    Assert (Test-Subset $sel.Performance $sel.MaxPerformance) 'Privacy + Boost must be inside Max Performance'
    Assert (Test-Subset $sel.Recommended $sel.MaxPrivacy) 'Recommended must be inside Max Privacy'
    Assert ($sel.Minimal.Count -eq 6) "Quick Debloat should be the six commercial extras, got $($sel.Minimal.Count)"
    Assert ($sel.None.Count -eq 0) 'Stock / None must select nothing'
}
Test-Case 'presets: safe presets never take away everyday features' {
    $everyday = 'PasswordManagerEnabled', 'AutofillAddressEnabled', 'AutofillCreditCardEnabled', 'SyncDisabled', 'BrowserSignin', 'RestoreOnStartup',
                'TranslateEnabled', 'SearchSuggestEnabled', 'ImportSavedPasswords', 'ImportBookmarks', 'DefaultBraveRemember1PStorageSetting',
                'DefaultBraveHttpsUpgradeSetting', 'ComponentUpdatesEnabled', 'SpellcheckEnabled', 'NTPCustomBackgroundEnabled', 'DnsOverHttpsMode'
    foreach ($k in 'Minimal', 'Recommended', 'Origin', 'Performance') {
        foreach ($p in $everyday) { Assert ($sel[$k] -notcontains $p) "preset $k must not include $p" }
    }
    Assert ($sel.MaxPerformance -notcontains 'PasswordManagerEnabled') 'Max Performance must not disable the password manager'
    Assert ($sel.MaxPerformance -notcontains 'DefaultBraveRemember1PStorageSetting') 'Max Performance must not sign you out of every site'
    foreach ($k in $script:PresetKeys) { Assert ($sel[$k] -notcontains 'ComponentUpdatesEnabled') "preset $k must never stop component updates" }
}
Test-Case 'presets: applying a preset ticks exactly its policies and never touches updater tasks or overrides' {
    Reset-Sandbox
    foreach ($k in $script:PresetKeys) {
        Set-PresetChecks -Preset $k
        $ticked = @(Get-Ticked)
        Assert (($ticked.Count -eq $sel[$k].Count) -and (Test-Subset $ticked $sel[$k])) "preset $k ticked $($ticked.Count), expected $($sel[$k].Count)"
        Assert (@($script:Items | Where-Object { ($_.Kind -in 'Task', 'Service') -and $_.Checked }).Count -eq 0) "preset $k ticked an updater item"
        Assert (-not ($script:Overrides.Search.Enabled -or $script:Overrides.Ntp.Enabled -or $script:Overrides.Startup.Enabled)) "preset $k touched an override"
    }
}

# =============================================================== 3. registry pipeline (HKCU sandbox)
Test-Case 'registry: applying Recommended writes exactly the ticked policies, with the right types' {
    Reset-Sandbox
    Set-PresetChecks -Preset Recommended
    $r = Invoke-ApplyNow
    Assert ($r.Failures.Count -eq 0) "failures: $($r.Failures -join '; ')"
    $snap = Read-PolicySnapshot -Path $script:PolicyKeyPath
    $ticked = Get-Ticked
    Assert ($snap.Values.Count -eq $ticked.Count) "registry has $($snap.Values.Count) values, expected $($ticked.Count)"
    foreach ($id in $ticked) {
        $def = $script:PolicyByName[$id]
        Assert ("$($snap.Values[$id])" -eq "$($def.Value)") "$id = $($snap.Values[$id]), expected $($def.Value)"
        $kind = if ($def.Type -eq 'DWORD') { 'DWord' } else { 'String' }
        Assert ($snap.Kinds[$id] -eq $kind) "$id has registry type $($snap.Kinds[$id]), expected $kind"
    }
}
Test-Case 'registry: applying twice changes nothing the second time (idempotent)' {
    $plan = New-ApplyPlan
    Assert (-not (Test-PlanHasChanges $plan)) "second plan still wants $($plan.Counts.Add) add, $($plan.Counts.Change) change, $($plan.Counts.Clear) clear"
}
Test-Case 'registry: switching to a smaller preset clears exactly the extra policies' {
    Set-PresetChecks -Preset Minimal
    $plan = New-ApplyPlan
    $clears = @($plan.Registry | Where-Object { $_.Action -eq 'Clear' })
    Assert ($clears.Count -eq ($sel.Recommended.Count - $sel.Minimal.Count)) "clears $($clears.Count)"
    [void](Invoke-ApplyNow)
    $snap = Read-PolicySnapshot -Path $script:PolicyKeyPath
    Assert ($snap.Values.Count -eq 6) "registry has $($snap.Values.Count) values after Quick Debloat"
}
Test-Case 'registry: values with a different data or type than ours show up as Change, and Load state ticks only exact matches' {
    Reset-Sandbox
    New-Item -Path $script:PolicyKeyPath -Force | Out-Null
    New-ItemProperty -LiteralPath $script:PolicyKeyPath -Name 'BraveRewardsDisabled' -Value 0 -PropertyType DWord | Out-Null   # wrong value
    New-ItemProperty -LiteralPath $script:PolicyKeyPath -Name 'BraveWalletDisabled' -Value '1' -PropertyType String | Out-Null # right value, wrong type
    New-ItemProperty -LiteralPath $script:PolicyKeyPath -Name 'BraveVPNDisabled' -Value 1 -PropertyType DWord | Out-Null      # exact
    Invoke-LoadCurrentState
    $ticked = Get-Ticked
    Assert ($ticked -contains 'BraveVPNDisabled') 'the exact match must be ticked'
    Assert ($ticked -notcontains 'BraveRewardsDisabled') 'a different value must not be ticked'
    Set-ItemChecked (Get-BfoItem 'Policy' 'BraveWalletDisabled') $true
    $plan = New-ApplyPlan
    $op = $plan.Registry | Where-Object { $_.Name -eq 'BraveWalletDisabled' }
    Assert ($op.Action -eq 'Change') "wrong-type value should be a Change, got $($op.Action)"
}
Test-Case 'registry: Verify reports foreign policies and Restore keeps them unless asked' {
    Reset-Sandbox
    Set-PresetChecks -Preset Minimal
    [void](Invoke-ApplyNow)
    New-ItemProperty -LiteralPath $script:PolicyKeyPath -Name 'SomeCompanyPolicy' -Value 1 -PropertyType DWord | Out-Null
    New-Item -Path (Join-Path $script:PolicyKeyPath 'ExtensionInstallForcelist') -Force | Out-Null
    $foreign = Get-ForeignPolicyValues
    Assert ($foreign.Values -contains 'SomeCompanyPolicy') 'foreign value not detected'
    Assert ($foreign.SubKeys -contains 'ExtensionInstallForcelist') 'foreign sub-key not detected'
    Assert ((New-VerifyReport) -match 'SomeCompanyPolicy') 'verify report does not list the foreign policy'
    $fail = @(Invoke-FullRestore -RemoveForeign $false)
    Assert ($fail.Count -eq 0) "restore failures: $($fail -join '; ')"
    $snap = Read-PolicySnapshot -Path $script:PolicyKeyPath
    Assert ($snap.Exists -and $snap.Values.ContainsKey('SomeCompanyPolicy')) 'the foreign policy was deleted'
    Assert (-not $snap.Values.ContainsKey('BraveRewardsDisabled')) 'our own policy survived the restore'
    [void](Invoke-FullRestore -RemoveForeign $true)
    Assert (-not (Test-Path -LiteralPath $script:PolicyKeyPath)) 'the key should be gone after a full removal'
}
Test-Case 'registry: values older versions wrote for policies Brave no longer has are cleared by Apply and Restore and are not called foreign' {
    Reset-Sandbox
    New-Item -Path $script:PolicyKeyPath -Force | Out-Null
    $leftovers = 'WebTorrentDisabled', 'SigninAllowed', 'MediaRouterEnabled', 'LensOverlaySettings'
    foreach ($n in $leftovers) { New-ItemProperty -LiteralPath $script:PolicyKeyPath -Name $n -Value 1 -PropertyType DWord | Out-Null }
    New-ItemProperty -LiteralPath $script:PolicyKeyPath -Name 'SomeCompanyPolicy' -Value 1 -PropertyType DWord | Out-Null
    $foreign = Get-ForeignPolicyValues
    foreach ($n in $leftovers) { Assert ($foreign.Values -notcontains $n) "$n (ours, from an older version) was reported as foreign" }
    Assert ($foreign.Values -contains 'SomeCompanyPolicy') 'a genuinely foreign value was not reported'
    $ops = @(Get-RegistryOps -Desired (Get-DesiredPolicyMap) -Snapshot (Read-PolicySnapshot -Path $script:PolicyKeyPath))
    foreach ($n in $leftovers) { Assert (@($ops | Where-Object { $_.Action -eq 'Clear' -and $_.Name -eq $n }).Count -eq 1) "Apply would not clear $n" }
    Assert ((New-VerifyReport) -match 'Leftovers from older versions of this tool: 4') 'the Verify report does not mention the leftovers'
    Assert ((New-ApplyPlanReport (New-ApplyPlan)) -match 'CLEAR\s+SigninAllowed .*leftover from an older version') 'the Preview report does not explain the leftover'
    $fail = @(Invoke-FullRestore -RemoveForeign $false)
    Assert ($fail.Count -eq 0) "restore failures: $($fail -join '; ')"
    $left = @((Read-PolicySnapshot -Path $script:PolicyKeyPath).Values.Keys)
    Assert ($left -contains 'SomeCompanyPolicy') 'restore removed the foreign value'
    foreach ($n in $leftovers) { Assert ($left -notcontains $n) "$n was left behind by restore" }
}
Test-Case 'registry: a known policy that someone else set to a different value is left alone by Apply and Restore, and shows as Set elsewhere' {
    Reset-Sandbox
    New-Item -Path $script:PolicyKeyPath -Force | Out-Null
    New-ItemProperty -LiteralPath $script:PolicyKeyPath -Name 'BrowserSignin' -Value 1 -PropertyType DWord | Out-Null                    # the catalog writes 0
    New-ItemProperty -LiteralPath $script:PolicyKeyPath -Name 'HardwareAccelerationModeEnabled' -Value 7 -PropertyType DWord | Out-Null   # not one of our two choices
    New-ItemProperty -LiteralPath $script:PolicyKeyPath -Name 'BraveWalletDisabled' -Value 1 -PropertyType DWord | Out-Null              # identical to ours: treated as ours
    Invoke-LoadCurrentState
    Assert ((Get-ItemState (Get-BfoItem 'Policy' 'BrowserSignin')) -eq 'foreign') 'a different value should show as Set elsewhere'
    Assert ((Get-ItemState (Get-BfoItem 'Policy' 'HardwareAccelerationModeEnabled')) -eq 'foreign') 'a value outside our choices should show as Set elsewhere'
    Assert ((Get-ItemState (Get-BfoItem 'Policy' 'BraveWalletDisabled')) -eq 'active') 'an identical value is ours and shows as Active'
    $plan = New-ApplyPlan
    Assert (($plan.Counts.Leave -eq 2) -and ($plan.Counts.Clear -eq 0)) "expected 2 Leave and 0 Clear, got $($plan.Counts.Leave) / $($plan.Counts.Clear)"
    Assert (-not (Test-PlanHasChanges $plan)) 'leaving other people''s values alone must not count as a pending change'
    Assert ((New-ApplyPlanReport $plan) -match 'LEAVE\s+BrowserSignin') 'Preview does not say the value is left alone'
    [void](Invoke-ApplyNow)
    $snap = Read-PolicySnapshot -Path $script:PolicyKeyPath
    Assert (($snap.Values['BrowserSignin'] -eq 1) -and ($snap.Values['HardwareAccelerationModeEnabled'] -eq 7)) 'Apply removed a value that was not ours'
    $foreign = Get-ForeignPolicyValues
    Assert (($foreign.Values -contains 'BrowserSignin') -and ($foreign.Values -contains 'HardwareAccelerationModeEnabled') -and ($foreign.Values -notcontains 'BraveWalletDisabled')) 'the foreign list is wrong'
    Assert ((New-VerifyReport) -match 'BrowserSignin') 'Verify does not list the value it leaves alone'
    $fail = @(Invoke-FullRestore -RemoveForeign $false)
    Assert ($fail.Count -eq 0) "restore failures: $($fail -join '; ')"
    $snap = Read-PolicySnapshot -Path $script:PolicyKeyPath
    Assert ($snap.Values.ContainsKey('BrowserSignin') -and $snap.Values.ContainsKey('HardwareAccelerationModeEnabled')) 'Restore removed a value that was not ours'
    Assert (-not $snap.Values.ContainsKey('BraveWalletDisabled')) 'Restore left our own value behind'
    # ticking the row is an explicit request to replace it
    Set-ItemChecked (Get-BfoItem 'Policy' 'BrowserSignin') $true
    Assert ((Get-ItemState (Get-BfoItem 'Policy' 'BrowserSignin')) -eq 'willReplace') 'ticking should offer to replace the other value (after asking)'
    [void](Invoke-ApplyNow)
    Assert ((Read-PolicySnapshot -Path $script:PolicyKeyPath).Values['BrowserSignin'] -eq 0) 'the ticked row was not applied'
    # a value an older version wrote still counts as ours
    New-ItemProperty -LiteralPath $script:PolicyKeyPath -Name 'BatterySaverModeAvailability' -Value 2 -PropertyType DWord -Force | Out-Null
    $script:Snapshot = Read-PolicySnapshot -Path $script:PolicyKeyPath
    Assert ((Get-ItemState (Get-BfoItem 'Policy' 'BatterySaverModeAvailability')) -eq 'willRemove') 'the v1.12 Battery Saver value should count as ours'
}
Test-Case 'config: importing never re-enables an updater the user disabled, and export lists only ticked updater rows' {
    Reset-Sandbox
    $uaName = 'BraveSoftwareUpdateTaskUserS-1-12-1-1-2-3-4UA{22222222-2222-2222-2222-222222222222}'
    $script:FakeTasks = @([pscustomobject]@{ Name = $uaName; State = 'Disabled'; Task = $null })
    # a config (also what older versions exported) that lists every updater row as false = "not ticked"
    $old = '{ "schemaVersion": 3, "policies": { "BraveRewardsDisabled": true }, "tasks": { "core": false, "ua": false }, "services": { "brave": false, "bravem": false } }'
    [void](Import-ConfigObject ($old | ConvertFrom-Json))
    Assert (@(Get-SystemOps -Refresh).Count -eq 0) 'importing updater rows set to false must not produce an ENABLE operation'
    # the same after the user has looked at the Updater page (so the disabled task is the baseline)
    Import-CurrentSystemState -Refresh
    [void](Import-ConfigObject ($old | ConvertFrom-Json))
    Assert (@(Get-SystemOps).Count -eq 0) 'importing false changed an updater that was already disabled'
    Assert ((Get-BfoItem 'Task' 'ua').Checked) 'the ua task is disabled on this PC and must stay ticked'
    # a ticked row is exported, unticked ones are not, and importing a ticked row disables the task
    Reset-Sandbox
    Set-ItemChecked (Get-BfoItem 'Task' 'ua') $true
    $cfg = New-ConfigObject
    Assert ($cfg.tasks.Contains('ua') -and -not $cfg.tasks.Contains('core')) 'export should list only the ticked updater rows'
    Assert ($cfg.services.Count -eq 0) 'no service was ticked, so none should be exported'
    Reset-Sandbox
    $script:FakeTasks = @([pscustomobject]@{ Name = $uaName; State = 'Ready'; Task = $null })
    [void](Import-ConfigObject (($cfg | ConvertTo-Json -Depth 5) | ConvertFrom-Json))
    $ops = @(Get-SystemOps -Refresh)
    Assert (($ops.Count -eq 1) -and ($ops[0].Action -eq 'Disable')) 'a ticked updater row in a config should still disable the task'
}
Test-Case 'registry: restore also removes the legacy per-channel keys older versions wrote' {
    Reset-Sandbox
    foreach ($k in $script:LegacyPolicyKeys) {
        $p = Get-PolicyHivePath $k
        New-Item -Path $p -Force | Out-Null
        New-ItemProperty -LiteralPath $p -Name 'BraveRewardsDisabled' -Value 1 -PropertyType DWord | Out-Null
    }
    [void](Invoke-FullRestore -RemoveForeign $false)
    foreach ($k in $script:LegacyPolicyKeys) { Assert (-not (Test-Path -LiteralPath (Get-PolicyHivePath $k))) "legacy key $k survived" }
}
Test-Case 'registry: the backup is a real .reg export, and an empty hive is not an error' {
    Reset-Sandbox
    $b = Export-PolicyBackup
    Assert ($b.Ok -and -not $b.File) 'nothing to back up should succeed without a file'
    Set-PresetChecks -Preset Minimal
    [void](Invoke-ApplyNow)
    $b = Export-PolicyBackup
    Assert ($b.Ok -and $b.File -and (Test-Path -LiteralPath $b.File)) "backup failed: $($b.Reason)"
    Assert ((Get-Content -LiteralPath $b.File -Raw) -match 'BraveRewardsDisabled') 'the backup does not contain the policy'
}

# =============================================================== 4. overrides
Test-Case 'overrides: search, new tab and startup pages are written and cleared together' {
    Reset-Sandbox
    $script:Overrides.Search  = @{ Enabled = $true; EngineId = 'duckduckgo'; CustomUrl = '' }
    $script:Overrides.Ntp     = @{ Enabled = $true; DestinationId = 'blank'; CustomUrl = '' }
    $script:Overrides.Startup = @{ Enabled = $true; ModeId = 'specificPages'; Urls = 'https://example.com, https://example.org' }
    $r = Invoke-ApplyNow
    Assert ($r.Failures.Count -eq 0) "failures: $($r.Failures -join '; ')"
    $snap = Read-PolicySnapshot -Path $script:PolicyKeyPath
    Assert ($snap.Values['DefaultSearchProviderName'] -eq 'DuckDuckGo') 'search provider name'
    Assert ($snap.Values['DefaultSearchProviderSearchURL'] -eq 'https://duckduckgo.com/?q={searchTerms}') 'search URL'
    Assert ($snap.Values['NewTabPageLocation'] -eq 'about:blank') 'new tab page'
    Assert ($snap.Values['RestoreOnStartup'] -eq 4) 'startup mode code'
    Assert (($snap.Urls -join ',') -eq 'https://example.com,https://example.org') "startup URLs: $($snap.Urls -join ',')"
    $script:Overrides.Search.Enabled = $false; $script:Overrides.Ntp.Enabled = $false; $script:Overrides.Startup.Enabled = $false
    [void](Invoke-ApplyNow)
    $snap = Read-PolicySnapshot -Path $script:PolicyKeyPath
    Assert ($snap.Values.Count -eq 0 -and $snap.Urls.Count -eq 0) 'untick + Apply must remove every override value'
}
Test-Case 'overrides: unusable input is rejected with a message instead of being written' {
    Reset-Sandbox
    $script:Overrides.Search = @{ Enabled = $true; EngineId = 'custom'; CustomUrl = '' }
    $threw = $false; try { [void](Get-DesiredOverrides) } catch { $threw = $true }
    Assert $threw 'an empty custom search URL must be rejected'
    $script:Overrides.Search = @{ Enabled = $true; EngineId = 'custom'; CustomUrl = 'https://x.example/search?q=' }
    $threw = $false; try { [void](Get-DesiredOverrides) } catch { $threw = $true }
    Assert $threw 'a custom search URL without {searchTerms} must be rejected'
    $script:Overrides.Search = @{ Enabled = $false; EngineId = 'brave'; CustomUrl = '' }
    $script:Overrides.Startup = @{ Enabled = $true; ModeId = 'specificPages'; Urls = 'javascript:alert(1)' }
    $threw = $false; try { [void](Get-DesiredOverrides) } catch { $threw = $true }
    Assert $threw 'a javascript: startup page must be rejected'
}
Test-Case 'overrides: a ticked policy and an override for the same value resolve to the override' {
    Reset-Sandbox
    Set-ItemChecked (Get-BfoItem 'Policy' 'NewTabPageLocation') $true
    $script:Overrides.Ntp = @{ Enabled = $true; DestinationId = 'braveSearchHome'; CustomUrl = '' }
    $plan = New-ApplyPlan
    $op = $plan.Registry | Where-Object { $_.Name -eq 'NewTabPageLocation' }
    Assert ($op.Value -eq 'https://search.brave.com') "override should win, got $($op.Value)"
}

# =============================================================== 5. config export / import
Test-Case 'config: export then import restores every tick, choice and override' {
    Reset-Sandbox
    Set-PresetChecks -Preset MaxPrivacy
    Set-ItemChoice (Get-BfoItem 'Policy' 'HardwareAccelerationModeEnabled') 'disable'
    Set-ItemChecked (Get-BfoItem 'Policy' 'HardwareAccelerationModeEnabled') $true
    $script:Overrides.Search = @{ Enabled = $true; EngineId = 'qwant'; CustomUrl = '' }
    $before = (Get-Ticked | Sort-Object) -join ','
    $json = (New-ConfigObject) | ConvertTo-Json -Depth 5
    Reset-Sandbox
    [void](Import-ConfigObject ($json | ConvertFrom-Json))
    Assert (((Get-Ticked | Sort-Object) -join ',') -eq $before) 'ticks differ after import'
    Assert ((Get-BfoItem 'Policy' 'HardwareAccelerationModeEnabled').Value -eq 0) 'the GPU choice was not restored'
    Assert ($script:Overrides.Search.Enabled -and $script:Overrides.Search.EngineId -eq 'qwant') 'search override not restored'
    Assert ($script:ActiveProfile -eq 'MaxPrivacy') 'active preset not restored'
}
Test-Case 'config: files from earlier versions still import (English labels, old task names, unknown policies)' {
    Reset-Sandbox
    $old = '{ "schemaVersion": 2, "policies": { "BraveRewardsDisabled": true, "WebTorrentDisabled": true }, "tasks": { "BraveSoftwareUpdateTaskMachineCore": true },
              "hosts": { "Brave P3A telemetry": true }, "search": { "enabled": true, "engine": "Google" }, "startup": { "enabled": true, "mode": "Restore my last session" } }'
    $unknown = Import-ConfigObject ($old | ConvertFrom-Json)
    Assert ((Get-BfoItem 'Policy' 'BraveRewardsDisabled').Checked) 'known policy not imported'
    Assert ($unknown -ge 1) 'the removed policy should be counted as unknown, not crash'
    Assert ((Get-BfoItem 'Task' 'core').Checked) 'legacy task name not mapped'
    Assert ((Get-BfoItem 'Host' 'p3a').Checked) 'legacy hosts label not mapped'
    Assert ($script:Overrides.Search.EngineId -eq 'google' -and $script:Overrides.Startup.ModeId -eq 'restoreSession') 'legacy override labels not mapped'
}
Test-Case 'config: text booleans are not blindly truthy' {
    Assert ((ConvertTo-BoolStrict 'false') -eq $false) '"false" must be false'
    Assert ((ConvertTo-BoolStrict 'true') -eq $true) '"true" must be true'
    Assert ((ConvertTo-BoolStrict $false) -eq $false) 'bool passthrough'
}

# =============================================================== 6. hosts file (temp file)
function Write-HostsBytes { param([byte[]]$Bytes) [System.IO.File]::WriteAllBytes($script:HostsFile, $Bytes) }
function Read-HostsBytes { return [System.IO.File]::ReadAllBytes($script:HostsFile) }
function Find-Bytes {
    param([byte[]]$Haystack, [byte[]]$Needle)
    for ($i = 0; $i -le $Haystack.Length - $Needle.Length; $i++) {
        $hit = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) { if ($Haystack[$i + $j] -ne $Needle[$j]) { $hit = $false; break } }
        if ($hit) { return $i }
    }
    return -1
}
Test-Case 'hosts: non-ASCII text in the user''s own entries survives byte for byte (UTF-8 and ANSI)' {
    Reset-Sandbox
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $original = $utf8.GetBytes("# caf$([char]0xE9) - r$([char]0xE9)seau maison $([char]0x2014) note`r`n127.0.0.1 localhost`r`n192.168.1.10 nas.local  # serveur $([char]0xE0) la maison`r`n")
    Write-HostsBytes $original
    Set-HostsManagedDomains -Domains @('example.test')
    $after = Read-HostsBytes
    Assert ((Find-Bytes $after $original) -eq 0) 'the original bytes were altered or moved'
    Assert (@(Get-HostsManagedDomains) -contains 'example.test') 'block not written'
    Set-HostsManagedDomains -Domains @()
    $clean = Read-HostsBytes
    Assert (($clean.Length -eq $original.Length) -and ((Find-Bytes $clean $original) -eq 0)) 'removing the block did not restore the exact original file'
    # ANSI (Windows-1252) bytes that are not valid UTF-8
    $ansi = [byte[]](0x23, 0x20, 0x63, 0x61, 0x66, 0xE9, 0x0D, 0x0A, 0x31, 0x32, 0x37, 0x2E, 0x30, 0x2E, 0x30, 0x2E, 0x31, 0x20, 0x6C, 0x6F, 0x63, 0x61, 0x6C, 0x68, 0x6F, 0x73, 0x74, 0x0D, 0x0A)
    Write-HostsBytes $ansi
    Set-HostsManagedDomains -Domains @('example.test')
    Assert ((Find-Bytes (Read-HostsBytes) $ansi) -eq 0) 'ANSI bytes were altered'
}
Test-Case 'hosts: replacing the block never duplicates it, and LF / missing trailing newline are respected' {
    Reset-Sandbox
    $lf = [System.Text.Encoding]::ASCII.GetBytes("127.0.0.1 localhost`n# note")   # LF, no trailing newline
    Write-HostsBytes $lf
    Set-HostsManagedDomains -Domains @('a.example.test', 'b.example.test')
    Set-HostsManagedDomains -Domains @('c.example.test')
    $text = [System.Text.Encoding]::ASCII.GetString((Read-HostsBytes))
    Assert (([regex]::Matches($text, 'Brave-Free-Origin START')).Count -eq 1) 'block duplicated'
    Assert ($text -notmatch "`r") 'an LF-only file was converted to CRLF'
    Assert ((@(Get-HostsManagedDomains)) -join ',' -eq 'c.example.test') 'old domains were not replaced'
    Assert ($text.StartsWith("127.0.0.1 localhost`n# note")) 'the user''s lines moved'
}
Test-Case 'hosts: UTF-16 files and read-only files are handled' {
    Reset-Sandbox
    $enc = New-Object System.Text.UnicodeEncoding($false, $true)
    Write-HostsBytes ($enc.GetPreamble() + $enc.GetBytes("127.0.0.1 localhost`r`n"))
    Set-HostsManagedDomains -Domains @('example.test')
    $b = Read-HostsBytes
    Assert ($b[0] -eq 0xFF -and $b[1] -eq 0xFE) 'UTF-16 BOM lost'
    Assert (@(Get-HostsManagedDomains) -contains 'example.test') 'UTF-16 block not readable'
    Reset-Sandbox
    Write-HostsBytes ([System.Text.Encoding]::ASCII.GetBytes("127.0.0.1 localhost`r`n"))
    Set-ItemProperty -LiteralPath $script:HostsFile -Name IsReadOnly -Value $true
    Set-HostsManagedDomains -Domains @('example.test')
    Assert ((Get-Item -LiteralPath $script:HostsFile).IsReadOnly) 'the read-only attribute was not restored'
    Set-ItemProperty -LiteralPath $script:HostsFile -Name IsReadOnly -Value $false
}
Test-Case 'hosts: a damaged block (START without END, END without START, START twice) is refused and the file is left untouched' {
    Reset-Sandbox
    $cases = [ordered]@{
        'start without end' = "127.0.0.1 localhost`r`n# === Brave-Free-Origin START - managed block ===`r`n0.0.0.0 a.example.test`r`n192.168.1.50 my-nas`r`n192.168.1.60 printer`r`n"
        'end without start' = "127.0.0.1 localhost`r`n0.0.0.0 a.example.test`r`n# === Brave-Free-Origin END ===`r`n192.168.1.50 my-nas`r`n"
        'start twice'       = "# === Brave-Free-Origin START ===`r`n0.0.0.0 a.example.test`r`n# === Brave-Free-Origin START ===`r`n0.0.0.0 b.example.test`r`n# === Brave-Free-Origin END ===`r`n192.168.1.50 my-nas`r`n"
    }
    foreach ($name in $cases.Keys) {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($cases[$name])
        Write-HostsBytes $bytes
        $refused = $false
        try { Set-HostsManagedDomains -Domains @('new.example.test') } catch { $refused = ("$($_.Exception.Message)" -match 'damaged') }
        Assert $refused "$name : the damaged block was not refused"
        $after = Read-HostsBytes
        Assert (($after.Length -eq $bytes.Length) -and ((Find-Bytes $after $bytes) -eq 0)) "$name : the file was changed"
    }
    Write-HostsBytes ([System.Text.Encoding]::ASCII.GetBytes($cases['start without end']))
    Assert (@(Get-HostsManagedDomains).Count -eq 0) 'an unclosed block must not be reported as blocked domains'
    # two well-formed blocks are fine: both are replaced by one, and the user's line stays
    Write-HostsBytes ([System.Text.Encoding]::ASCII.GetBytes("# === Brave-Free-Origin START ===`r`n0.0.0.0 a.example.test`r`n# === Brave-Free-Origin END ===`r`n192.168.1.50 my-nas`r`n# === Brave-Free-Origin START ===`r`n0.0.0.0 b.example.test`r`n# === Brave-Free-Origin END ===`r`n"))
    Set-HostsManagedDomains -Domains @('c.example.test')
    $text = [System.Text.Encoding]::ASCII.GetString((Read-HostsBytes))
    Assert ((([regex]::Matches($text, 'Brave-Free-Origin START')).Count -eq 1) -and ($text -match '192\.168\.1\.50 my-nas')) 'two well-formed blocks should collapse into one and keep the user''s line'
}
Test-Case 'hosts: the read-only flag is put back even when the write fails' {
    Reset-Sandbox
    Write-HostsBytes ([System.Text.Encoding]::ASCII.GetBytes("127.0.0.1 localhost`r`n"))
    Set-ItemProperty -LiteralPath $script:HostsFile -Name IsReadOnly -Value $true
    # a handle that allows reading but not writing makes every write attempt fail, like an antivirus scanning the file
    $lock = [System.IO.File]::Open($script:HostsFile, 'Open', 'Read', 'Read')
    $failed = $false
    try { Set-HostsManagedDomains -Domains @('example.test') } catch { $failed = $true } finally { $lock.Dispose() }
    Assert $failed 'the write should have failed while the file was held open'
    Assert ((Get-Item -LiteralPath $script:HostsFile).IsReadOnly) 'the read-only flag was not restored after the failed write'
    Set-ItemProperty -LiteralPath $script:HostsFile -Name IsReadOnly -Value $false
}
Test-Case 'scriptlets: list files with LF and CRLF endings are split, edited and written back with their own line endings' {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('bfo-scriptlet-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    try {
        $rules = @('! title', 'example.com##+js(set-constant, a, 1)', '||ads.example^', 'other.org##+js(abort-on-property-read, b)')
        foreach ($style in @(@{ Name = 'lf'; Nl = "`n" }, @{ Name = 'crlf'; Nl = "`r`n" })) {
            $file = Join-Path $root "list-$($style.Name).txt"
            $original = [System.Text.Encoding]::UTF8.GetBytes(($rules -join $style.Nl) + $style.Nl)
            [System.IO.File]::WriteAllBytes($file, $original)
            $data = Read-ListFileLines -Path $file
            Assert ($data.Lines.Count -eq 4) "$($style.Name): expected 4 lines, got $($data.Lines.Count)"
            Assert (($data.Lines[0] -eq '! title') -and ($data.Lines[1] -eq $rules[1])) "$($style.Name): lines were not split cleanly"
            Assert (-not @($data.Lines | Where-Object { $_ -match "[`r`n]" }).Count) "$($style.Name): a line kept a stray CR or LF"
            $rec = ConvertTo-ScriptletRecord -File $file -Root $root -Line $rules[1] -LineNumber 2
            Assert ($null -ne $rec) 'the test rule was not recognised as a scriptlet rule'
            Assert ((Set-ScriptletRuleState -Records @($rec) -Enable $false -AffectDuplicates $false) -eq 1) "$($style.Name): disabling changed the wrong number of lines"
            $edited = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($file))
            Assert ($edited -notmatch "`r`r") "$($style.Name): the edit produced CR CR"
            Assert ($edited.Contains($script:ScriptletDisablePrefix + $rules[1])) "$($style.Name): the rule was not commented out"
            if ($style.Name -eq 'lf') { Assert ($edited -notmatch "`r") 'an LF file gained CRs' } else { Assert (($edited -split "`r`n").Count -eq 5) 'a CRLF file lost its line endings' }
            $rec2 = ConvertTo-ScriptletRecord -File $file -Root $root -Line ($script:ScriptletDisablePrefix + $rules[1]) -LineNumber 2
            Assert ((Set-ScriptletRuleState -Records @($rec2) -Enable $true -AffectDuplicates $false) -eq 1) "$($style.Name): re-enabling failed"
            $back = [System.IO.File]::ReadAllBytes($file)
            Assert (($back.Length -eq $original.Length) -and ((Find-Bytes $back $original) -eq 0)) "$($style.Name): re-enabling did not restore the original bytes"
        }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
Test-Case 'hosts: presets tick hosts groups only when the feature is off, and Preview lists adds/keeps/removes' {
    Reset-Sandbox
    Set-PresetChecks -Preset Recommended
    $domains = @(Get-SelectedHostsDomains)
    Assert ($domains -contains 'collector.bsg.brave.com') 'P3A collector should be selected by Recommended'
    Assert ($domains -notcontains 'go-updater.brave.com') 'the update server must never be pre-selected'
    Set-HostsManagedDomains -Domains @('collector.bsg.brave.com', 'old.example.test')
    Update-HostsCache
    $report = New-HostsPlanReport
    Assert ($report -match '\+ usage-ping\.brave\.com' -and $report -match '= collector\.bsg\.brave\.com' -and $report -match '- old\.example\.test') 'hosts preview is wrong'
}

# =============================================================== 7. updater tasks and services (fakes)
Test-Case 'updater: per-user, per-machine and plain task names are all found; foreign tasks are not' {
    Reset-Sandbox
    $script:FakeTasks = @(
        [pscustomobject]@{ Name = 'BraveSoftwareUpdateTaskUserS-1-12-1-1-2-3-4Core{11111111-1111-1111-1111-111111111111}'; State = 'Ready'; Task = $null },
        [pscustomobject]@{ Name = 'BraveSoftwareUpdateTaskUserS-1-12-1-1-2-3-4UA{22222222-2222-2222-2222-222222222222}'; State = 'Ready'; Task = $null },
        [pscustomobject]@{ Name = 'BraveSoftwareUpdateTaskMachineCore'; State = 'Ready'; Task = $null },
        [pscustomobject]@{ Name = 'BraveSoftwareUpdateTaskMachineUA{11111111-2222-3333-4444-555555555555}'; State = 'Ready'; Task = $null }
    )
    Assert ((Find-BfoTasks -Pattern ($script:UpdaterTaskDefs | Where-Object Id -eq 'core').Pattern).Count -eq 2) 'Core tasks not found'
    Assert ((Find-BfoTasks -Pattern ($script:UpdaterTaskDefs | Where-Object Id -eq 'ua').Pattern).Count -eq 2) 'UA tasks not found'
}
Test-Case 'updater: only rows the user changed produce operations, and Restore undoes them' {
    Reset-Sandbox
    $script:FakeTasks = @([pscustomobject]@{ Name = 'BraveSoftwareUpdateTaskMachineUA{1}'; State = 'Ready'; Task = $null })
    $script:FakeServices = @([pscustomobject]@{ Name = 'brave'; StartType = 'Automatic'; Status = 'Running' }, [pscustomobject]@{ Name = 'bravem'; StartType = 'Manual'; Status = 'Stopped' },
                             [pscustomobject]@{ Name = 'brave1dc9a3'; StartType = 'Automatic'; Status = 'Running' })
    Import-CurrentSystemState -Refresh
    Assert ((New-ApplyPlan).System.Count -eq 0) 'untouched updater rows must not produce operations'
    Assert (@(Find-BfoUpdaterServices -Id 'brave').Count -eq 2) 'brave must match brave and the hex-suffixed re-created service'
    Assert (@(Find-BfoUpdaterServices -Id 'bravem').Count -eq 1) 'bravem must not be mistaken for brave'
    Set-ItemChecked (Get-BfoItem 'Task' 'ua') $true
    Set-ItemChecked (Get-BfoItem 'Service' 'bravem') $true
    $plan = New-ApplyPlan
    Assert ($plan.System.Count -eq 2) "expected 2 operations, got $($plan.System.Count)"
    [void](Invoke-ApplyPlan $plan)
    Assert ($script:FakeTasks[0].State -eq 'Disabled') 'the task was not disabled'
    Assert (($script:FakeServices | Where-Object Name -eq 'bravem').StartType -eq 'Disabled') 'the service was not disabled'
    Assert (($script:FakeServices | Where-Object Name -eq 'brave').StartType -eq 'Automatic') 'an untouched service changed'
    [void](Invoke-FullRestore -RemoveForeign $false)
    Assert ($script:FakeTasks[0].State -eq 'Ready') 'Restore did not re-enable the task'
    Assert (($script:FakeServices | Where-Object Name -eq 'bravem').StartType -eq 'Manual') 'Restore did not reset the service to its default'
}
Test-Case 'updater: Restore turns the services older versions could have disabled back on' {
    Reset-Sandbox
    $script:FakeServices = @([pscustomobject]@{ Name = 'BraveElevationService'; StartType = 'Disabled'; Status = 'Stopped' })
    [void](Invoke-FullRestore -RemoveForeign $false)
    Assert (($script:FakeServices | Where-Object Name -eq 'BraveElevationService').StartType -eq 'Manual') 'BraveElevationService stayed disabled'
    Assert (-not ($script:UpdaterServiceDefs | Where-Object Name -eq 'BraveElevationService')) 'BraveElevationService must not be offered as a checkbox'
}
Test-Case 'updater: turning updates off asks first, and the answer is respected' {
    Reset-Sandbox
    $script:FakeTasks = @([pscustomobject]@{ Name = 'BraveSoftwareUpdateTaskMachineUA{1}'; State = 'Ready'; Task = $null })
    Import-CurrentSystemState -Refresh
    Set-ItemChecked (Get-BfoItem 'Task' 'ua') $true
    $script:SelfTestAnswers.Enqueue('No')
    $script:ChkBackup.Checked = $false
    Invoke-ApplyAction
    Assert ($script:FakeTasks[0].State -eq 'Ready') 'answering No must not disable the task'
    Assert (@($script:SelfTestDialogs | Where-Object { $_[1] -eq (T 'msg.updater.confirm') }).Count -ge 1) 'no warning was shown'
    $script:SelfTestAnswers.Enqueue('Yes')
    Invoke-ApplyAction
    Assert ($script:FakeTasks[0].State -eq 'Disabled') 'answering Yes should disable the task'
}

# =============================================================== 7b. settings that were already set elsewhere
# The scenario of the "Existing Brave policies detected" question: BrowserSignin = 1, another search engine, an intranet
# New Tab page - all written by somebody else.
function Set-ExistingScenario {
    Reset-Sandbox
    $key = $script:PolicyKeyPath
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -LiteralPath $key -Name 'BrowserSignin' -Value 1 -PropertyType DWord | Out-Null
    New-ItemProperty -LiteralPath $key -Name 'DefaultSearchProviderEnabled' -Value 1 -PropertyType DWord | Out-Null
    New-ItemProperty -LiteralPath $key -Name 'DefaultSearchProviderName' -Value 'Company Search' -PropertyType String | Out-Null
    New-ItemProperty -LiteralPath $key -Name 'DefaultSearchProviderSearchURL' -Value 'https://company.example/search?q={searchTerms}' -PropertyType String | Out-Null
    New-ItemProperty -LiteralPath $key -Name 'NewTabPageLocation' -Value 'https://intranet.example' -PropertyType String | Out-Null
    $script:Snapshot = Read-PolicySnapshot -Path $key
    Set-ItemChecked (Get-BfoItem 'Policy' 'BrowserSignin') $true
    $script:Overrides.Search.Enabled = $true          # the Brave engine
    $script:ChkBackup.Checked = $false
    $script:SelfTestLastResult = $null
}
function Get-PolicyNow { param([string]$Name) return (Read-PolicySnapshot -Path $script:PolicyKeyPath).Values[$Name] }

Test-Case 'existing settings: the plan finds exactly what somebody else set, and shows what would replace it' {
    Set-ExistingScenario
    $plan = New-ApplyPlan
    $c = @(Get-PolicyConflicts $plan)
    Assert ($c.Count -eq 3) "expected 3 entries, got $($c.Count): $(($c | ForEach-Object { $_.Key }) -join ', ')"
    $signin = $c | Where-Object { $_.Key -eq 'BrowserSignin' }
    Assert (($signin.Current -eq '1') -and ($signin.Wants -eq '0')) 'BrowserSignin should read current 1 / wants 0'
    $search = $c | Where-Object { $_.Key -eq 'search' }
    Assert ($search.Current -eq 'https://company.example/search?q={searchTerms}') "search current: $($search.Current)"
    Assert ($search.Wants -eq 'https://search.brave.com/search?q={searchTerms}') "search wants: $($search.Wants)"
    foreach ($n in 'DefaultSearchProviderName', 'DefaultSearchProviderSearchURL', 'DefaultSearchProviderKeyword', 'DefaultSearchProviderSuggestURL') {
        Assert ($search.Names -contains $n) "the search entry must cover $n so it is kept or replaced whole"
    }
    $ntp = $c | Where-Object { $_.Key -eq 'ntp' }
    Assert (($ntp.Current -eq 'https://intranet.example') -and ($null -eq $ntp.Wants)) 'the New Tab entry should be a removal'
    Assert (Test-PlanHasChanges $plan) 'the plan has changes'
    # keeping an entry drops its changes, including the values that would have been added to it
    $kept = New-ApplyPlan -KeepNames $search.Names
    Assert (-not (@($kept.Registry | Where-Object { $_.Name -like 'DefaultSearchProvider*' -and $_.Action -in 'Add', 'Change' }).Count)) 'a kept search engine must not be half replaced'
    Assert (@(Get-PolicyConflicts $kept).Count -eq 2) 'the kept entry should no longer be asked about'
    $report = New-ApplyPlanReport $plan
    Assert ($report -match 'CHANGE BrowserSignin : 1 -> 0\s+- set elsewhere') 'the preview does not flag the replaced value'
    Assert ($report -match 'Set elsewhere: 3 ') 'the preview does not summarise the conflicts'
    # the rows say the same thing
    Assert ((Get-ItemState (Get-BfoItem 'Policy' 'BrowserSignin')) -eq 'willReplace') 'a ticked row over somebody else''s value should say Will replace'
    Assert ((Get-ItemState (Get-BfoItem 'Policy' 'NewTabPageLocation')) -eq 'willReplace') 'an unticked New Tab row over somebody else''s value should say Will replace (asks first)'
    Assert ((T 'state.willReplace') -ne '' -and (T 'tip.replace') -ne '') 'strings are missing'
}
Test-Case 'existing settings: Cancel changes nothing; Keep changes nothing and says so' {
    Set-ExistingScenario
    $script:SelfTestExistingAnswers.Enqueue('Cancel')
    Invoke-ApplyAction
    Assert ($script:SelfTestExistingDialogs.Count -eq 1) 'the question was not asked'
    Assert ($null -eq $script:SelfTestLastResult) 'Cancel must not apply anything'
    Assert ((Get-PolicyNow 'BrowserSignin') -eq 1 -and (Get-PolicyNow 'NewTabPageLocation') -eq 'https://intranet.example') 'Cancel changed the registry'
    $script:SelfTestExistingAnswers.Enqueue('Keep')
    Invoke-ApplyAction
    Assert ($script:SelfTestExistingDialogs.Count -eq 2) 'the question was not asked again'
    Assert ((Get-PolicyNow 'BrowserSignin') -eq 1) 'Keep changed BrowserSignin'
    Assert ((Get-PolicyNow 'DefaultSearchProviderSearchURL') -eq 'https://company.example/search?q={searchTerms}') 'Keep changed the search engine'
    Assert ($null -eq (Get-PolicyNow 'DefaultSearchProviderKeyword')) 'Keep half replaced the search engine'
    Assert ((Get-PolicyNow 'NewTabPageLocation') -eq 'https://intranet.example') 'Keep removed the New Tab page'
    Assert (@($script:SelfTestDialogs | Where-Object { $_[1] -eq (T 'msg.apply.allKept') }).Count -ge 1) 'Keep did not say that nothing was changed'
    Assert ($null -eq $script:SelfTestLastResult) 'nothing was applied, so there is no result'
    Assert ($script:ExistingMode -eq 'ask') 'a single Keep must not become a standing preference'
}
Test-Case 'existing settings: untick one to keep just that one; replace does the rest and reports both' {
    Set-ExistingScenario
    $script:SelfTestExistingAnswers.Enqueue(@{ Action = 'Replace'; Keep = @('search') })
    Invoke-ApplyAction
    Assert ((Get-PolicyNow 'BrowserSignin') -eq 0) 'the ticked BrowserSignin was not replaced'
    Assert ($null -eq (Get-PolicyNow 'NewTabPageLocation')) 'the ticked New Tab page was not removed'
    Assert ((Get-PolicyNow 'DefaultSearchProviderSearchURL') -eq 'https://company.example/search?q={searchTerms}' -and (Get-PolicyNow 'DefaultSearchProviderName') -eq 'Company Search') 'the unticked search engine was touched'
    Assert ($null -eq (Get-PolicyNow 'DefaultSearchProviderKeyword')) 'the unticked search engine got new values'
    $r = $script:SelfTestLastResult
    Assert ($r -and $r.ConflictsReplaced -eq 2 -and $r.ConflictsKept -eq 1) "replaced/kept = $($r.ConflictsReplaced)/$($r.ConflictsKept)"
    Assert ($r.Failures.Count -eq 0) 'apply reported failures'
    Assert ((Get-Content -LiteralPath $script:LogFile -Raw) -match 'REPLACED BrowserSignin: 1 -> 0') 'the log does not record what was replaced'
}
Test-Case 'existing settings: Replace overwrites everything, remembers what it wrote, and the next Apply has nothing to ask' {
    Set-ExistingScenario
    $script:SelfTestExistingAnswers.Enqueue('Replace')
    Invoke-ApplyAction
    Assert ((Get-PolicyNow 'BrowserSignin') -eq 0) 'BrowserSignin'
    Assert ((Get-PolicyNow 'DefaultSearchProviderSearchURL') -eq 'https://search.brave.com/search?q={searchTerms}') 'search URL'
    Assert ((Get-PolicyNow 'DefaultSearchProviderKeyword') -eq 'brave') 'search keyword'
    Assert ($null -eq (Get-PolicyNow 'NewTabPageLocation')) 'New Tab page'
    Assert ($script:SelfTestLastResult.ConflictsReplaced -eq 3 -and $script:SelfTestLastResult.ConflictsKept -eq 0) 'result counts'
    Assert ($script:AppliedLedger['BrowserSignin'] -eq '0') 'the ledger did not record BrowserSignin'
    $asked = $script:SelfTestExistingDialogs.Count
    Invoke-ApplyAction
    Assert ($script:SelfTestExistingDialogs.Count -eq $asked) 'nothing is set elsewhere any more, so nothing should be asked'
    Assert (@($script:SelfTestDialogs | Where-Object { $_[1] -eq (T 'msg.apply.nothing') }).Count -ge 1) 'the second Apply should have nothing to do'
    # the ledger survives a restart
    $before = $script:AppliedLedger['DefaultSearchProviderSearchURL']
    $script:AppliedLedger = @{}
    Import-AppliedLedger
    Assert ($script:AppliedLedger['DefaultSearchProviderSearchURL'] -eq $before -and $before) 'the ledger was not saved to the settings file'
}
Test-Case 'existing settings: a custom search address typed in this app is ours from then on; one typed elsewhere is not' {
    Reset-Sandbox
    $script:ChkBackup.Checked = $false
    $script:Overrides.Search.Enabled = $true; $script:Overrides.Search.EngineId = 'custom'
    $script:Overrides.Search.CustomUrl = 'https://my-searx.example/search?q={searchTerms}'
    Invoke-ApplyAction
    Assert ((Get-PolicyNow 'DefaultSearchProviderSearchURL') -eq 'https://my-searx.example/search?q={searchTerms}') 'the custom engine was not applied'
    Assert ($script:SelfTestExistingDialogs.Count -eq 0) 'a first Apply into an empty key must not ask'
    $script:Overrides.Search.CustomUrl = 'https://other.example/find?q={searchTerms}'
    Invoke-ApplyAction
    Assert ((Get-PolicyNow 'DefaultSearchProviderSearchURL') -eq 'https://other.example/find?q={searchTerms}') 'changing our own custom engine should just work'
    Assert ($script:SelfTestExistingDialogs.Count -eq 0) 'our own custom engine was treated as somebody else''s'
    $script:Overrides.Search.Enabled = $false
    Invoke-ApplyAction
    Assert ($null -eq (Get-PolicyNow 'DefaultSearchProviderSearchURL')) 'unticking should remove our own custom engine'
    Assert ($script:SelfTestExistingDialogs.Count -eq 0) 'removing our own custom engine should not ask'
    # somebody else's engine at the same place is asked about
    New-Item -Path $script:PolicyKeyPath -Force | Out-Null
    New-ItemProperty -LiteralPath $script:PolicyKeyPath -Name 'DefaultSearchProviderSearchURL' -Value 'https://elsewhere.example/?q={searchTerms}' -PropertyType String | Out-Null
    $script:Snapshot = Read-PolicySnapshot -Path $script:PolicyKeyPath
    $c = @(Get-PolicyConflicts (New-ApplyPlan))
    Assert (($c.Count -eq 1) -and ($c[0].Key -eq 'search') -and ($null -eq $c[0].Wants)) 'an engine set elsewhere should be listed as a removal'
}
Test-Case 'existing settings: a custom search engine written by an older version (nothing remembered) is recognised as ours' {
    Reset-Sandbox
    $script:ChkBackup.Checked = $false
    $key = $script:PolicyKeyPath
    New-Item -Path $key -Force | Out-Null
    New-ItemProperty -LiteralPath $key -Name 'DefaultSearchProviderEnabled' -Value 1 -PropertyType DWord | Out-Null
    New-ItemProperty -LiteralPath $key -Name 'DefaultSearchProviderName' -Value 'Custom Search' -PropertyType String | Out-Null
    New-ItemProperty -LiteralPath $key -Name 'DefaultSearchProviderKeyword' -Value 'custom' -PropertyType String | Out-Null
    New-ItemProperty -LiteralPath $key -Name 'DefaultSearchProviderSearchURL' -Value 'https://my-searx.example/search?q={searchTerms}' -PropertyType String | Out-Null
    $script:Snapshot = Read-PolicySnapshot -Path $key
    Assert (@(Get-PolicyConflicts (New-ApplyPlan)).Count -eq 0) 'an older custom engine should not be asked about'
    Assert (@(@((Get-ForeignPolicyValues).Values) | Where-Object { $_ -like 'DefaultSearchProvider*' }).Count -eq 0) 'an older custom engine must not be called foreign'
    Invoke-ApplyAction                   # the search override is off, so the engine is removed - it is ours, so without a question
    Assert ($script:SelfTestExistingDialogs.Count -eq 0) 'removing our own older custom engine should not ask'
    Assert ($null -eq (Get-PolicyNow 'DefaultSearchProviderSearchURL')) 'the older custom engine was not removed'
}
Test-Case 'existing settings: a list of startup pages set elsewhere is asked about, kept whole or removed whole' {
    Reset-Sandbox
    $script:ChkBackup.Checked = $false
    New-Item -Path $script:PolicyKeyPath -Force | Out-Null
    New-ItemProperty -LiteralPath $script:PolicyKeyPath -Name 'RestoreOnStartup' -Value 4 -PropertyType DWord | Out-Null
    New-Item -Path (Join-Path $script:PolicyKeyPath 'RestoreOnStartupURLs') -Force | Out-Null
    New-ItemProperty -LiteralPath (Join-Path $script:PolicyKeyPath 'RestoreOnStartupURLs') -Name '1' -Value 'https://intranet.example/start' -PropertyType String | Out-Null
    $script:Snapshot = Read-PolicySnapshot -Path $script:PolicyKeyPath
    $c = @(Get-PolicyConflicts (New-ApplyPlan))
    Assert (($c.Count -eq 1) -and ($c[0].Key -eq 'startup')) 'the startup pages should be one entry'
    Assert ($c[0].Current -match 'intranet\.example/start') "startup current: $($c[0].Current)"
    $script:SelfTestExistingAnswers.Enqueue('Keep')
    Invoke-ApplyAction
    Assert ((Get-PolicyNow 'RestoreOnStartup') -eq 4 -and (Read-PolicySnapshot -Path $script:PolicyKeyPath).Urls.Count -eq 1) 'Keep did not keep the startup pages'
    $script:SelfTestExistingAnswers.Enqueue('Replace')
    Invoke-ApplyAction
    $snap = Read-PolicySnapshot -Path $script:PolicyKeyPath
    Assert (($null -eq $snap.Values['RestoreOnStartup']) -and ($snap.Urls.Count -eq 0)) 'Replace did not remove the startup pages'
}
Test-Case 'existing settings: the preference (ask / always replace / always keep) is respected, saved and shown in Tools' {
    Set-ExistingScenario
    Set-ExistingMode 'keep'
    Assert ((Get-BfoSettings -Path $script:SettingsPath)['existingMode'] -eq 'keep') 'the preference was not saved'
    Assert ((Get-ItemState (Get-BfoItem 'Policy' 'BrowserSignin')) -eq 'foreign') 'with "always keep", the row should show Set elsewhere'
    Update-PendingSummary
    Assert ($script:LblPending.Text -eq (T 'bar.none')) "nothing should be pending when everything is kept: $($script:LblPending.Text)"
    Assert ((New-ApplyPlanReport (New-ApplyPlan -KeepNames @('BrowserSignin'))) -match 'LEAVE\s+BrowserSignin = 1\s+- set elsewhere; kept') 'the preview does not explain a kept value'
    Invoke-ApplyAction
    Assert ($script:SelfTestExistingDialogs.Count -eq 0) '"always keep" must not ask'
    Assert ((Get-PolicyNow 'BrowserSignin') -eq 1 -and (Get-PolicyNow 'NewTabPageLocation') -eq 'https://intranet.example') '"always keep" changed something'
    Set-ExistingMode 'replace'
    Assert ((Get-ItemState (Get-BfoItem 'Policy' 'BrowserSignin')) -eq 'willReplace') '"always replace" shows Will replace'
    Invoke-ApplyAction
    Assert ($script:SelfTestExistingDialogs.Count -eq 0) '"always replace" must not ask'
    Assert ((Get-PolicyNow 'BrowserSignin') -eq 0 -and $null -eq (Get-PolicyNow 'NewTabPageLocation')) '"always replace" did not replace'
    $menu = New-ToolsMenu
    $sub = $menu.Items | Where-Object { "$($_.Tag)" -eq 'tools.existing' }
    Assert ($sub -and $sub.DropDownItems.Count -eq 3) 'the Tools menu has no submenu for this'
    Assert ((@($sub.DropDownItems | Where-Object { $_.Checked }).Count -eq 1) -and (($sub.DropDownItems | Where-Object { $_.Checked }).Tag -eq 'tools.existing.replace')) 'the submenu does not show the current preference'
    # "do this every time" on the question itself
    Set-ExistingScenario
    Set-ExistingMode 'ask'
    $script:SelfTestExistingAnswers.Enqueue(@{ Action = 'Keep'; Remember = $true })
    Invoke-ApplyAction
    Assert ($script:ExistingMode -eq 'keep') 'ticking "do this every time" did not switch the preference'
    Set-ExistingScenario
    Set-ExistingMode 'ask'
    $script:SelfTestExistingAnswers.Enqueue(@{ Action = 'Replace'; Keep = @('search'); Remember = $true })
    Invoke-ApplyAction
    Assert ($script:ExistingMode -eq 'ask') 'a partly ticked answer must not become a standing "always replace"'
    Set-ExistingMode 'ask'
    Set-ExistingMode 'nonsense'
    Assert ($script:ExistingMode -eq 'ask') 'an unknown preference must be ignored'
}

# =============================================================== 8. window, pages, filter, actions
$form.ShowInTaskbar = $false; $form.StartPosition = 'Manual'; $form.Location = New-Object System.Drawing.Point(-32000, -32000)
$form.Show()
[System.Windows.Forms.Application]::DoEvents()
function Save-Shot {
    param([string]$Name)
    if (-not $script:WantShots) { return }
    [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 120; [System.Windows.Forms.Application]::DoEvents()
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $bmp.Save((Join-Path $script:TestOut "$Name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}
Test-Case 'window: it fits a small work area and every page can be opened' {
    Assert ($form.Height -le [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height) 'window taller than the work area'
    Assert ($form.MinimumSize.Height -le 620 -and $form.MinimumSize.Width -le 960) "minimum size too large: $($form.MinimumSize)"
    foreach ($p in $script:PageOrder) {
        Select-NavPage $p.Id
        Assert ($script:PagePanels[$p.Id].Visible) "page $($p.Id) did not open"
        Assert ($script:LblPageTitle.Text -eq (T "page.$($p.Id).title")) "page title for $($p.Id)"
        Save-Shot "page-$($p.Id)"
    }
}
Test-Case 'window: every row is drawn tall enough for its wrapped text and every setting has a row' {
    Reset-Sandbox
    Invoke-LoadCurrentState
    $rows = 0
    foreach ($id in $script:Grids.Keys) {
        Select-NavPage $id
        $g = $script:Grids[$id]
        Update-GridRowHeights $g
        foreach ($r in $g.Rows) { $rows++; Assert ($r.Height -ge 40) "row $($r.Tag.Id) is only $($r.Height) px" }
    }
    Assert ($rows -eq $script:Items.Count) "$rows rows for $($script:Items.Count) items"
}
Test-Case 'window: the search box shows a hint, is hidden on pages it does not cover, and the technical column is named per page' {
    Select-NavPage 'braveFeatures'
    Assert ($script:FilterBoxPanel.Visible -and $script:FilterOptsPanel.Visible) 'search controls should be visible on a policy page'
    Assert ($script:LblFilterHint.Visible -and $script:LblFilterHint.Text -eq (T 'filter.placeholder')) 'the hint is not showing on an empty search box'
    $script:TxtFilter.Text = 'wallet'
    Assert (-not $script:LblFilterHint.Visible) 'the hint should hide once something is typed'
    Clear-Filter
    Assert $script:LblFilterHint.Visible 'the hint should return when the box is empty again'
    foreach ($id in 'overrides', 'scriptlets') {
        Select-NavPage $id
        Assert ((-not $script:FilterBoxPanel.Visible) -and (-not $script:FilterOptsPanel.Visible)) "search controls should be hidden on $id"
    }
    foreach ($id in 'updater', 'hosts') {
        Select-NavPage $id
        Assert $script:FilterBoxPanel.Visible "search controls should be visible on $id"
    }
    Assert ($script:Grids['braveFeatures'].Columns['policy'].HeaderText -eq (T 'grid.col.policy')) 'policy pages should say Policy'
    Assert ($script:Grids['hosts'].Columns['policy'].HeaderText -eq (T 'grid.col.domains')) 'the hosts page should say Domains'
    Assert ($script:Grids['updater'].Columns['policy'].HeaderText -eq (T 'grid.col.name')) 'the updater page should say Name'
    Select-NavPage 'braveFeatures'
}
Test-Case 'window: resizing re-lays out every grid without errors' {
    Select-NavPage 'braveFeatures'
    $original = $form.Size
    $smaller = New-Object System.Drawing.Size([Math]::Max($form.MinimumSize.Width, 980), [Math]::Max($form.MinimumSize.Height, 640))
    foreach ($k in @($script:GridsDirty.Keys)) { $script:GridsDirty[$k] = $false }
    $form.Size = $smaller
    foreach ($k in @($script:GridsDirty.Keys)) { Assert $script:GridsDirty[$k] "grid $k was not marked for re-layout after the window was resized" }
    foreach ($k in @($script:GridsDirty.Keys)) { $script:GridsDirty[$k] = $false }
    $form.Size = $original
    foreach ($k in @($script:GridsDirty.Keys)) { Assert $script:GridsDirty[$k] "grid $k was not marked for re-layout after the window was restored" }
    Update-GridRowHeights $script:CurrentGrid
    foreach ($r in $script:CurrentGrid.Rows) { Assert ($r.Height -ge 40) "row $($r.Tag.Id) is only $($r.Height) px after a resize" }
}
Test-Case 'window: technical details, the log panel and repeated resizing work on every page' {
    $original = $form.Size
    $sizes = @($form.MinimumSize, (New-Object System.Drawing.Size(1500, 900)), $form.MinimumSize, $original)
    foreach ($id in @($script:Grids.Keys)) {
        Select-NavPage $id
        $g = $script:Grids[$id]
        $script:ChkTechnical.Checked = $false
        Assert (-not $g.Columns['policy'].Visible -and -not $g.Columns['value'].Visible) "technical columns still visible on $id after switching them off"
        $script:ChkTechnical.Checked = $true
        foreach ($size in $sizes) {
            $form.Size = $size
            Update-GridRowHeights $g
            foreach ($r in $g.Rows) { Assert ($r.Height -ge 40) "row $($r.Tag.Id) on $id is only $($r.Height) px at $($size.Width)x$($size.Height)" }
        }
    }
    Switch-LogPanel
    Switch-LogPanel
    Select-NavPage 'braveFeatures'
}
Test-Case 'window: driving the real controls (preset buttons, rows, search box, language box, resize) logs no errors' {
    Reset-Sandbox
    Invoke-LoadCurrentState
    $logBefore = if (Test-Path -LiteralPath $script:LogFile) { (Get-Item -LiteralPath $script:LogFile).Length } else { 0 }
    $pump = { [System.Windows.Forms.Application]::DoEvents() }
    $originalLocale = $script:CurrentLocale
    $originalSize = $form.Size
    try {
        foreach ($key in $script:PresetKeys) {
            if ($script:PresetButtons.ContainsKey($key)) { $script:PresetButtons[$key].PerformClick(); & $pump }
        }
        foreach ($id in @($script:Grids.Keys)) {
            Select-NavPage $id
            foreach ($row in @($script:Grids[$id].Rows | Select-Object -First 3)) { Toggle-Item $row.Tag; Toggle-Item $row.Tag }
            & $pump
        }
        $script:TxtFilter.Text = 'wallet'
        1..6 | ForEach-Object { & $pump; Start-Sleep -Milliseconds 100 }
        $script:ChkSelectedOnly.Checked = $true; & $pump
        $script:ChkSelectedOnly.Checked = $false; & $pump
        Clear-Filter; & $pump
        for ($i = 0; $i -lt $script:LocaleList.Count; $i++) { $script:LanguageCombo.SelectedIndex = $i; & $pump }
        $form.Size = $form.MinimumSize; & $pump
        $form.Size = $originalSize; & $pump
    } finally {
        [void](Set-BfoLocale -Code $originalLocale)
        Update-UiLanguage
        for ($i = 0; $i -lt $script:LocaleList.Count; $i++) { if ($script:LocaleList[$i].Code -eq $originalLocale) { $script:LanguageCombo.SelectedIndex = $i } }
        Select-NavPage 'braveFeatures'
    }
    $bytes = [System.IO.File]::ReadAllBytes($script:LogFile)
    $newLog = [System.Text.Encoding]::UTF8.GetString($bytes, [int]$logBefore, $bytes.Length - [int]$logBefore)
    $errors = @($newLog -split "`r?`n" | Where-Object { $_ -match '\[ERR\]' })
    Assert ($errors.Count -eq 0) ("errors were logged while the controls were driven: " + ($errors -join ' | '))
}
Test-Case 'window: the sidebar shows live n/N counts and the pending bar counts the diff' {
    Reset-Sandbox
    Invoke-LoadCurrentState
    Invoke-PresetClick 'Minimal'
    $node = $script:NavNodes['braveFeatures']
    Assert ($node.Text -match '6/12') "sidebar text was '$($node.Text)'"
    Assert ($script:LblPending.Text -match '6') "pending text was '$($script:LblPending.Text)'"
    Assert ($script:PresetButtons['Minimal'].BackColor -eq $script:Clr.Ember) 'the active preset is not highlighted'
    Invoke-PresetClick 'None'
    Assert ($script:LblPending.Text -eq (T 'bar.none')) 'no pending changes expected after Stock / None on a clean key'
}
Test-Case 'window: row status follows the registry (Active / Will apply / Will change / Will remove / Not set)' {
    Reset-Sandbox
    New-Item -Path $script:PolicyKeyPath -Force | Out-Null
    New-ItemProperty -LiteralPath $script:PolicyKeyPath -Name 'BraveRewardsDisabled' -Value 1 -PropertyType DWord | Out-Null
    New-ItemProperty -LiteralPath $script:PolicyKeyPath -Name 'BraveWalletDisabled' -Value 0 -PropertyType DWord | Out-Null              # a value this tool never writes: somebody else's
    New-ItemProperty -LiteralPath $script:PolicyKeyPath -Name 'HardwareAccelerationModeEnabled' -Value 1 -PropertyType DWord | Out-Null  # one of our own two choices
    New-ItemProperty -LiteralPath $script:PolicyKeyPath -Name 'BraveNewsDisabled' -Value 1 -PropertyType DWord | Out-Null
    Invoke-LoadCurrentState
    Set-ItemChecked (Get-BfoItem 'Policy' 'BraveWalletDisabled') $true      # registry has somebody else's value -> replace (asks first)
    Set-ItemChoice (Get-BfoItem 'Policy' 'HardwareAccelerationModeEnabled') 'disable'   # registry has our other choice -> change
    Set-ItemChecked (Get-BfoItem 'Policy' 'BraveVPNDisabled') $true          # not in registry -> apply
    Set-ItemChecked (Get-BfoItem 'Policy' 'BraveNewsDisabled') $false        # in registry, unticked -> remove
    Update-AllItemViews
    Assert ((Get-ItemState (Get-BfoItem 'Policy' 'BraveRewardsDisabled')) -eq 'active') 'active'
    Assert ((Get-ItemState (Get-BfoItem 'Policy' 'BraveWalletDisabled')) -eq 'willReplace') 'willReplace'
    Assert ((Get-ItemState (Get-BfoItem 'Policy' 'HardwareAccelerationModeEnabled')) -eq 'willChange') 'willChange'
    Assert ((Get-ItemState (Get-BfoItem 'Policy' 'BraveVPNDisabled')) -eq 'willApply') 'willApply'
    Assert ((Get-ItemState (Get-BfoItem 'Policy' 'BraveNewsDisabled')) -eq 'willRemove') 'willRemove'
    Assert ((Get-ItemState (Get-BfoItem 'Policy' 'BraveTalkDisabled')) -eq 'notSet') 'notSet'
}
Test-Case 'window: search filters every page at once, tick-all works on what is visible, clear restores' {
    Reset-Sandbox
    $script:FilterText = 'leo'; Update-Filter
    $visible = @($script:Items | Where-Object { $_.Row -and $_.Row.Visible })
    Assert ($visible.Count -ge 1 -and $visible.Count -le 4) "'leo' matched $($visible.Count) rows"
    Assert ($visible.Id -contains 'BraveAIChatEnabled') 'Leo not found by its plain name'
    $script:FilterText = 'BraveTalkDisabled'; Update-Filter
    Assert (@($script:Items | Where-Object { $_.Row -and $_.Row.Visible }).Count -eq 1) 'a policy name should find exactly its row'
    Clear-Filter
    Assert (@($script:Items | Where-Object { $_.Row -and -not $_.Row.Visible }).Count -eq 0) 'clearing the filter left rows hidden'
    Select-NavPage 'braveFeatures'
    Set-PageChecks $true
    Assert (@($script:Items | Where-Object { $_.Page -eq 'braveFeatures' -and $_.Checked }).Count -eq 12) 'tick all'
    Set-PageChecks $false
    Assert (@($script:Items | Where-Object { $_.Page -eq 'braveFeatures' -and $_.Checked }).Count -eq 0) 'untick all'
}
Test-Case 'actions: Preview, Verify, Apply and Restore run end to end without errors' {
    Reset-Sandbox
    Invoke-LoadCurrentState
    Invoke-PresetClick 'Recommended'
    Invoke-PreviewAction
    Assert ($script:SelfTestReports.Count -eq 1 -and $script:SelfTestReports[0][1] -match 'dry run') 'preview report missing'
    $script:ChkBackup.Checked = $true
    Invoke-ApplyAction
    $snap = Read-PolicySnapshot -Path $script:PolicyKeyPath
    Assert ($snap.Values.Count -eq $sel.Recommended.Count) "applied $($snap.Values.Count)"
    Assert ($script:SelfTestLastResult.Failures.Count -eq 0) 'apply reported failures'
    Invoke-VerifyAction
    Assert ($script:SelfTestReports[-1][1] -match 'Missing \(not in registry\): 0') 'verify should report nothing missing'
    Invoke-RestoreAction
    Assert (-not (Test-Path -LiteralPath $script:PolicyKeyPath)) 'restore left the key behind'
    Assert ((Get-Ticked).Count -eq 0 -and $script:ActiveProfile -eq 'None') 'restore should untick everything'
    Invoke-ApplyAction
    Assert (@($script:SelfTestDialogs | Where-Object { $_[1] -eq (T 'msg.apply.nothing') }).Count -ge 1) 'Apply with nothing to do should say so'
}
Test-Case 'actions: a failing handler is reported, logged and never crashes the window' {
    $script:SelfTestDialogs = @()
    Invoke-Guarded 'Deliberate test failure' { throw 'boom' }
    Assert (@($script:SelfTestDialogs | Where-Object { $_[1] -match 'boom' }).Count -eq 1) 'the error dialog was not shown'
    Assert ((Get-Content -LiteralPath $script:LogFile -Raw) -match 'Deliberate test failure failed') 'the failure was not logged'
}
Test-Case 'actions: opening Brave pages goes through the un-elevated launcher (recorded in the sandbox)' {
    $script:LastOpenedUrl = $null
    [void](Open-InBrave 'brave://policy')
    Assert ($script:LastOpenedUrl -eq 'brave://policy' -or $script:LastOpenedUrl -eq $null) 'unexpected launch record'
    Assert (-not (Get-BraveExecutable -Channel 'Nope')) 'unknown channel must not resolve'
    $menu = New-ToolsMenu
    Assert ($menu.Items.Count -ge 8) 'tools menu is incomplete'
}

function Invoke-ExistingDialogForTest {
    param($Conflicts, [string]$Button, [string[]]$Untick = @(), [bool]$Remember = $false)
    $ui = New-ExistingPoliciesDialog $Conflicts
    try {
        $f = $ui.Form
        $f.ShowInTaskbar = $false; $f.StartPosition = 'Manual'; $f.Location = New-Object System.Drawing.Point(-32000, -32000)
        $f.Show()
        1..3 | ForEach-Object { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
        foreach ($row in $ui.Grid.Rows) { if ($Untick -contains $row.Tag.Key) { $row.Cells[0].Value = $false } }
        if ($Remember -and $ui.Remember.Enabled) { $ui.Remember.Checked = $true }
        $unticked = @(); foreach ($row in $ui.Grid.Rows) { if (-not [bool]$row.Cells[0].Value) { $unticked += $row.Tag.Key } }
        $every = ($ui.Remember.Checked -and $ui.Remember.Enabled)
        switch ($Button) {
            'Apply'  { $ui.Apply.PerformClick() }
            'Keep'   { $ui.Keep.PerformClick() }
            'Cancel' { $ui.Cancel.PerformClick() }
            'Escape' { $f.Close() }
        }
        return (New-ExistingChoice -Action $ui.State.Action -Conflicts $Conflicts -KeepKeys $unticked -Remember $every)
    } finally { $ui.Form.Dispose(); $script:ExistingUi = $null }
}
Test-Case 'existing settings window: lists every entry ticked, unticking turns "every time" off, and each button gives its answer' {
    Set-ExistingScenario
    $conflicts = @(Get-PolicyConflicts (New-ApplyPlan))
    $ui = New-ExistingPoliciesDialog $conflicts
    try {
        $f = $ui.Form
        $f.ShowInTaskbar = $false; $f.StartPosition = 'Manual'; $f.Location = New-Object System.Drawing.Point(-32000, -32000)
        $f.Show()
        1..4 | ForEach-Object { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 60 }
        Assert ($ui.Grid.Rows.Count -eq 3) "rows: $($ui.Grid.Rows.Count)"
        Assert (@($ui.Grid.Rows | Where-Object { -not [bool]$_.Cells[0].Value }).Count -eq 0) 'every entry should start ticked'
        Assert ($ui.Remember.Enabled -and -not $ui.Remember.Checked) '"every time" should be available, and off, while everything is ticked'
        foreach ($row in $ui.Grid.Rows) { Assert (("$($row.Cells['setting'].Value)" -ne '') -and ("$($row.Cells['current'].Value)" -ne '') -and ("$($row.Cells['wants'].Value)" -ne '')) "row $($row.Tag.Key) has an empty cell" }
        $ntpRow = $ui.Grid.Rows | Where-Object { $_.Tag.Key -eq 'ntp' }
        Assert ($ntpRow.Cells['wants'].Value -eq (T 'existing.remove')) 'the removal is not spelled out'
        Assert ($ui.Intro.Text -eq (T 'existing.intro' @(3))) 'the count is wrong'
        $origin = New-Object System.Drawing.Point(0, 0)
        $introY = $ui.Intro.PointToScreen($origin).Y; $gridY = $ui.Grid.PointToScreen($origin).Y; $applyY = $ui.Apply.PointToScreen($origin).Y
        Assert (($ui.Grid.Height -gt 60) -and ($introY -lt $gridY) -and ($applyY -gt ($gridY + $ui.Grid.Height))) "the window is laid out wrongly: intro $introY, list $gridY (height $($ui.Grid.Height)), buttons $applyY"
        $ui.Remember.Checked = $true
        $ui.Grid.Rows[0].Cells[0].Value = $false
        Assert ((-not $ui.Remember.Enabled) -and (-not $ui.Remember.Checked)) 'unticking a row must switch "every time" off'
        $ui.Grid.Rows[0].Cells[0].Value = $true
        Assert $ui.Remember.Enabled '"every time" should come back when everything is ticked again'
        # a click on the first row's title, then on its tick box (the grid's protected click method, called directly)
        $onClick = [System.Windows.Forms.DataGridView].GetMethod('OnCellClick', [System.Reflection.BindingFlags]'Instance,NonPublic')
        $click = [System.Windows.Forms.DataGridViewCellEventArgs]::new(1, 0)
        [void]$onClick.Invoke($ui.Grid, [object[]]@($click.psobject.BaseObject))
        Assert (-not [bool]$ui.Grid.Rows[0].Cells[0].Value) 'clicking a row should untick it'
        $click = [System.Windows.Forms.DataGridViewCellEventArgs]::new(0, 0)
        [void]$onClick.Invoke($ui.Grid, [object[]]@($click.psobject.BaseObject))
        Assert ([bool]$ui.Grid.Rows[0].Cells[0].Value) 'clicking the tick box should tick it again'
    } finally { $ui.Form.Dispose(); $script:ExistingUi = $null }

    $r = Invoke-ExistingDialogForTest $conflicts 'Apply'
    Assert (($r.Action -eq 'Replace') -and ($r.KeepNames.Count -eq 0)) 'Apply BFO changes anyway with everything ticked should replace all'
    $r = Invoke-ExistingDialogForTest $conflicts 'Apply' -Untick @('BrowserSignin')
    Assert (($r.Action -eq 'Replace') -and ($r.KeepNames -contains 'BrowserSignin') -and ($r.KeepNames -notcontains 'NewTabPageLocation')) 'an unticked entry should be kept and only that one'
    $r = Invoke-ExistingDialogForTest $conflicts 'Keep'
    Assert (($r.Action -eq 'Keep') -and ($r.KeepNames -contains 'BrowserSignin') -and ($r.KeepNames -contains 'NewTabPageLocation') -and ($r.KeepNames -contains 'DefaultSearchProviderSearchURL')) 'Keep existing settings should keep every entry'
    $r = Invoke-ExistingDialogForTest $conflicts 'Cancel'
    Assert ($r.Action -eq 'Cancel') 'Cancel'
    $r = Invoke-ExistingDialogForTest $conflicts 'Escape'
    Assert ($r.Action -eq 'Cancel') 'closing the window must count as Cancel'
    $r = Invoke-ExistingDialogForTest $conflicts 'Keep' -Remember $true
    Assert ($r.Remember) '"do this every time" was lost'
    $r = Invoke-ExistingDialogForTest $conflicts 'Apply' -Untick @('search') -Remember $true
    Assert (-not $r.Remember) '"do this every time" must be ignored when a row was unticked'
}

# =============================================================== 9. languages
$originalLocale = $script:CurrentLocale
foreach ($loc in $script:LocaleList) {
    Test-Case "language $($loc.Code) ($($loc.EnglishName)): switches live, no missing text, right direction and font" {
        [void](Set-BfoLocale -Code $loc.Code)
        Update-UiLanguage
        $wantRtl = [bool]$loc.Rtl
        $missing = New-Object System.Collections.ArrayList
        Find-MissingText $script:Form $missing
        Assert ($missing.Count -eq 0) "untranslated placeholders: $($missing -join ' | ')"
        foreach ($g in $script:Grids.Values) {
            foreach ($row in $g.Rows) { foreach ($c in $row.Cells) { Assert (-not ("$($c.Value)" -match '!!')) "grid cell '$($c.Value)'" } }
        }
        foreach ($mi in $script:ToolsMenu.Items) {
            Assert (-not ("$($mi.Text)" -match '!!')) "menu '$($mi.Text)'"
            if ($mi -is [System.Windows.Forms.ToolStripMenuItem]) { foreach ($sub in $mi.DropDownItems) { Assert (-not ("$($sub.Text)" -match '!!')) "submenu '$($sub.Text)'" } }
        }
        $sample = @(
            [pscustomobject]@{ Key = 'BrowserSignin'; Title = (T 'policy.BrowserSignin.title'); Policy = 'BrowserSignin'; Current = '1'; Wants = '0'; Names = @('BrowserSignin') },
            [pscustomobject]@{ Key = 'ntp'; Title = (T 'existing.group.ntp'); Policy = 'NewTabPageLocation'; Current = 'https://intranet.example'; Wants = $null; Names = @('NewTabPageLocation') })
        $ui = New-ExistingPoliciesDialog $sample
        try {
            $bad = New-Object System.Collections.ArrayList
            Find-MissingText $ui.Form $bad
            Assert ($bad.Count -eq 0) "existing-settings window: untranslated placeholders: $($bad -join ' | ')"
            foreach ($col in $ui.Grid.Columns) { Assert (-not ("$($col.HeaderText)" -match '!!')) "existing-settings column '$($col.HeaderText)'" }
            Assert (($ui.Form.RightToLeft -eq [System.Windows.Forms.RightToLeft]::Yes) -eq $wantRtl) 'the existing-settings window does not follow the language direction'
            Assert ($ui.Apply.Text -ne '' -and $ui.Keep.Text -ne '' -and $ui.Cancel.Text -ne '') 'a button of the existing-settings window has no text'
        } finally { $ui.Form.Dispose(); $script:ExistingUi = $null }
        Assert ($script:IsRtl -eq $wantRtl) "IsRtl is $($script:IsRtl)"
        Assert (($script:Form.RightToLeft -eq [System.Windows.Forms.RightToLeft]::Yes) -eq $wantRtl) 'form direction does not match the language'
        Assert (Test-FontInstalled (Get-FontPlan).Body) "font '$((Get-FontPlan).Body)' is not installed"
        Assert ($script:LanguageCombo.SelectedIndex -ge 0) 'language picker has no selection'
        foreach ($p in $script:PageOrder) { Select-NavPage $p.Id; Assert ($script:LblPageTitle.Text -ne '') "empty title for $($p.Id)"; if ($p.Id -in 'braveFeatures', 'updater', 'overrides') { Save-Shot "lang-$($loc.Code)-$($p.Id)" } }
        Select-NavPage 'braveFeatures'
    }
}
Test-Case 'language: the PC language is used when we have it, English otherwise' {
    $french = @($script:LocaleList.Code | Where-Object { $_ -like 'fr-*' })
    if ($french.Count -gt 0) { Assert ((Resolve-StartupLocale -Requested '' -Saved '' -UiCulture 'fr-CA') -eq $french[0]) 'fr-CA should map to the French file' }
    Assert ((Resolve-StartupLocale -Requested '' -Saved '' -UiCulture 'xx-YY') -eq 'en-US') 'an unknown language should fall back to English'
    Assert ((Resolve-StartupLocale -Requested 'en-US' -Saved 'fr-FR' -UiCulture 'fr-FR') -eq 'en-US') '-Lang must beat the saved and OS language'
    Assert ((Resolve-StartupLocale -Requested '' -Saved '' -UiCulture 'zh-TW') -notlike 'zh-CN') 'Traditional Chinese must never be served Simplified'
}
[void](Set-BfoLocale -Code $originalLocale)
Update-UiLanguage
Save-Shot 'final'

# =============================================================== summary
Reset-Sandbox
if (Test-Path -LiteralPath $sandboxRoot) { Remove-Item -LiteralPath $sandboxRoot -Recurse -Force }
$failed = @($script:Results | Where-Object { -not $_.Passed })
$summary = New-Object System.Collections.ArrayList
[void]$summary.Add("Brave Free Origin self-test v$($script:AppVersion): $($script:Results.Count - $failed.Count) passed, $($failed.Count) failed, $([int]$sw.Elapsed.TotalSeconds) s")
foreach ($f in $failed) { [void]$summary.Add("  FAIL  $($f.Name)`r`n        $($f.Error)") }
$summary | ForEach-Object { Write-Host $_ }
$script:Results | ForEach-Object { '{0}  {1}  {2} ms{3}' -f $(if ($_.Passed) { 'PASS' } else { 'FAIL' }), $_.Name, $_.Ms, $(if ($_.Error) { "  -- $($_.Error)" } else { '' }) } |
    Set-Content -LiteralPath (Join-Path $script:TestOut 'report.txt') -Encoding UTF8
$form.Close()
if ($failed.Count -gt 0) { $script:SelfTestExit = 1 }
