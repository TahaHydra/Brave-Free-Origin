<#
.SYNOPSIS
    Brave Free Origin - one-line launcher.

.DESCRIPTION
    Run it from any PowerShell window (Windows PowerShell 5.1 or PowerShell 7).
    You do not need to be an administrator to start it:

        irm https://xhydra.fr/bfo | iex

    Nothing here is hidden. In order, this script:

      1. Asks GitHub for the latest Brave Free Origin release
         (github.com/TahaHydra/Brave-Free-Origin), or the one you name.
      2. Downloads Brave-Free-Origin.zip from that release into a private
         folder under %LOCALAPPDATA%\Brave-Free-Origin\run\.
      3. Compares the download with the SHA-256 checksum GitHub publishes for
         that exact file. If they differ, or no checksum can be found, it stops
         and runs nothing.
      4. Unpacks the zip (refusing any entry that would land outside that folder).
      5. Starts the app in a separate Windows PowerShell process with the
         execution policy relaxed for that one process only - your system
         setting is never changed - and asks Windows for administrator
         permission (the UAC prompt) because Brave's policies live in HKLM.
      6. Waits until you close the app, then deletes the unpacked folder.

    Nothing is installed. Your backups, settings and logs stay where the app
    always keeps them (Documents\Brave-Free-Origin-Backups and
    %LOCALAPPDATA%\Brave-Free-Origin).

    Options are read from environment variables, because a piped script cannot
    take parameters. Set them in the same window first:

        $env:BFO_VERSION = 'v2.0'   # a specific release instead of the latest
        $env:BFO_LANG    = 'fr-FR'   # start the app in this language
        $env:BFO_NO_LAUNCH = '1'     # download + verify + unpack only, then print the
                                     # folder so you can read every file before running it
        irm https://xhydra.fr/bfo | iex

    The parameters below exist for testing (tools\Test-Bootstrap.ps1) and for
    people who save the script and run it directly.

.EXAMPLE
    irm https://xhydra.fr/bfo | iex

.EXAMPLE
    $env:BFO_NO_LAUNCH = '1'; irm https://xhydra.fr/bfo | iex
#>
# This file is deliberately pure ASCII and never calls `exit`: it is normally
# run through Invoke-Expression, where `exit` would close the user's window,
# and PowerShell 5.1 decodes a downloaded script with the wrong code page
# unless the server says UTF-8.

function Write-BfoStep {
    param([string]$Text)
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor Cyan
}

function Write-BfoNote {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host "    $Text" -ForegroundColor $Color
}

function Write-BfoLog {
    param([string]$Text)
    try {
        $dir = Join-Path $script:BfoDataDir 'logs'
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $file = Join-Path $dir ('bootstrap-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        [System.IO.File]::AppendAllText($file, ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text) + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# One exception type for "we know exactly what to tell the user".
function New-BfoError {
    param([string]$Message)
    $ex = New-Object System.InvalidOperationException($Message)
    $ex.Data['Friendly'] = $true
    return $ex
}

function Test-BfoAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-BfoEnvironment {
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
        throw (New-BfoError 'Brave Free Origin is a Windows tool. Run this on the Windows PC where Brave is installed.')
    }
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        throw (New-BfoError ("PowerShell is in '{0}' mode on this PC (usually set by your organization), which does not allow this tool to run." -f $ExecutionContext.SessionState.LanguageMode))
    }
    # A Group Policy execution policy overrides the one-process bypass used to start the app.
    try {
        $blocking = @(Get-ExecutionPolicy -List | Where-Object {
            $_.Scope -in @('MachinePolicy', 'UserPolicy') -and $_.ExecutionPolicy -in @('Restricted', 'AllSigned')
        })
        if ($blocking.Count -gt 0) {
            throw (New-BfoError 'A Group Policy on this PC only allows signed PowerShell scripts, and Brave Free Origin is not signed. Ask your administrator, or use a PC you manage.')
        }
    } catch [System.InvalidOperationException] { throw } catch { }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
}

function Get-BfoReleaseInfo {
    param([string]$Repo, [string]$ApiBase, [string]$Version)

    $route = if ($Version) {
        $tag = $Version.Trim()
        if ($tag -notmatch '^[vV]?\d+(\.\d+){1,3}([-.][0-9A-Za-z.]+)?$') {
            throw (New-BfoError "'$Version' is not a version like v2.0.")
        }
        if ($tag -notmatch '^[vV]') { $tag = "v$tag" }
        "releases/tags/$tag"
    } else {
        'releases/latest'
    }
    $uri = '{0}/repos/{1}/{2}' -f $ApiBase.TrimEnd('/'), $Repo, $route
    Write-BfoLog "GET $uri"

    try {
        $release = Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 30 -Headers @{
            'User-Agent' = 'BraveFreeOrigin-Bootstrap'
            'Accept'     = 'application/vnd.github+json'
        }
    } catch {
        $code = $null
        try { $code = [int]$_.Exception.Response.StatusCode } catch { }
        if ($code -eq 404) { throw (New-BfoError ("GitHub has no release '{0}' for {1}. Check the version, or leave BFO_VERSION unset for the latest." -f $(if ($Version) { $Version } else { 'latest' }), $Repo)) }
        if ($code -eq 403 -or $code -eq 429) { throw (New-BfoError 'GitHub is limiting requests from this network right now. Wait a few minutes and try again, or download the zip from the Releases page by hand.') }
        throw (New-BfoError ("Could not reach GitHub ({0}). Check your internet connection, proxy or firewall and try again." -f $_.Exception.Message))
    }

    $asset = @($release.assets | Where-Object { $_.name -eq 'Brave-Free-Origin.zip' }) | Select-Object -First 1
    if (-not $asset) {
        throw (New-BfoError ("Release {0} has no Brave-Free-Origin.zip attached." -f $release.tag_name))
    }
    return [pscustomobject]@{ Tag = [string]$release.tag_name; Asset = $asset }
}

# The SHA-256 GitHub itself computed for the asset ("sha256:<hex>"). Returns
# $null when the release predates that field.
function Get-BfoExpectedHash {
    param($Asset)
    $digest = ''
    if ($Asset.PSObject.Properties.Name -contains 'digest') { $digest = [string]$Asset.digest }
    if ($digest -match '^sha256:([0-9a-fA-F]{64})$') { return $Matches[1].ToLowerInvariant() }
    return $null
}

function Save-BfoAsset {
    param($Asset, [string]$Repo, [string]$ApiBase, [string]$Destination)

    $url = [string]$Asset.browser_download_url
    $official = "https://github.com/$Repo/releases/download/"
    $isTest   = ($ApiBase -notlike 'https://api.github.com*')
    if (-not $url.StartsWith($official, [StringComparison]::Ordinal) -and -not $isTest) {
        throw (New-BfoError "Refusing to download from an unexpected address: $url")
    }
    if ([int64]$Asset.size -gt 50MB -or [int64]$Asset.size -le 0) {
        throw (New-BfoError ("The release file has an unexpected size ({0} bytes)." -f $Asset.size))
    }

    Write-BfoLog "Download $url"
    $previous = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'      # the 5.1 progress bar makes downloads many times slower
    try {
        Invoke-WebRequest -Uri $url -OutFile $Destination -UseBasicParsing -TimeoutSec 120 -Headers @{ 'User-Agent' = 'BraveFreeOrigin-Bootstrap' }
    } catch {
        throw (New-BfoError ("The download failed ({0}). Check your connection and try again." -f $_.Exception.Message))
    } finally {
        $ProgressPreference = $previous
    }
}

function Expand-BfoZip {
    param([string]$ZipPath, [string]$Destination)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    $zip  = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $zip.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }            # a folder entry
            $target = [System.IO.Path]::GetFullPath((Join-Path $Destination ($entry.FullName -replace '/', '\')))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                throw (New-BfoError ("The zip contains an unsafe path ({0}); nothing was run." -f $entry.FullName))
            }
            $parent = [System.IO.Path]::GetDirectoryName($target)
            if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally {
        $zip.Dispose()
    }
}

function Remove-BfoFolder {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    for ($i = 0; $i -lt 5; $i++) {
        try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return } catch { Start-Sleep -Milliseconds 400 }
    }
    Write-BfoLog "Could not remove $Path"
}

function Start-BfoApp {
    param([string]$ScriptPath, [string]$SettingsPath, [string]$Lang, [scriptblock]$LaunchHook)

    $argList = @(
        '-NoLogo', '-NoProfile'
        '-ExecutionPolicy', 'Bypass'                    # this process only - the system policy is untouched
        '-WindowStyle', 'Hidden'                        # the GUI is the only window the user needs
        '-File', ('"{0}"' -f $ScriptPath)
        '-BfoSettingsPath', ('"{0}"' -f $SettingsPath)  # keep the user's own settings even if another admin account approves UAC
    )
    if ($Lang) { $argList += @('-Lang', ('"{0}"' -f $Lang)) }

    if ($LaunchHook) { return (& $LaunchHook $argList) }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
    $splat = @{ FilePath = $psExe; ArgumentList = $argList; WindowStyle = 'Hidden'; PassThru = $true; Wait = $true; ErrorAction = 'Stop' }
    if (-not (Test-BfoAdministrator)) { $splat['Verb'] = 'RunAs' }
    $process = Start-Process @splat
    return [int]$process.ExitCode
}

function Invoke-BfoBootstrap {
    [CmdletBinding()]
    param(
        [string]$Version = $env:BFO_VERSION,
        [string]$Lang    = $env:BFO_LANG,
        [switch]$NoLaunch,

        # test hooks (tools\Test-Bootstrap.ps1). BFO_API_BASE is honoured only for a
        # loopback address, so it can never point the download at another machine.
        [string]$Repo    = 'TahaHydra/Brave-Free-Origin',
        [string]$ApiBase = $(if ($env:BFO_API_BASE -match '^http://(127\.0\.0\.1|localhost):\d{2,5}$') { $env:BFO_API_BASE } else { 'https://api.github.com' }),
        [string]$WorkRoot,
        [scriptblock]$LaunchHook
    )
    $ErrorActionPreference = 'Stop'
    $noLaunchNow = $NoLaunch.IsPresent -or ($env:BFO_NO_LAUNCH -in @('1', 'true', 'yes'))

    $localApp = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [System.IO.Path]::GetTempPath() }
    $script:BfoDataDir = Join-Path $localApp 'Brave-Free-Origin'
    if (-not $WorkRoot) { $WorkRoot = Join-Path $script:BfoDataDir 'run' }
    $settingsPath = Join-Path $script:BfoDataDir 'settings.json'

    Write-Host ''
    Write-Host '  Brave Free Origin' -ForegroundColor White
    Write-Host '  Turn off the extras you do not want in Brave. Every change is reversible.' -ForegroundColor DarkGray

    $runDir = $null
    $exit   = 0
    try {
        Assert-BfoEnvironment

        Write-BfoStep '1/4  Looking up the release on GitHub...'
        $info = Get-BfoReleaseInfo -Repo $Repo -ApiBase $ApiBase -Version $Version
        Write-BfoNote ("Brave Free Origin {0}" -f $info.Tag)

        $expected = Get-BfoExpectedHash $info.Asset
        if (-not $expected) {
            throw (New-BfoError ("GitHub does not publish a checksum for {0}, so the download could not be verified and was not run. Download the zip from the Releases page and check it by hand." -f $info.Tag))
        }

        if (-not (Test-Path -LiteralPath $WorkRoot)) { [void](New-Item -ItemType Directory -Path $WorkRoot -Force) }
        # Leftovers from a run that was killed (power cut, closed window).
        Get-ChildItem -LiteralPath $WorkRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
            ForEach-Object { Remove-BfoFolder $_.FullName }

        $runDir = Join-Path $WorkRoot ([guid]::NewGuid().ToString('N').Substring(0, 12))
        [void](New-Item -ItemType Directory -Path $runDir -Force)
        $zipPath = Join-Path $runDir 'Brave-Free-Origin.zip'

        Write-BfoStep '2/4  Downloading...'
        Save-BfoAsset -Asset $info.Asset -Repo $Repo -ApiBase $ApiBase -Destination $zipPath
        Write-BfoNote ("{0:N0} KB" -f ((Get-Item -LiteralPath $zipPath).Length / 1KB))

        Write-BfoStep '3/4  Checking the download against GitHub''s checksum...'
        $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        Write-BfoLog "sha256 expected=$expected actual=$actual"
        if ($actual -ne $expected) {
            throw (New-BfoError 'The downloaded file does not match the checksum GitHub published for it, so it was deleted and NOT run. Try again; if it keeps happening, your network may be altering downloads.')
        }
        Write-BfoNote 'Matches.' 'Green'

        $appDir = Join-Path $runDir 'app'
        Expand-BfoZip -ZipPath $zipPath -Destination $appDir
        $scriptPath = Join-Path $appDir 'Brave-Free-Origin.ps1'
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            throw (New-BfoError 'The release zip does not contain Brave-Free-Origin.ps1.')
        }
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

        if ($noLaunchNow) {
            Write-BfoStep 'Done - not started, as requested.'
            Write-BfoNote "Files are in: $appDir"
            Write-BfoNote 'Read them, then start with:  Brave-Free-Origin.bat  (or delete the folder when finished).'
            $global:BfoLastFolder = $appDir
            $runDir = $null                                   # keep the files
            return 0
        }

        Write-BfoStep '4/4  Starting Brave Free Origin...'
        Write-BfoNote 'Windows will now ask for administrator permission. Choose Yes to continue.' 'Yellow'
        Write-BfoNote 'Close the Brave Free Origin window when you are done; this window then cleans up.'
        try {
            $exit = Start-BfoApp -ScriptPath $scriptPath -SettingsPath $settingsPath -Lang $Lang -LaunchHook $LaunchHook
        } catch {
            $win32 = $null
            for ($e = $_.Exception; $e; $e = $e.InnerException) { if ($e -is [System.ComponentModel.Win32Exception]) { $win32 = $e; break } }
            if ($win32 -and $win32.NativeErrorCode -eq 1223) {
                Write-BfoLog 'UAC prompt declined'
                Write-Host ''
                Write-Host '  You chose No on the Windows permission prompt, so nothing was started and nothing was changed.' -ForegroundColor Yellow
                Write-BfoNote 'Run the command again and choose Yes when you are ready.'
                return 2
            }
            throw
        }
        Write-BfoLog "App exited with code $exit"
        if ($exit -eq 2) {
            Write-Host ''
            Write-Host '  Administrator permission was not granted, so nothing was changed.' -ForegroundColor Yellow
        } elseif ($exit -ne 0) {
            Write-Host ''
            Write-Host ("  Brave Free Origin closed with an error (code {0})." -f $exit) -ForegroundColor Yellow
            Write-BfoNote ("Details: {0}" -f (Join-Path $script:BfoDataDir 'logs'))
        } else {
            Write-Host ''
            Write-Host '  Finished. Nothing was installed; the temporary files are being removed.' -ForegroundColor Green
        }
        return $exit
    } catch {
        $friendly = $false
        try { $friendly = [bool]$_.Exception.Data['Friendly'] } catch { }
        Write-BfoLog ("ERROR: {0}" -f $_.Exception.ToString())
        Write-Host ''
        if ($friendly) {
            Write-Host ("  {0}" -f $_.Exception.Message) -ForegroundColor Red
        } else {
            Write-Host ("  Something unexpected went wrong: {0}" -f $_.Exception.Message) -ForegroundColor Red
            Write-BfoNote ("Log: {0}" -f (Join-Path $script:BfoDataDir 'logs'))
            Write-BfoNote 'Please report it at https://github.com/TahaHydra/Brave-Free-Origin/issues'
        }
        return 1
    } finally {
        if ($runDir) { Remove-BfoFolder $runDir }
    }
}

# Options come from BFO_* environment variables (a piped script cannot take
# parameters); arguments given when the file is run directly are passed through.
$bfoResult = @(Invoke-BfoBootstrap @args)
$global:LASTEXITCODE = [int]$bfoResult[-1]

# Leave the caller's session as we found it (a piped script runs in the caller's scope).
Remove-Item -Path 'Function:\*-Bfo*' -ErrorAction SilentlyContinue
Remove-Variable -Name bfoResult, BfoDataDir -Scope Script -ErrorAction SilentlyContinue
