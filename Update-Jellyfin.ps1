#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Automatically updates Jellyfin Server to the latest stable release.

.DESCRIPTION
    Robust Jellyfin updater designed for unattended Task Scheduler execution.
    Uses the portable ZIP from repo.jellyfin.org -- never touches service registration,
    so custom service accounts, start modes, and recovery settings are always preserved.

    Features:
    - Version comparison via GitHub releases API + repo.jellyfin.org portable ZIP
    - Full installation backup with automatic rollback on failure
    - Graceful service stop with escalation to forced kill
    - Post-update health check (service state + HTTP probe)
    - Comprehensive timestamped logging with rotation
    - Lock file to prevent concurrent runs
    - Disk space pre-flight check

.PARAMETER InstallPath
    Path to the Jellyfin Server installation directory.

.PARAMETER ServiceName
    Name of the Jellyfin Windows service.

.PARAMETER LogDirectory
    Directory for log files. Created if it does not exist.

.PARAMETER HealthCheckUrl
    URL to probe after update to verify Jellyfin is responding.

.PARAMETER HealthCheckTimeoutSeconds
    Maximum seconds to wait for Jellyfin to respond after update.

.PARAMETER ServiceStopTimeoutSeconds
    Maximum seconds to wait for the service to stop gracefully.

.PARAMETER MaxBackups
    Number of installation backups to retain. Oldest are pruned.

.PARAMETER MaxLogFiles
    Number of log files to retain. Oldest are pruned.

.PARAMETER Force
    Force update even if versions match.

.PARAMETER PushoverUserKey
    Pushover user/group key for notifications. If omitted, no notifications are sent.

.PARAMETER PushoverApiToken
    Pushover application API token.

.PARAMETER PushoverDevice
    Optional Pushover device name to target. If omitted, all devices receive the notification.

.EXAMPLE
    .\Update-Jellyfin.ps1
    Runs with default settings.

.EXAMPLE
    .\Update-Jellyfin.ps1 -Force -Verbose
    Forces a reinstall of the latest version with verbose output.

.NOTES
    SERVICE SETUP (one-time):
    This script does NOT register a Windows service -- that is your responsibility.
    If migrating from the NSIS installer, re-register the service manually:

      sc.exe create JellyfinServer `
          binPath= '"C:\Program Files\Jellyfin\Server\jellyfin.exe" --service --datadir "C:\ProgramData\Jellyfin\Server"' `
          obj= "sa-Jellyfin@home.lan" `
          password= "YourPassword" `
          start= delayed-auto

      sc.exe description JellyfinServer "Jellyfin Media Server"
      sc.exe failure JellyfinServer reset= 86400 actions= restart/30000/restart/60000/restart/120000

    TASK SCHEDULER:
      Program:   powershell.exe
      Arguments: -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Scripts\Update-Jellyfin.ps1"
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Parameters are used by nested functions via parent scope')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
    Justification = 'Script is designed for unattended non-interactive execution')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', 'Test-PreFlightChecks',
    Justification = 'Name reflects that multiple checks are performed')]
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$InstallPath = "${env:ProgramFiles}\Jellyfin\Server",

    [ValidateNotNullOrEmpty()]
    [string]$ServiceName = 'JellyfinServer',

    [ValidateNotNullOrEmpty()]
    [string]$LogDirectory = "${env:ProgramData}\Jellyfin\UpdateLogs",

    [ValidateNotNullOrEmpty()]
    [string]$HealthCheckUrl = 'http://localhost:8096/health',

    [ValidateRange(30, 600)]
    [int]$HealthCheckTimeoutSeconds = 120,

    [ValidateRange(10, 300)]
    [int]$ServiceStopTimeoutSeconds = 60,

    [ValidateRange(1, 20)]
    [int]$MaxBackups = 3,

    [ValidateRange(1, 100)]
    [int]$MaxLogFiles = 30,

    [switch]$Force,

    [string]$PushoverUserKey,

    [string]$PushoverApiToken,

    [string]$PushoverDevice
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Force TLS 1.2 for GitHub API and repo.jellyfin.org
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

#region -- Constants ----------------------------------------------------------

$Script:GitHubApiUrl     = 'https://api.github.com/repos/jellyfin/jellyfin/releases/latest'
$Script:RepoBaseUrl      = 'https://repo.jellyfin.org/files/server/windows'
$Script:BackupRoot       = Join-Path $env:ProgramData 'Jellyfin\UpdateBackups'
$Script:LockFile         = Join-Path $env:ProgramData 'Jellyfin\update.lock'
$Script:MinDiskSpaceGB   = 2
$Script:MinZipSizeMB     = 50    # Sanity check: real ZIP is ~160MB
$Script:UserAgent        = 'Jellyfin-AutoUpdater/1.0 (PowerShell)'

# Exit codes for Task Scheduler visibility
enum ExitCode {
    Success            = 0
    AlreadyUpToDate    = 0
    ConcurrentRun      = 1
    PreFlightFailed    = 2
    DownloadFailed     = 3
    ServiceStopFailed  = 5
    InstallFailed      = 6
    RollbackPerformed  = 7
    HealthCheckFailed  = 8
    UnhandledError     = 99
}

#endregion

#region -- Logging ------------------------------------------------------------

function Initialize-Logging {
    if (-not (Test-Path $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $Script:LogFile = Join-Path $LogDirectory "JellyfinUpdate_$timestamp.log"

    # Rotate old logs
    Get-ChildItem -Path $LogDirectory -Filter '*.log' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $MaxLogFiles |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-UpdateLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $entry = "[$timestamp] [$Level] $Message"

    Add-Content -Path $Script:LogFile -Value $entry -Encoding UTF8

    switch ($Level) {
        'ERROR'   { Write-Error   $Message -ErrorAction Continue }
        'WARN'    { Write-Warning $Message }
        'SUCCESS' { Write-Information $entry -InformationAction Continue }
        default   { Write-Verbose $entry }
    }
}

#endregion

#region -- Pushover Notifications ---------------------------------------------

function Send-PushoverNotification {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Success', 'Rollback', 'Failed', 'Info')]
        [string]$Type,

        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Url,
        [string]$UrlTitle
    )

    if (-not $PushoverUserKey -or -not $PushoverApiToken) {
        return
    }

    # Priority: -2 lowest, -1 low, 0 normal, 1 high, 2 emergency
    $priorityMap = @{
        'Success'  = 0
        'Info'     = -1
        'Rollback' = 1
        'Failed'   = 1
    }

    # Sound: https://pushover.net/api#sounds
    $soundMap = @{
        'Success'  = 'none'
        'Info'     = 'none'
        'Rollback' = 'none'
        'Failed'   = 'none'
    }

    $body = @{
        token    = $PushoverApiToken
        user     = $PushoverUserKey
        title    = $Title
        message  = $Message
        html     = 1
        priority = $priorityMap[$Type]
        sound    = $soundMap[$Type]
    }

    if ($PushoverDevice) {
        $body['device'] = $PushoverDevice
    }

    if ($Url) {
        $body['url'] = $Url
        if ($UrlTitle) {
            $body['url_title'] = $UrlTitle
        }
    }

    try {
        $null = Invoke-RestMethod -Uri 'https://api.pushover.net/1/messages.json' `
            -Method Post -Body $body -TimeoutSec 15 -ErrorAction Stop
        Write-UpdateLog "Pushover notification sent: $Type" -Level INFO
    }
    catch {
        # Non-fatal: log but do not fail the update
        Write-UpdateLog "Pushover notification failed: $_" -Level WARN
    }
}

#endregion

#region -- Lock File ----------------------------------------------------------

function Enter-UpdateLock {
    $lockDir = Split-Path $Script:LockFile -Parent
    if (-not (Test-Path $lockDir)) {
        New-Item -Path $lockDir -ItemType Directory -Force | Out-Null
    }

    # Handle stale lock before attempting atomic create
    if (Test-Path $Script:LockFile) {
        $lockContent = Get-Content $Script:LockFile -Raw -ErrorAction SilentlyContinue
        $lockAge = (Get-Date) - (Get-Item $Script:LockFile).LastWriteTime

        if ($lockAge.TotalMinutes -gt 30) {
            Write-UpdateLog "Removing stale lock file (age: $($lockAge.TotalMinutes.ToString('F0')) min, PID: $lockContent)" -Level WARN
            Remove-Item $Script:LockFile -Force
        }
        else {
            Write-UpdateLog "Another update is already running (lock age: $($lockAge.TotalMinutes.ToString('F1')) min, PID: $lockContent)" -Level ERROR
            return $false
        }
    }

    # Atomic lock acquisition — CreateNew fails if file was created between check and here
    try {
        $stream = [System.IO.File]::Open($Script:LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $writer = [System.IO.StreamWriter]::new($stream)
            $writer.Write($PID)
            $writer.Flush()
        }
        finally {
            if ($writer) { $writer.Dispose() }
            $stream.Dispose()
        }
        Write-UpdateLog "Acquired update lock (PID: $PID)"
        return $true
    }
    catch [System.IO.IOException] {
        Write-UpdateLog "Another update acquired the lock before us (race condition avoided)" -Level ERROR
        return $false
    }
}

function Exit-UpdateLock {
    if (Test-Path $Script:LockFile) {
        Remove-Item $Script:LockFile -Force -ErrorAction SilentlyContinue
        Write-UpdateLog 'Released update lock'
    }
}

#endregion

#region -- Pre-Flight Checks --------------------------------------------------

function Test-PreFlightChecks {
    Write-UpdateLog '-- Pre-flight checks --'

    # 1. Service exists
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-UpdateLog "Service '$ServiceName' not found. Available Jellyfin-like services: $(
            (Get-Service | Where-Object Name -like '*jellyfin*').Name -join ', '
        )" -Level ERROR
        return $false
    }
    Write-UpdateLog "Service '$ServiceName' found (Status: $($service.Status))"

    # 2. Install path exists
    if (-not (Test-Path $InstallPath)) {
        Write-UpdateLog "Install path not found: $InstallPath" -Level ERROR
        return $false
    }
    Write-UpdateLog "Install path verified: $InstallPath"

    # 3. Disk space on system drive
    $systemDrive = $env:SystemDrive
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$systemDrive'" -ErrorAction SilentlyContinue
    if (-not $disk) {
        Write-UpdateLog "Could not query disk space for $systemDrive" -Level ERROR
        return $false
    }
    $freeSpaceGB = [math]::Round($disk.FreeSpace / 1GB, 2)
    if ($freeSpaceGB -lt $Script:MinDiskSpaceGB) {
        Write-UpdateLog "Insufficient disk space on $systemDrive : ${freeSpaceGB}GB free, need ${Script:MinDiskSpaceGB}GB" -Level ERROR
        return $false
    }
    Write-UpdateLog "Disk space OK: ${freeSpaceGB}GB free on $systemDrive"

    # 4. Internet connectivity
    foreach ($hostname in @('api.github.com', 'repo.jellyfin.org')) {
        try {
            $null = [System.Net.Dns]::GetHostAddresses($hostname)
            Write-UpdateLog "DNS resolution for $hostname OK"
        }
        catch {
            Write-UpdateLog "Cannot resolve $hostname -- no internet? Error: $_" -Level ERROR
            return $false
        }
    }

    return $true
}

#endregion

#region -- Version Detection --------------------------------------------------

function Get-InstalledVersion {
    # Primary: read from the DLL or EXE
    foreach ($binary in @('jellyfin.dll', 'jellyfin.exe')) {
        $path = Join-Path $InstallPath $binary
        if (Test-Path $path) {
            try {
                $version = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($path).ProductVersion
                if ($version) {
                    $clean = ($version -split '\+')[0]
                    Write-UpdateLog "Installed version from ${binary}: $clean"
                    return $clean
                }
            }
            catch {
                Write-UpdateLog "Could not read version from ${binary}: $_" -Level WARN
            }
        }
    }

    # Fallback: system.xml
    $systemXml = Join-Path $env:ProgramData 'Jellyfin\Server\config\system.xml'
    if (Test-Path $systemXml) {
        try {
            $xml = [xml](Get-Content $systemXml -Raw)
            $version = $xml.ServerConfiguration.ServerVersion
            if ($version) {
                Write-UpdateLog "Installed version from system.xml: $version"
                return $version
            }
        }
        catch {
            Write-UpdateLog "Could not parse system.xml: $_" -Level WARN
        }
    }

    Write-UpdateLog 'Could not determine installed version from any source' -Level WARN
    return $null
}

function Get-LatestRelease {
    Write-UpdateLog 'Querying GitHub releases API (jellyfin/jellyfin)...'

    $headers = @{
        'Accept'     = 'application/vnd.github+json'
        'User-Agent' = $Script:UserAgent
    }

    $maxRetries = 3
    $release = $null

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $release = Invoke-RestMethod -Uri $Script:GitHubApiUrl -Headers $headers -TimeoutSec 30
            break
        }
        catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            Write-UpdateLog "GitHub API attempt $attempt/$maxRetries failed (HTTP $statusCode): $_" -Level WARN

            if ($attempt -lt $maxRetries) {
                $backoff = $attempt * 5
                Write-UpdateLog "Retrying in ${backoff}s..."
                Start-Sleep -Seconds $backoff
            }
        }
    }

    if (-not $release) {
        Write-UpdateLog 'Failed to query GitHub releases API after all retries' -Level ERROR
        return $null
    }

    # v10.11.7 -> 10.11.7
    $latestVersion = $release.tag_name -replace '^v', ''
    $zipName = "jellyfin_${latestVersion}-amd64.zip"

    # Construct download URLs -- try versioned path first, then latest-stable symlink
    $primaryUrl  = "$($Script:RepoBaseUrl)/stable/v${latestVersion}/amd64/$zipName"
    $fallbackUrl = "$($Script:RepoBaseUrl)/latest-stable/amd64/$zipName"

    $downloadUrl = $null
    foreach ($candidateUrl in @($primaryUrl, $fallbackUrl)) {
        try {
            Write-UpdateLog "Probing: $candidateUrl"
            $null = Invoke-WebRequest -Uri $candidateUrl -Method Head -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
            $downloadUrl = $candidateUrl
            Write-UpdateLog 'URL reachable'
            break
        }
        catch {
            $httpStatus = $_.Exception.Response.StatusCode.value__
            Write-UpdateLog "Probe failed (HTTP $httpStatus): $candidateUrl" -Level WARN
        }
    }

    if (-not $downloadUrl) {
        Write-UpdateLog "ZIP not found on repo.jellyfin.org for version $latestVersion" -Level ERROR
        return $null
    }

    $result = [PSCustomObject]@{
        Version     = $latestVersion
        Tag         = $release.tag_name
        DownloadUrl = $downloadUrl
        ZipName     = $zipName
        PublishedAt = $release.published_at
    }

    Write-UpdateLog "Latest release: v$($result.Version) published $($result.PublishedAt)"
    Write-UpdateLog "Download URL: $($result.DownloadUrl)"

    return $result
}

#endregion

#region -- Download & Verify --------------------------------------------------

function Get-PortableZip {
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Release
    )

    $tempDir = Join-Path $env:TEMP "JellyfinUpdate_$(Get-Date -Format 'yyyyMMddHHmmss')"
    New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

    $zipPath = Join-Path $tempDir $Release.ZipName

    Write-UpdateLog "Downloading $($Release.ZipName) to $tempDir..."

    $maxRetries = 3
    $downloaded = $false

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            Write-UpdateLog "Download attempt $attempt/$maxRetries via Invoke-WebRequest..."
            $webRequestParams = @{
                Uri             = $Release.DownloadUrl
                OutFile         = $zipPath
                UseBasicParsing = $true
                TimeoutSec      = 300
                Headers         = @{ 'User-Agent' = $Script:UserAgent }
                ErrorAction     = 'Stop'
            }
            Invoke-WebRequest @webRequestParams
            $downloaded = $true
            break
        }
        catch {
            Write-UpdateLog "Invoke-WebRequest attempt $attempt/$maxRetries failed: $_" -Level WARN

            if ($attempt -eq $maxRetries) {
                Write-UpdateLog 'Falling back to BITS transfer...' -Level WARN
                try {
                    Start-BitsTransfer -Source $Release.DownloadUrl -Destination $zipPath -ErrorAction Stop
                    $downloaded = $true
                }
                catch {
                    Write-UpdateLog "BITS transfer also failed: $_" -Level ERROR
                }
            }
            else {
                Start-Sleep -Seconds ($attempt * 5)
            }
        }
    }

    if (-not $downloaded -or -not (Test-Path $zipPath)) {
        Write-UpdateLog 'All download attempts failed' -Level ERROR
        return $null
    }

    # Sanity check: real ZIP is ~160MB
    $sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    if ($sizeMB -lt $Script:MinZipSizeMB) {
        Write-UpdateLog "Downloaded file is suspiciously small: ${sizeMB}MB (expected >${Script:MinZipSizeMB}MB). Likely an error page or truncated download." -Level ERROR
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        return $null
    }

    # Verify it is actually a ZIP (PK header: 0x50 0x4B)
    try {
        $stream = [System.IO.File]::OpenRead($zipPath)
        try {
            $header = New-Object byte[] 4
            $bytesRead = $stream.Read($header, 0, 4)
            if ($bytesRead -lt 4 -or $header[0] -ne 0x50 -or $header[1] -ne 0x4B) {
                Write-UpdateLog 'Downloaded file does not have a valid ZIP header (PK signature missing)' -Level ERROR
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                return $null
            }
            Write-UpdateLog "ZIP header validated, size: ${sizeMB}MB"
        }
        finally {
            $stream.Close()
            $stream.Dispose()
        }
    }
    catch {
        Write-UpdateLog "Could not validate ZIP header: $_" -Level WARN
    }

    return [PSCustomObject]@{
        ZipPath = $zipPath
        TempDir = $tempDir
    }
}

#endregion

#region -- Service Management -------------------------------------------------

function Stop-JellyfinService {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service -or $service.Status -eq 'Stopped') {
        Write-UpdateLog 'Service is already stopped'
        return $true
    }

    Write-UpdateLog "Stopping service '$ServiceName' (current status: $($service.Status))..."

    try {
        Stop-Service -Name $ServiceName -Force -ErrorAction Stop
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($ServiceStopTimeoutSeconds))
        Write-UpdateLog 'Service stopped gracefully' -Level SUCCESS
        return $true
    }
    catch {
        Write-UpdateLog "Graceful stop failed: $_" -Level WARN
    }

    # Escalate: kill the process
    Write-UpdateLog 'Attempting forceful process termination...' -Level WARN

    try {
        $escapedName = $ServiceName.Replace("'", "''")
            $serviceWmi = Get-CimInstance -ClassName Win32_Service -Filter "Name='$escapedName'" -ErrorAction Stop
        if ($serviceWmi.ProcessId -and $serviceWmi.ProcessId -ne 0) {
            $proc = Get-Process -Id $serviceWmi.ProcessId -ErrorAction SilentlyContinue
            if ($proc) {
                Write-UpdateLog "Killing process $($proc.Id) ($($proc.ProcessName))"
                $proc | Stop-Process -Force
                Start-Sleep -Seconds 3
            }
        }
    }
    catch {
        Write-UpdateLog "Could not kill via WMI PID lookup: $_" -Level WARN
    }

    # Kill any lingering jellyfin processes
    Get-Process -Name 'jellyfin*' -ErrorAction SilentlyContinue | ForEach-Object {
        Write-UpdateLog "Killing lingering process: $($_.ProcessName) (PID: $($_.Id))" -Level WARN
        $_ | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 2

    # Final check
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service.Status -eq 'Stopped') {
        Write-UpdateLog 'Service stopped after forced termination' -Level SUCCESS
        return $true
    }

    Write-UpdateLog "CRITICAL: Service is still in state '$($service.Status)' after all stop attempts" -Level ERROR
    return $false
}

function Start-JellyfinService {
    Write-UpdateLog "Starting service '$ServiceName'..."

    $maxRetries = 3
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            Start-Service -Name $ServiceName -ErrorAction Stop
            $svc = Get-Service -Name $ServiceName
            $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
            Write-UpdateLog 'Service started successfully' -Level SUCCESS
            return $true
        }
        catch {
            Write-UpdateLog "Start attempt $attempt/$maxRetries failed: $_" -Level WARN
            if ($attempt -lt $maxRetries) {
                Start-Sleep -Seconds 5
            }
        }
    }

    Write-UpdateLog 'Failed to start service after all attempts' -Level ERROR
    return $false
}

#endregion

#region -- Backup & Rollback --------------------------------------------------

function New-InstallationBackup {
    if (-not (Test-Path $Script:BackupRoot)) {
        New-Item -Path $Script:BackupRoot -ItemType Directory -Force | Out-Null
    }

    $installedVersion = Get-InstalledVersion
    $versionLabel = if ($installedVersion) { $installedVersion } else { 'unknown' }
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupDir = Join-Path $Script:BackupRoot "${versionLabel}_${timestamp}"

    Write-UpdateLog "Creating backup of $InstallPath to $backupDir..."

    try {
        $robocopyArgs = @(
            $InstallPath
            $backupDir
            '/MIR'
            '/R:2'
            '/W:1'
            '/NP'
            '/NDL'
            '/NFL'
            '/LOG+:' + (Join-Path $LogDirectory "robocopy_backup_$timestamp.log")
        )

        $null = & robocopy @robocopyArgs
        $robocopyExit = $LASTEXITCODE

        if ($robocopyExit -ge 8) {
            Write-UpdateLog "Robocopy backup failed with exit code $robocopyExit" -Level ERROR
            return $null
        }

        $backupSize = (Get-ChildItem $backupDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
        Write-UpdateLog "Backup complete: $backupDir ($([math]::Round($backupSize / 1MB, 1)) MB)" -Level SUCCESS

        # Prune old backups
        Get-ChildItem -Path $Script:BackupRoot -Directory |
            Sort-Object CreationTime -Descending |
            Select-Object -Skip $MaxBackups |
            ForEach-Object {
                Write-UpdateLog "Pruning old backup: $($_.Name)"
                Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }

        return $backupDir
    }
    catch {
        Write-UpdateLog "Backup failed: $_" -Level ERROR
        return $null
    }
}

function Restore-FromBackup {
    param(
        [Parameter(Mandatory)]
        [string]$BackupDir
    )

    Write-UpdateLog "ROLLING BACK from backup: $BackupDir" -Level WARN

    if (-not (Test-Path $BackupDir)) {
        Write-UpdateLog "Backup directory not found: $BackupDir" -Level ERROR
        return $false
    }

    # Make sure service is stopped before rollback
    $null = Stop-JellyfinService

    try {
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $robocopyArgs = @(
            $BackupDir
            $InstallPath
            '/MIR'
            '/R:2'
            '/W:1'
            '/NP'
            '/NDL'
            '/NFL'
            '/LOG+:' + (Join-Path $LogDirectory "robocopy_rollback_$timestamp.log")
        )

        $null = & robocopy @robocopyArgs
        $robocopyExit = $LASTEXITCODE

        if ($robocopyExit -ge 8) {
            Write-UpdateLog "Robocopy rollback failed with exit code $robocopyExit -- MANUAL INTERVENTION REQUIRED" -Level ERROR
            return $false
        }

        Write-UpdateLog 'Files restored from backup' -Level SUCCESS

        if (Start-JellyfinService) {
            Write-UpdateLog 'Rollback complete, service is running on previous version' -Level SUCCESS
            return $true
        }
        else {
            Write-UpdateLog 'Rollback restored files but service failed to start -- MANUAL INTERVENTION REQUIRED' -Level ERROR
            return $false
        }
    }
    catch {
        Write-UpdateLog "Rollback failed: $_ -- MANUAL INTERVENTION REQUIRED" -Level ERROR
        return $false
    }
}

#endregion

#region -- Installation -------------------------------------------------------

function Install-JellyfinUpdate {
    param(
        [Parameter(Mandatory)]
        [string]$ZipPath
    )

    Write-UpdateLog "Extracting $ZipPath to $InstallPath..."

    try {
        # The ZIP contains a root folder like 'jellyfin_10.11.7' with files inside.
        # Extract to staging first to handle the root folder transparently.

        $stagingDir = Join-Path (Split-Path $ZipPath -Parent) 'staging'
        New-Item -Path $stagingDir -ItemType Directory -Force | Out-Null

        Write-UpdateLog 'Extracting ZIP to staging directory...'
        Expand-Archive -Path $ZipPath -DestinationPath $stagingDir -Force

        # Determine source: single subfolder (unwrap it) or flat extraction
        $extractedItems = @(Get-ChildItem -Path $stagingDir)
        if ($extractedItems.Count -eq 1 -and $extractedItems[0].PSIsContainer) {
            $sourceDir = $extractedItems[0].FullName
            Write-UpdateLog "ZIP contains root folder: $($extractedItems[0].Name)"
        }
        else {
            $sourceDir = $stagingDir
            Write-UpdateLog 'ZIP extracts flat (no root folder)'
        }

        # Verify the extracted content looks like Jellyfin
        $hasJellyfinBinary = (Test-Path (Join-Path $sourceDir 'jellyfin.dll')) -or
                             (Test-Path (Join-Path $sourceDir 'jellyfin.exe'))
        if (-not $hasJellyfinBinary) {
            Write-UpdateLog 'Extracted content does not contain jellyfin.dll or jellyfin.exe -- ZIP may be corrupt' -Level ERROR
            return $false
        }

        # Robocopy the extracted files into the install path
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $robocopyArgs = @(
            $sourceDir
            $InstallPath
            '/MIR'
            '/R:2'
            '/W:1'
            '/NP'
            '/NDL'
            '/NFL'
            '/LOG+:' + (Join-Path $LogDirectory "robocopy_install_$timestamp.log")
        )

        $null = & robocopy @robocopyArgs
        $robocopyExit = $LASTEXITCODE

        if ($robocopyExit -ge 8) {
            Write-UpdateLog "Robocopy install failed with exit code $robocopyExit" -Level ERROR
            return $false
        }

        # Final verification
        $hasJellyfinBinary = (Test-Path (Join-Path $InstallPath 'jellyfin.dll')) -or
                             (Test-Path (Join-Path $InstallPath 'jellyfin.exe'))
        if (-not $hasJellyfinBinary) {
            Write-UpdateLog "Post-install verification failed: no Jellyfin binary found in $InstallPath" -Level ERROR
            return $false
        }

        Write-UpdateLog 'Installation completed successfully' -Level SUCCESS
        return $true
    }
    catch {
        Write-UpdateLog "Installation failed: $_" -Level ERROR
        return $false
    }
    finally {
        if ($stagingDir -and (Test-Path $stagingDir)) {
            Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion

#region -- Health Check -------------------------------------------------------

function Test-JellyfinHealth {
    Write-UpdateLog "Performing health check against $HealthCheckUrl (timeout: ${HealthCheckTimeoutSeconds}s)..."

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $pollInterval = 5

    while ($stopwatch.Elapsed.TotalSeconds -lt $HealthCheckTimeoutSeconds) {
        try {
            $response = Invoke-WebRequest -Uri $HealthCheckUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                $body = $response.Content.Trim()
                if ($body -eq 'Healthy') {
                    Write-UpdateLog "Health check passed (HTTP 200, body='Healthy') after $([math]::Round($stopwatch.Elapsed.TotalSeconds))s" -Level SUCCESS
                    return $true
                }
                Write-UpdateLog "Health check HTTP 200 but unexpected body: '$body', retrying..." -Level WARN
            }
            else {
                Write-UpdateLog "Health check returned HTTP $($response.StatusCode), retrying..." -Level WARN
            }
        }
        catch {
            $elapsed = [math]::Round($stopwatch.Elapsed.TotalSeconds)
            Write-UpdateLog "Health check not ready (${elapsed}s elapsed): $($_.Exception.Message)" -Level WARN
        }

        Start-Sleep -Seconds $pollInterval
    }

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    Write-UpdateLog "Health check FAILED after ${HealthCheckTimeoutSeconds}s. Service status: $($service.Status)" -Level ERROR
    return $false
}

#endregion

#region -- Compare Versions ---------------------------------------------------

function Compare-SemanticVersion {
    param(
        [string]$Installed,
        [string]$Latest
    )

    # Strip v prefix, pre-release suffix (-beta.1), and build metadata (+abc)
    $cleanPattern = '^v?(?<ver>\d+\.\d+\.\d+(\.\d+)?)'

    $instMatch   = [regex]::Match($Installed, $cleanPattern)
    $latestMatch = [regex]::Match($Latest, $cleanPattern)

    if (-not $instMatch.Success -or -not $latestMatch.Success) {
        Write-UpdateLog "Could not parse version numbers, falling back to string comparison (installed='$Installed', latest='$Latest')" -Level WARN
        return $Installed -ne $Latest
    }

    try {
        $instVer   = [version]$instMatch.Groups['ver'].Value
        $latestVer = [version]$latestMatch.Groups['ver'].Value
        return $latestVer -gt $instVer
    }
    catch {
        Write-UpdateLog "Version cast failed: $_ - falling back to string comparison" -Level WARN
        return $Installed -ne $Latest
    }
}

#endregion

#region -- Main ---------------------------------------------------------------

function Invoke-JellyfinUpdate {
    Initialize-Logging
    Write-UpdateLog '================================================================'
    Write-UpdateLog '  Jellyfin Auto-Updater starting (portable ZIP mode)'
    Write-UpdateLog "  Host: $env:COMPUTERNAME | User: $env:USERNAME | PID: $PID"
    Write-UpdateLog '================================================================'

    $exitCode = [ExitCode]::Success
    $backupDir = $null
    $tempDir = $null
    $installedVersion = $null
    $release = $null

    try {
        # -- Lock --
        if (-not (Enter-UpdateLock)) {
            return [int][ExitCode]::ConcurrentRun
        }

        # -- Pre-flight --
        if (-not (Test-PreFlightChecks)) {
            $exitCode = [ExitCode]::PreFlightFailed
            return [int]$exitCode
        }

        # -- Version check --
        $installedVersion = Get-InstalledVersion
        $release = Get-LatestRelease

        if (-not $release) {
            $exitCode = [ExitCode]::DownloadFailed
            return [int]$exitCode
        }

        if ($installedVersion -and -not $Force) {
            $updateNeeded = Compare-SemanticVersion -Installed $installedVersion -Latest $release.Version
            if (-not $updateNeeded) {
                Write-UpdateLog "Already up to date: installed=$installedVersion, latest=$($release.Version)" -Level SUCCESS
                return [int][ExitCode]::AlreadyUpToDate
            }
        }

        Write-UpdateLog "Update available: $installedVersion -> $($release.Version)"

        # -- Download --
        $download = Get-PortableZip -Release $release
        if (-not $download) {
            $exitCode = [ExitCode]::DownloadFailed
            return [int]$exitCode
        }
        $tempDir = $download.TempDir

        # -- Backup --
        $backupDir = New-InstallationBackup
        if (-not $backupDir) {
            Write-UpdateLog 'Cannot proceed without a valid backup' -Level ERROR
            $exitCode = [ExitCode]::PreFlightFailed
            return [int]$exitCode
        }

        # -- Stop service --
        if (-not (Stop-JellyfinService)) {
            $exitCode = [ExitCode]::ServiceStopFailed
            return [int]$exitCode
        }

        # Brief pause to ensure file handles are released
        Start-Sleep -Seconds 3

        # -- Extract & install --
        if (-not (Install-JellyfinUpdate -ZipPath $download.ZipPath)) {
            Write-UpdateLog 'Installation failed, initiating rollback...' -Level ERROR
            Restore-FromBackup -BackupDir $backupDir
            $exitCode = [ExitCode]::RollbackPerformed
            return [int]$exitCode
        }

        # -- Start service --
        if (-not (Start-JellyfinService)) {
            Write-UpdateLog 'Service failed to start after update, initiating rollback...' -Level ERROR
            Restore-FromBackup -BackupDir $backupDir
            $exitCode = [ExitCode]::RollbackPerformed
            return [int]$exitCode
        }

        # -- Health check --
        if (-not (Test-JellyfinHealth)) {
            Write-UpdateLog 'Health check failed after update, initiating rollback...' -Level ERROR
            Restore-FromBackup -BackupDir $backupDir
            $exitCode = [ExitCode]::RollbackPerformed
            return [int]$exitCode
        }

        # -- Verify new version --
        $newVersion = Get-InstalledVersion
        Write-UpdateLog "Update successful: $installedVersion -> $newVersion" -Level SUCCESS

        Send-PushoverNotification -Type 'Success' `
            -Title "Jellyfin updated to $newVersion" `
            -Message (
                "<b>$env:COMPUTERNAME</b> updated successfully" +
                "<br><b>Previous:</b> $installedVersion" +
                "<br><b>New:</b> $newVersion" +
                "<br><b>Duration:</b> $([math]::Round(((Get-Date) - (Get-Item $Script:LogFile).CreationTime).TotalSeconds))s"
            ) `
            -Url "https://github.com/jellyfin/jellyfin/releases/tag/$($release.Tag)" `
            -UrlTitle 'Release Notes'

        $exitCode = [ExitCode]::Success
        return [int]$exitCode
    }
    catch {
        Write-UpdateLog "UNHANDLED EXCEPTION: $_" -Level ERROR
        Write-UpdateLog "Stack trace: $($_.ScriptStackTrace)" -Level ERROR

        if ($backupDir -and (Test-Path $backupDir)) {
            Write-UpdateLog 'Attempting emergency rollback...' -Level WARN
            Restore-FromBackup -BackupDir $backupDir
            $exitCode = [ExitCode]::RollbackPerformed
        }
        else {
            $exitCode = [ExitCode]::UnhandledError
        }

        return [int]$exitCode
    }
    finally {
        if ($tempDir -and (Test-Path $tempDir)) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-UpdateLog "Cleaned up temp directory: $tempDir"
        }

        Exit-UpdateLock

        # -- Send failure/rollback notifications --
        if ($exitCode -eq [ExitCode]::RollbackPerformed) {
            Send-PushoverNotification -Type 'Rollback' `
                -Title 'Jellyfin update ROLLED BACK' `
                -Message (
                    "<b>$env:COMPUTERNAME</b> update failed and was rolled back" +
                    "<br><b>Installed:</b> $(if ($installedVersion) { $installedVersion } else { 'unknown' })" +
                    "<br><b>Target:</b> $(if ($release) { $release.Version } else { 'unknown' })" +
                    "<br>Check logs: <b>$Script:LogFile</b>"
                )
        }
        elseif ([int]$exitCode -gt 0 -and $exitCode -ne [ExitCode]::ConcurrentRun) {
            Send-PushoverNotification -Type 'Failed' `
                -Title "Jellyfin update failed ($exitCode)" `
                -Message (
                    "<b>$env:COMPUTERNAME</b> update failed at stage: <b>$exitCode</b>" +
                    "<br><b>Installed:</b> $(if ($installedVersion) { $installedVersion } else { 'unknown' })" +
                    "<br>Check logs: <b>$Script:LogFile</b>"
                )
        }

        Write-UpdateLog "Exit code: $exitCode ($([int]$exitCode))"
        Write-UpdateLog '================================================================'
        Write-UpdateLog '  Jellyfin Auto-Updater finished'
        Write-UpdateLog '================================================================'
    }
}

# Execute and exit with code for Task Scheduler
$result = Invoke-JellyfinUpdate | Select-Object -Last 1
exit $result
