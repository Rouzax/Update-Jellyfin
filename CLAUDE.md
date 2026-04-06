# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Single-file PowerShell script (`Update-Jellyfin.ps1`) that automatically updates Jellyfin Server on Windows using the portable ZIP from repo.jellyfin.org. Designed for unattended execution via Task Scheduler.

## Running

Requires PowerShell 5.1+ and Administrator privileges (`#Requires -RunAsAdministrator`).

```powershell
# Default run
.\Update-Jellyfin.ps1

# Force reinstall with verbose output
.\Update-Jellyfin.ps1 -Force -Verbose

# Syntax check without execution
pwsh -NoProfile -Command "& { $null = [System.Management.Automation.Language.Parser]::ParseFile('Update-Jellyfin.ps1', [ref]$null, [ref]$errors); $errors }"
```

There are no tests, build steps, or linting configured.

## Architecture

The script follows a linear pipeline in `Invoke-JellyfinUpdate` (line ~898):

1. **Lock** (`Enter-UpdateLock`) - File-based lock at `%ProgramData%\Jellyfin\update.lock` with 30-min stale detection
2. **Pre-flight** (`Test-PreFlightChecks`) - Validates service exists, install path, disk space (2GB min), DNS resolution
3. **Version check** - Compares installed version (from DLL/EXE `ProductVersion` or `system.xml` fallback) against GitHub releases API
4. **Download** (`Get-PortableZip`) - BITS transfer with WebClient fallback, validates ZIP header and minimum size (50MB)
5. **Backup** (`New-InstallationBackup`) - Robocopy mirror to `%ProgramData%\Jellyfin\UpdateBackups\`, auto-prunes old backups
6. **Service stop** (`Stop-JellyfinService`) - Graceful stop with escalation to WMI PID kill, then wildcard process kill
7. **Install** (`Install-JellyfinUpdate`) - Extracts ZIP to staging, handles root folder unwrapping, robocopy mirrors to install path
8. **Service start + Health check** - HTTP 200 poll on `/health` endpoint with configurable timeout
9. **Rollback** (`Restore-FromBackup`) - Triggered automatically on install failure, service start failure, or health check failure

**Notifications**: Optional Pushover integration sends notifications on success, rollback, or failure.

**Exit codes**: Defined via `ExitCode` enum (lines 137-148) for Task Scheduler visibility: 0=Success, 1=ConcurrentRun, 2=PreFlightFailed, 3=DownloadFailed, 5=ServiceStopFailed, 6=InstallFailed, 7=RollbackPerformed, 8=HealthCheckFailed, 99=UnhandledError.

## Key Details

- Uses `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`
- Forces TLS 1.2 for all web requests
- Download URLs: tries versioned path on repo.jellyfin.org first, falls back to `latest-stable` symlink
- Robocopy exit codes < 8 are treated as success (standard robocopy behavior)
- All retryable operations use 3 attempts with exponential backoff
- Logging writes timestamped entries to `%ProgramData%\Jellyfin\UpdateLogs\` with auto-rotation
