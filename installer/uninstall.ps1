#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Uninstalls the Forensic File Integrity System.

.DESCRIPTION
    Stops and removes the ForensicWatcher scheduled task, then optionally
    removes the installed program files from the path configured in config.json
    (installPath). Evidence data (chain_log.csv, .ots files) can be preserved
    for legal hold.

.PARAMETER PreserveData
    If specified, skips deletion of the data\ and logs\ subdirectories under
    installPath, preserving the chain log, OTS proofs, and system event log
    for legal hold.

.PARAMETER Force
    Suppresses all confirmation prompts. Use with caution.

.EXAMPLE
    .\uninstall.ps1
    Interactive uninstall with prompts.

.EXAMPLE
    .\uninstall.ps1 -PreserveData
    Removes program files but keeps evidence data intact.

.EXAMPLE
    .\uninstall.ps1 -Force
    Removes everything without prompts.
#>

param(
    [switch]$PreserveData,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Read installPath and repoPath from the project source config — same source of
# truth used by install.ps1. This must be done before any files are deleted.
$sourceConfig = Join-Path $PSScriptRoot "..\config\config.json"
if (-not (Test-Path $sourceConfig)) {
    throw "config/config.json not found. Cannot determine install path."
}
$config      = Get-Content $sourceConfig -Raw | ConvertFrom-Json
$InstallPath = $config.installPath
$TaskName    = "ForensicWatcher"
$WeeklyTaskName = "ForensicWeeklyMaintenance"

if (-not $InstallPath) {
    throw "Config error: 'installPath' is not set in config.json"
}

function Write-Status($message) {
    Write-Host "[*] $message"
}

function Write-Done($message) {
    Write-Host "[+] $message" -ForegroundColor Green
}

function Write-Warn($message) {
    Write-Host "[!] $message" -ForegroundColor Yellow
}

function Write-Fail($message) {
    Write-Host "[-] $message" -ForegroundColor Red
}

function Confirm-Action($prompt) {
    if ($Force) { return $true }
    $answer = Read-Host "$prompt [y/N]"
    return ($answer -match "^[Yy]$")
}

# ── Banner ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Forensic File Integrity System — Uninstaller" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

if (-not $Force) {
    Write-Host "This will:"
    Write-Host "  1. Stop the ForensicWatcher scheduled task"
    Write-Host "  2. Remove the scheduled task registration"
    if ($PreserveData) {
        Write-Host "  3. Remove program files from $InstallPath"
        Write-Host "     (Evidence data in data\ and logs\ will be PRESERVED)"
    } else {
        Write-Host "  3. Remove ALL files from $InstallPath"
        Write-Host "     (Including chain log, OTS proofs, and evidence data)"
    }
    Write-Host ""
    if (-not (Confirm-Action "Proceed with uninstall?")) {
        Write-Host "Uninstall cancelled."
        exit 0
    }
    Write-Host ""
}

# ── Step 1: Stop the scheduled task ─────────────────────────────────────────

Write-Status "Stopping scheduled task '$TaskName'..."

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    if ($task.State -eq "Running") {
        try {
            Stop-ScheduledTask -TaskName $TaskName
            Write-Done "Task stopped."
        } catch {
            Write-Warn "Could not stop task: $_"
        }
    } else {
        Write-Status "Task is not currently running (state: $($task.State))."
    }
} else {
    Write-Warn "Scheduled task '$TaskName' not found — skipping."
}

# ── Step 2: Unregister the scheduled task ───────────────────────────────────

Write-Status "Removing scheduled task '$TaskName'..."

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Done "Scheduled task removed."
    } catch {
        Write-Fail "Failed to remove scheduled task: $_"
        Write-Warn "You can remove it manually via Task Scheduler (taskschd.msc)."
    }
} else {
    Write-Warn "Scheduled task '$TaskName' not found — skipping."
}

# ── Step 2b: Remove weekly maintenance task ─────────────────────────────────

Write-Status "Removing scheduled task '$WeeklyTaskName'..."

$weeklyTask = Get-ScheduledTask -TaskName $WeeklyTaskName -ErrorAction SilentlyContinue
if ($weeklyTask) {
    if ($weeklyTask.State -eq "Running") {
        Stop-ScheduledTask -TaskName $WeeklyTaskName -ErrorAction SilentlyContinue
    }
    try {
        Unregister-ScheduledTask -TaskName $WeeklyTaskName -Confirm:$false
        Write-Done "Scheduled task removed."
    } catch {
        Write-Fail "Failed to remove scheduled task: $_"
    }
} else {
    Write-Warn "Scheduled task '$WeeklyTaskName' not found — skipping."
}

# ── Step 3: Remove installed files ──────────────────────────────────────────

if (-not (Test-Path $InstallPath)) {
    Write-Warn "Install path '$InstallPath' not found — nothing to remove."
} else {
    if ($PreserveData) {
        Write-Status "Preserving evidence data. Removing program files only..."

        $removeDirs = @("src", "config", "installer")
        foreach ($dir in $removeDirs) {
            $target = Join-Path $InstallPath $dir
            if (Test-Path $target) {
                try {
                    Remove-Item $target -Recurse -Force
                    Write-Done "Removed: $target"
                } catch {
                    Write-Fail "Could not remove $target`: $_"
                }
            }
        }

        Write-Host ""
        Write-Host "Evidence data preserved at:" -ForegroundColor Cyan
        Write-Host "  $InstallPath\data"
        Write-Host "  $InstallPath\logs"
        Write-Host ""
        Write-Host "Keep these for legal hold, court submission, or further investigation."

    } else {
        # Warn before removing evidence
        if (-not $Force) {
            Write-Host ""
            Write-Warn "This will permanently delete the chain log, OTS blockchain proofs,"
            Write-Warn "and all evidence data. This CANNOT be undone."
            Write-Host ""
            if (-not (Confirm-Action "Confirm deletion of all evidence data?")) {
                Write-Host "Uninstall aborted to preserve data."
                Write-Host "Re-run with -PreserveData to remove program files only."
                exit 0
            }
        }

        try {
            Remove-Item $InstallPath -Recurse -Force
            Write-Done "Removed: $InstallPath"
        } catch {
            Write-Fail "Could not fully remove $InstallPath`: $_"
            Write-Warn "Some files may be locked by a running process. Close any open"
            Write-Warn "PowerShell sessions using ForensicSystem files and retry."
        }
    }
}

# ── Step 4: Remove Git repo (optional) ──────────────────────────────────────
# $config was read at the top before any deletions, so repoPath is always available.

if ($config.repoPath -and (Test-Path "$($config.repoPath)\.git")) {
    Write-Host ""
    Write-Warn "A forensic Git repository exists at: $($config.repoPath)"
    Write-Warn "This repository contains the signed audit trail."
    if (-not $Force -and -not $PreserveData) {
        if (Confirm-Action "Remove the forensic Git repository?") {
            Remove-Item $config.repoPath -Recurse -Force
            Write-Done "Git repository removed: $($config.repoPath)"
        } else {
            Write-Status "Git repository preserved at: $($config.repoPath)"
        }
    } else {
        Write-Status "Git repository preserved at: $($config.repoPath)"
        Write-Status "Remove it manually if no longer needed."
    }
}

# ── Done ─────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Uninstall complete." -ForegroundColor Green
Write-Host ""
