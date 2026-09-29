<#
.SYNOPSIS
    Tests install\bfo.ps1 (the one-line launcher behind `irm https://xhydra.fr/bfo | iex`).

.DESCRIPTION
    Runs the real bootstrap script against a fake GitHub served from 127.0.0.1,
    so nothing leaves the machine, no UAC prompt appears and nothing outside a
    temporary folder is touched. The launch step is replaced by a hook that
    records what would have been started.

    Covered: latest / named releases, the launch arguments (one-process
    execution-policy bypass, settings path, language), cleanup after the app
    closes, "download only" mode, and every refusal path - tampered download,
    missing checksum, unsafe zip entry, incomplete zip, unknown release,
    rate limiting, bad version text, declined UAC prompt, app failure.

    Works on Windows PowerShell 5.1 and PowerShell 7.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\Test-Bootstrap.ps1
#>
[CmdletBinding()]
param(
    [string]$BootstrapPath
)

$ErrorActionPreference = 'Stop'
if (-not $BootstrapPath) { $BootstrapPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'install\bfo.ps1' }
$bootstrapFull = (Resolve-Path $BootstrapPath).Path
$bootstrapText = [System.IO.File]::ReadAllText($bootstrapFull)
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('bfo-bootstrap-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $sandbox -Force)
$savedLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = Join-Path $sandbox 'localappdata'      # bootstrap logs land here, not in the real profile
$work = Join-Path $sandbox 'run'

$script:passed = 0
$script:failed = New-Object System.Collections.ArrayList

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        Write-Host "[PASS] $Name"
        $script:passed++
    } catch {
        Write-Host "[FAIL] $Name"
        Write-Host "       $($_.Exception.Message)"
        [void]$script:failed.Add($Name)
    }
}

# ---- test zips ----------------------------------------------------------------
function New-TestZip {
    param([string]$Path, [hashtable]$Entries)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $fs  = [System.IO.File]::Open($Path, 'Create')
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Entries.Keys) {
            $entry  = $zip.CreateEntry($name)
            $stream = $entry.Open()
            $bytes  = [System.Text.Encoding]::UTF8.GetBytes([string]$Entries[$name])
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Dispose()
        }
    } finally { $zip.Dispose(); $fs.Dispose() }
}

$goodEntries = @{
    'Brave-Free-Origin.ps1'  = '# fake app'
    'Brave-Free-Origin.bat'  = '@echo off'
    'locales/en-US.json'     = '{}'
}
$zipGood    = Join-Path $sandbox 'good.zip'
$zipOther   = Join-Path $sandbox 'other.zip'
$zipSlip    = Join-Path $sandbox 'slip.zip'
$zipNoApp   = Join-Path $sandbox 'noapp.zip'
New-TestZip $zipGood  $goodEntries
New-TestZip $zipOther @{ 'Brave-Free-Origin.ps1' = '# something else entirely' }
New-TestZip $zipSlip  @{ 'Brave-Free-Origin.ps1' = '# fake app'; '../evil.txt' = 'should never be written' }
New-TestZip $zipNoApp @{ 'README.md' = 'no script in here' }

function Get-Sha256 { param([string]$Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

# ---- fake GitHub on loopback ---------------------------------------------------
$routes = [hashtable]::Synchronized(@{})
$hits   = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$listener = New-Object System.Net.HttpListener
$port = 0
for ($attempt = 0; $attempt -lt 30 -and $port -eq 0; $attempt++) {
    $candidate = Get-Random -Minimum 20000 -Maximum 60000
    $listener.Prefixes.Clear()
    $listener.Prefixes.Add("http://127.0.0.1:$candidate/")
    try { $listener.Start(); $port = $candidate } catch { }
}
if ($port -eq 0) { throw 'Could not open a loopback port for the fake GitHub.' }
$base = "http://127.0.0.1:$port"

$serverScript = {
    param($listener, $routes, $hits)
    while ($listener.IsListening) {
        try { $ctx = $listener.GetContext() } catch { break }
        try {
            $path = $ctx.Request.Url.AbsolutePath
            [void]$hits.Add($path)
            $route = $routes[$path]
            if (-not $route) { $route = @{ Status = 404; Type = 'application/json'; Body = [System.Text.Encoding]::UTF8.GetBytes('{"message":"Not Found"}') } }
            $ctx.Response.StatusCode  = [int]$route.Status
            $ctx.Response.ContentType = [string]$route.Type
            $ctx.Response.ContentLength64 = $route.Body.Length
            $ctx.Response.OutputStream.Write($route.Body, 0, $route.Body.Length)
        } catch { }
        finally { try { $ctx.Response.Close() } catch { } }
    }
}
$serverPs = [powershell]::Create()
[void]$serverPs.AddScript($serverScript).AddArgument($listener).AddArgument($routes).AddArgument($hits)
$serverHandle = $serverPs.BeginInvoke()

function Add-FileRoute {
    param([string]$Path, [string]$File)
    $routes[$Path] = @{ Status = 200; Type = 'application/zip'; Body = [System.IO.File]::ReadAllBytes($File) }
}
function Add-ReleaseRoute {
    param([string]$Path, [string]$Tag, [string]$AssetFile, [string]$DigestOf, [switch]$NoDigest, [switch]$NoAsset)
    $asset = [ordered]@{
        name                 = 'Brave-Free-Origin.zip'
        size                 = (Get-Item -LiteralPath $AssetFile).Length
        browser_download_url = "$base/dl/$Tag.zip"
    }
    if (-not $NoDigest) { $asset['digest'] = 'sha256:' + (Get-Sha256 $DigestOf) }
    $assets = if ($NoAsset) { @() } else { @($asset) }
    $json = [ordered]@{ tag_name = $Tag; assets = $assets } | ConvertTo-Json -Depth 6
    $routes[$Path] = @{ Status = 200; Type = 'application/json'; Body = [System.Text.UTF8Encoding]::new($false).GetBytes($json) }
    Add-FileRoute "/dl/$Tag.zip" $AssetFile
}

$api = '/repos/TahaHydra/Brave-Free-Origin/releases'
Add-ReleaseRoute "$api/latest"        'v9.9.9' $zipGood  $zipGood
Add-ReleaseRoute "$api/tags/v1.0.1"   'v1.0.1' $zipOther $zipGood                 # download differs from the published checksum
Add-ReleaseRoute "$api/tags/v1.0.2"   'v1.0.2' $zipGood  $zipGood -NoDigest
Add-ReleaseRoute "$api/tags/v1.0.3"   'v1.0.3' $zipSlip  $zipSlip                 # checksum is right, the zip is hostile
Add-ReleaseRoute "$api/tags/v1.0.4"   'v1.0.4' $zipNoApp $zipNoApp
Add-ReleaseRoute "$api/tags/v1.0.7"   'v1.0.7' $zipGood  $zipGood -NoAsset
$routes["$api/tags/v1.0.5"] = @{ Status = 403; Type = 'application/json'; Body = [System.Text.Encoding]::UTF8.GetBytes('{"message":"API rate limit exceeded"}') }

# ---- runner ------------------------------------------------------------------------
$script:launches = New-Object System.Collections.ArrayList
$okHook = {
    param($argList)
    $file = ($argList -join ' ')
    $scriptArg = $argList[($argList.IndexOf('-File') + 1)].Trim('"')
    [void]$script:launches.Add([pscustomobject]@{
        Args = $argList; Line = $file; ScriptExists = (Test-Path -LiteralPath $scriptArg); ScriptPath = $scriptArg
        LocalesExist = (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $scriptArg) 'locales\en-US.json'))
    })
    return 0
}

function Invoke-Bootstrap {
    param([string]$Version, [string]$Lang, [scriptblock]$Hook, [switch]$NoLaunch)
    $script:launches.Clear()
    $sb = [scriptblock]::Create($bootstrapText)
    $global:LASTEXITCODE = -99
    if ($NoLaunch) {
        $out = & $sb -ApiBase $base -WorkRoot $work -Version $Version -Lang $Lang -LaunchHook $Hook -NoLaunch *>&1 | Out-String
    } else {
        $out = & $sb -ApiBase $base -WorkRoot $work -Version $Version -Lang $Lang -LaunchHook $Hook *>&1 | Out-String
    }
    return [pscustomobject]@{ Exit = [int]$global:LASTEXITCODE; Output = $out }
}
function Get-RunFolders { @(Get-ChildItem -LiteralPath $work -Directory -ErrorAction SilentlyContinue) }
function Reset-Work { if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }; $hits.Clear() }

try {
    Test-Case 'the script parses, is pure ASCII and never calls exit' {
        $bytes = [System.IO.File]::ReadAllBytes($bootstrapFull)
        Assert (-not ($bytes | Where-Object { $_ -gt 127 })) 'non-ASCII bytes found'
        Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF)) 'BOM found'
        $errs = $null; $tok = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($bootstrapText, [ref]$tok, [ref]$errs)
        Assert (-not $errs) ('parse errors: ' + ($errs | ForEach-Object Message | Out-String))
        Assert ($bootstrapText -notmatch '(?m)^\s*exit\b') 'the script must not call exit: under iex it would close the window'
    }

    Test-Case 'latest release: downloads, verifies, starts the app once, then cleans up' {
        Reset-Work
        $r = Invoke-Bootstrap -Version '' -Lang '' -Hook $okHook
        Assert ($r.Exit -eq 0) "exit code was $($r.Exit)`n$($r.Output)"
        Assert ($script:launches.Count -eq 1) "launched $($script:launches.Count) times"
        $l = $script:launches[0]
        Assert $l.ScriptExists 'the script was not on disk when the app started'
        Assert $l.LocalesExist 'locales\en-US.json was not unpacked next to the script'
        Assert ($l.Line -match '-ExecutionPolicy Bypass') 'no one-process execution policy bypass'
        Assert ($l.Line -match '-NoProfile') 'profile is not skipped'
        Assert ($l.Line -match '-WindowStyle Hidden') 'the console is not hidden'
        Assert ($l.Line -match '-BfoSettingsPath "[^"]+settings\.json"') 'the settings path is not forwarded'
        Assert ($l.Line -notmatch '-Lang') 'no language was requested but -Lang was passed'
        Assert ((Get-RunFolders).Count -eq 0) 'the unpacked folder was not deleted after the app closed'
        Assert ($r.Output -match 'Matches') 'the checksum result was not shown'
        Assert ($hits -contains "$api/latest") 'the latest release was not requested'
    }

    Test-Case 'a named release and a language are honoured (1.0.1 style versions get a v prefix)' {
        Reset-Work
        Add-ReleaseRoute "$api/tags/v2.0.0" 'v2.0.0' $zipGood $zipGood
        $r = Invoke-Bootstrap -Version '2.0.0' -Lang 'fr-FR' -Hook $okHook
        Assert ($r.Exit -eq 0) "exit code was $($r.Exit)`n$($r.Output)"
        Assert ($hits -contains "$api/tags/v2.0.0") 'the tag was not requested'
        Assert ($script:launches[0].Line -match '-Lang "fr-FR"') 'the language was not forwarded'
    }

    Test-Case 'download-only mode keeps the files, starts nothing and prints where they are' {
        Reset-Work
        $r = Invoke-Bootstrap -Version '' -Lang '' -Hook $okHook -NoLaunch
        Assert ($r.Exit -eq 0) "exit code was $($r.Exit)`n$($r.Output)"
        Assert ($script:launches.Count -eq 0) 'the app was started in download-only mode'
        $folder = $global:BfoLastFolder
        Assert ($folder -and (Test-Path -LiteralPath (Join-Path $folder 'Brave-Free-Origin.ps1'))) 'the unpacked script is not where it was reported'
        Assert (-not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $folder) 'Brave-Free-Origin.zip'))) 'the zip should be removed once unpacked'
        Assert ($r.Output.Contains($folder)) 'the folder was not printed'
        Remove-Variable -Name BfoLastFolder -Scope Global -ErrorAction SilentlyContinue
    }

    Test-Case 'a download that differs from the published checksum is refused, deleted and never run' {
        Reset-Work
        $r = Invoke-Bootstrap -Version 'v1.0.1' -Lang '' -Hook $okHook
        Assert ($r.Exit -eq 1) "exit code was $($r.Exit)"
        Assert ($script:launches.Count -eq 0) 'a tampered download was launched'
        Assert ($r.Output -match 'does not match') "message was: $($r.Output)"
        Assert ((Get-RunFolders).Count -eq 0) 'the folder with the bad download was not removed'
    }

    Test-Case 'a release without a published checksum is refused before anything is downloaded' {
        Reset-Work
        $r = Invoke-Bootstrap -Version 'v1.0.2' -Lang '' -Hook $okHook
        Assert ($r.Exit -eq 1) "exit code was $($r.Exit)"
        Assert ($script:launches.Count -eq 0) 'an unverifiable release was launched'
        Assert ($r.Output -match 'checksum') "message was: $($r.Output)"
        Assert (-not ($hits -contains '/dl/v1.0.2.zip')) 'the file was downloaded although it could not be verified'
    }

    Test-Case 'a zip entry that would escape the folder is refused and nothing is written outside' {
        Reset-Work
        $r = Invoke-Bootstrap -Version 'v1.0.3' -Lang '' -Hook $okHook
        Assert ($r.Exit -eq 1) "exit code was $($r.Exit)"
        Assert ($script:launches.Count -eq 0) 'a hostile zip was launched'
        Assert ($r.Output -match 'unsafe path') "message was: $($r.Output)"
        Assert (-not (Test-Path -LiteralPath (Join-Path $work 'evil.txt'))) 'a file escaped into the work folder'
        Assert (-not (Test-Path -LiteralPath (Join-Path $sandbox 'evil.txt'))) 'a file escaped above the work folder'
        Assert ((Get-RunFolders).Count -eq 0) 'the folder was not cleaned up'
    }

    Test-Case 'a zip without the app script is refused with a clear message' {
        Reset-Work
        $r = Invoke-Bootstrap -Version 'v1.0.4' -Lang '' -Hook $okHook
        Assert ($r.Exit -eq 1) "exit code was $($r.Exit)"
        Assert ($r.Output -match 'does not contain Brave-Free-Origin\.ps1') "message was: $($r.Output)"
        Assert ($script:launches.Count -eq 0) 'launched anyway'
    }

    Test-Case 'a release with no zip attached, an unknown release and rate limiting each get a plain explanation' {
        Reset-Work
        $r = Invoke-Bootstrap -Version 'v1.0.7' -Lang '' -Hook $okHook
        Assert ($r.Exit -eq 1 -and $r.Output -match 'no Brave-Free-Origin\.zip') "no-asset message was: $($r.Output)"
        $r = Invoke-Bootstrap -Version 'v3.3.3' -Lang '' -Hook $okHook
        Assert ($r.Exit -eq 1 -and $r.Output -match 'no release') "404 message was: $($r.Output)"
        $r = Invoke-Bootstrap -Version 'v1.0.5' -Lang '' -Hook $okHook
        Assert ($r.Exit -eq 1 -and $r.Output -match 'limiting requests') "403 message was: $($r.Output)"
        Assert ($script:launches.Count -eq 0) 'launched after an error'
    }

    Test-Case 'version text that is not a version is rejected without any web request' {
        Reset-Work
        $before = $hits.Count
        $r = Invoke-Bootstrap -Version '1.13; calc' -Lang '' -Hook $okHook
        Assert ($r.Exit -eq 1 -and $r.Output -match 'not a version') "message was: $($r.Output)"
        Assert ($hits.Count -eq $before) 'a request was made for an invalid version'
    }

    Test-Case 'declining the UAC prompt is explained, exits 2 and still cleans up' {
        Reset-Work
        $declineHook = { param($argList) throw (New-Object System.ComponentModel.Win32Exception(1223, 'The operation was canceled by the user')) }
        $r = Invoke-Bootstrap -Version '' -Lang '' -Hook $declineHook
        Assert ($r.Exit -eq 2) "exit code was $($r.Exit)`n$($r.Output)"
        Assert ($r.Output -match 'chose No') "message was: $($r.Output)"
        Assert ((Get-RunFolders).Count -eq 0) 'the folder was left behind'
    }

    Test-Case 'an app that exits with an error is reported and the folder is still removed' {
        Reset-Work
        $failHook = { param($argList) return 1 }
        $r = Invoke-Bootstrap -Version '' -Lang '' -Hook $failHook
        Assert ($r.Exit -eq 1) "exit code was $($r.Exit)"
        Assert ($r.Output -match 'closed with an error') "message was: $($r.Output)"
        Assert ((Get-RunFolders).Count -eq 0) 'the folder was left behind'
    }

    Test-Case 'a crash inside the launcher is caught, logged and cleaned up' {
        Reset-Work
        $boomHook = { param($argList) throw 'boom from the launcher' }
        $r = Invoke-Bootstrap -Version '' -Lang '' -Hook $boomHook
        Assert ($r.Exit -eq 1) "exit code was $($r.Exit)"
        Assert ($r.Output -match 'unexpected') "message was: $($r.Output)"
        Assert ((Get-RunFolders).Count -eq 0) 'the folder was left behind'
        $log = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Brave-Free-Origin\logs') -Filter 'bootstrap-*.log' -ErrorAction SilentlyContinue | Select-Object -First 1
        Assert ($log -and ((Get-Content -LiteralPath $log.FullName -Raw) -match 'boom from the launcher')) 'the error was not written to the bootstrap log'
    }

    Test-Case 'folders left by a killed run are swept, recent ones are kept' {
        Reset-Work
        $old = Join-Path $work 'old000000000'; $new = Join-Path $work 'new000000000'
        [void](New-Item -ItemType Directory -Path $old -Force); [void](New-Item -ItemType Directory -Path $new -Force)
        (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-3)
        $r = Invoke-Bootstrap -Version '' -Lang '' -Hook $okHook
        Assert ($r.Exit -eq 0) "exit code was $($r.Exit)"
        Assert (-not (Test-Path -LiteralPath $old)) 'the stale folder was not removed'
        Assert (Test-Path -LiteralPath $new) 'a recent folder (maybe another running instance) was removed'
    }

    Test-Case 'the real `irm | iex` shape works: options come from environment variables and nothing leaks into the session' {
        Reset-Work
        # A child PowerShell evaluates the text with Invoke-Expression exactly as `irm | iex` does: no
        # arguments at all, so the fake server and the download-only switch arrive through BFO_* variables.
        $childScript = Join-Path $sandbox 'child.ps1'
        $q = { param($v) "'" + $v.Replace("'", "''") + "'" }
        $lines = @(
            ('$text = [System.IO.File]::ReadAllText({0})' -f (& $q $bootstrapFull)),
            "Invoke-Expression `$text",
            "'LEAK=' + @(Get-Command -Name '*-Bfo*' -CommandType Function -ErrorAction SilentlyContinue).Count",
            "'EXIT=' + `$LASTEXITCODE"
        )
        Set-Content -LiteralPath $childScript -Value $lines -Encoding ASCII
        $env:BFO_NO_LAUNCH = '1'
        $env:BFO_API_BASE  = $base
        try { $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $childScript 2>&1 | Out-String) }
        finally {
            Remove-Item -LiteralPath Env:\BFO_NO_LAUNCH -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath Env:\BFO_API_BASE  -ErrorAction SilentlyContinue
        }
        Assert ($out -match 'EXIT=0') "child output was:`n$out"
        Assert ($out -match 'LEAK=0') "helper functions leaked into the session:`n$out"
        Assert ($out -match 'not started, as requested') "BFO_NO_LAUNCH was ignored:`n$out"
        Assert ($hits -contains "$api/latest") 'BFO_API_BASE was ignored: the fake GitHub was never asked'
        $defaultRun = Join-Path $env:LOCALAPPDATA 'Brave-Free-Origin\run'
        $kept = @(Get-ChildItem -LiteralPath $defaultRun -Recurse -Filter 'Brave-Free-Origin.ps1' -ErrorAction SilentlyContinue)
        Assert ($kept.Count -eq 1) "download-only mode should leave exactly one unpacked copy, found $($kept.Count)"
    }

    Test-Case 'BFO_API_BASE is ignored unless it is a loopback address' {
        Reset-Work
        $childScript = Join-Path $sandbox 'child2.ps1'
        $q = { param($v) "'" + $v.Replace("'", "''") + "'" }
        $lines = @(
            ('$text = [System.IO.File]::ReadAllText({0})' -f (& $q $bootstrapFull)),
            "Invoke-Expression `$text"
        )
        Set-Content -LiteralPath $childScript -Value $lines -Encoding ASCII
        $before = $hits.Count
        $env:BFO_NO_LAUNCH = '1'
        $env:BFO_API_BASE  = 'http://192.0.2.1:9'          # TEST-NET address: a remote host, must never be used
        $env:BFO_VERSION   = 'v0.0.1'
        try { $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $childScript 2>&1 | Out-String) }
        finally {
            foreach ($n in 'BFO_NO_LAUNCH', 'BFO_API_BASE', 'BFO_VERSION') { Remove-Item -LiteralPath "Env:\$n" -ErrorAction SilentlyContinue }
        }
        Assert ($hits.Count -eq $before) 'the fake server should not have been contacted'
        Assert ($out -notmatch '192\.0\.2\.1') "the remote address was used:`n$out"
        # It fell back to api.github.com, which either answers 404 for the made-up tag or is unreachable: both are fine.
        Assert ($out -match 'no release|Could not reach GitHub|limiting requests') "unexpected output:`n$out"
    }
} finally {
    try { $listener.Stop(); $listener.Close() } catch { }
    try { $serverPs.Stop(); $serverPs.Dispose() } catch { }
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("Bootstrap self-test: {0} passed, {1} failed" -f $script:passed, $script:failed.Count)
if ($script:failed.Count -gt 0) { exit 1 }
