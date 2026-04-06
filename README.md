# Update-Jellyfin

Automatic updater for [Jellyfin Media Server](https://jellyfin.org/) on Windows. Designed for unattended execution via Task Scheduler.

Uses the **portable ZIP** from [repo.jellyfin.org](https://repo.jellyfin.org/) -- never touches service registration, so custom service accounts, start modes, and recovery settings are always preserved.

## Features

- **Automatic version detection** -- compares installed version against the GitHub releases API
- **Safe updates** -- full installation backup before every update with automatic rollback on failure
- **Graceful service management** -- stops the service cleanly with escalation to forced kill if needed
- **Post-update health check** -- verifies Jellyfin responds with HTTP 200 + `Healthy` body
- **Concurrent run protection** -- atomic lock file prevents overlapping executions
- **Pre-flight checks** -- validates service exists, install path, disk space (2 GB min), and internet connectivity
- **Pushover notifications** -- optional push notifications on success, failure, or rollback
- **Comprehensive logging** -- timestamped log files with automatic rotation

## Requirements

- Windows with PowerShell 5.1 or later
- Administrator privileges
- Jellyfin installed as a Windows service (the script does **not** register the service -- see [Service Setup](#service-setup))

## Quick Start

```powershell
.\Update-Jellyfin.ps1
```

The script will check for updates, download the latest portable ZIP, back up your current installation, apply the update, and verify Jellyfin is healthy. If anything fails, it rolls back automatically.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-InstallPath` | `C:\Program Files\Jellyfin\Server` | Jellyfin Server installation directory |
| `-ServiceName` | `JellyfinServer` | Name of the Windows service |
| `-LogDirectory` | `C:\ProgramData\Jellyfin\UpdateLogs` | Directory for log files |
| `-HealthCheckUrl` | `http://localhost:8096/health` | URL to probe after update |
| `-HealthCheckTimeoutSeconds` | `120` | Max seconds to wait for health check (30--600) |
| `-ServiceStopTimeoutSeconds` | `60` | Max seconds to wait for graceful stop (10--300) |
| `-MaxBackups` | `3` | Number of installation backups to keep (1--20) |
| `-MaxLogFiles` | `30` | Number of log files to keep (1--100) |
| `-Force` | | Force update even if already on latest version |
| `-PushoverUserKey` | | Pushover user/group key for notifications |
| `-PushoverApiToken` | | Pushover application API token |
| `-PushoverDevice` | | Target a specific Pushover device |

## Examples

```powershell
# Check for updates and apply if available
.\Update-Jellyfin.ps1

# Force reinstall with verbose output
.\Update-Jellyfin.ps1 -Force -Verbose

# Custom paths and Pushover notifications
.\Update-Jellyfin.ps1 `
    -InstallPath "D:\Jellyfin\Server" `
    -PushoverUserKey "your-user-key" `
    -PushoverApiToken "your-api-token"
```

## Task Scheduler Setup

Create a scheduled task to run the updater automatically:

**Program:** `powershell.exe`

**Arguments:**
```
-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Scripts\Update-Jellyfin.ps1"
```

The script returns structured exit codes for Task Scheduler visibility:

| Exit Code | Meaning |
|-----------|---------|
| 0 | Success / Already up to date |
| 1 | Another instance is already running |
| 2 | Pre-flight check failed |
| 3 | Download failed |
| 5 | Service stop failed |
| 6 | Installation failed |
| 7 | Rollback was performed |
| 8 | Health check failed |
| 99 | Unhandled error |

## Service Setup

This script does **not** register a Windows service. If migrating from the NSIS installer or setting up fresh, register the service manually:

```powershell
sc.exe create JellyfinServer `
    binPath= '"C:\Program Files\Jellyfin\Server\jellyfin.exe" --service --datadir "C:\ProgramData\Jellyfin\Server"' `
    start= delayed-auto

sc.exe description JellyfinServer "Jellyfin Media Server"
sc.exe failure JellyfinServer reset= 86400 actions= restart/30000/restart/60000/restart/120000
```

## How It Works

```
Check for update (GitHub API)
        |
    Download portable ZIP (Invoke-WebRequest, BITS fallback)
        |
    Validate ZIP (header + size check)
        |
    Backup current installation (robocopy mirror)
        |
    Stop Jellyfin service (graceful -> forced kill)
        |
    Extract and install (staging dir -> robocopy mirror)
        |
    Start service + health check (HTTP poll)
        |
    Success -- or automatic rollback from backup
```

## File Locations

| What | Where |
|------|-------|
| Installation backups | `C:\ProgramData\Jellyfin\UpdateBackups\` |
| Update logs | `C:\ProgramData\Jellyfin\UpdateLogs\` |
| Lock file | `C:\ProgramData\Jellyfin\update.lock` |

## License

[MIT](LICENSE)
