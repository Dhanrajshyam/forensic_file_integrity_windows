#Requires -RunAsAdministrator

Write-Host "Installing Forensic Integrity System..."

# Read config before copying anything — installPath is the source of truth
$sourceConfig = Join-Path $PSScriptRoot "..\config\config.json"
if (-not (Test-Path $sourceConfig)) {
    throw "config/config.json not found — cannot determine install path"
}
$config = Get-Content $sourceConfig -Raw | ConvertFrom-Json

if (-not $config.installPath) {
    throw "Config error: 'installPath' is not set in config.json"
}
$InstallPath = $config.installPath
Write-Host "Install path: $InstallPath"

# Create directory structure
New-Item -ItemType Directory -Force -Path $InstallPath         | Out-Null
New-Item -ItemType Directory -Force -Path "$InstallPath\data"  | Out-Null
New-Item -ItemType Directory -Force -Path "$InstallPath\logs"  | Out-Null

# Copy source files
Copy-Item "$PSScriptRoot\..\src"    $InstallPath -Recurse -Force
Copy-Item "$PSScriptRoot\..\config" $InstallPath -Recurse -Force

# ---------------------------------------------------------------------------
# Git evidence repo: clone from remote if configured, init fresh otherwise
# ---------------------------------------------------------------------------
if ($config.repoPath) {
    if (Test-Path "$($config.repoPath)\.git") {
        Write-Host "Git repo already exists at $($config.repoPath) — reusing."
    } else {
        $branch = if ($config.gitBranch) { $config.gitBranch } else { "main" }
        $remote = if ($config.gitRemoteUrl) { $config.gitRemoteUrl } else { $null }

        $cloned = $false
        if ($remote) {
            Write-Host "Attempting to clone $remote (branch: $branch)..."

            # Attempt 1: clone the specific branch
            git clone --branch $branch --single-branch $remote $config.repoPath 2>&1 | Out-Host
            if ($LASTEXITCODE -eq 0) {
                $cloned = $true
                Write-Host "Cloned existing repo (branch: $branch)."
            }

            if (-not $cloned) {
                # Branch not on remote yet — clone default, create our branch
                git clone --single-branch $remote $config.repoPath 2>&1 | Out-Host
                if ($LASTEXITCODE -eq 0) {
                    git -C $config.repoPath checkout -b $branch 2>&1 | Out-Host
                    $cloned = $true
                    Write-Host "Cloned repo; created branch '$branch'."
                }
            }
        }

        if (-not $cloned) {
            Write-Host "Initialising fresh Git repo..."
            New-Item -ItemType Directory -Force -Path $config.repoPath | Out-Null
            git init -b $branch $config.repoPath
            if ($remote) {
                git -C $config.repoPath remote add origin $remote
                Write-Host "Remote set to: $remote"
            }
        }

        if ($config.systemName) {
            $systemFolder = Join-Path $config.repoPath $config.systemName
            New-Item -ItemType Directory -Force -Path $systemFolder | Out-Null
            Write-Host "System folder created: $systemFolder"
        }
    }

    # Write git identity into the repo-local config so scheduled tasks running
    # as SYSTEM can commit without a global gitconfig in the SYSTEM profile.
    git -C $config.repoPath config user.name  "Forensic Watcher"
    git -C $config.repoPath config user.email "forensic@local"
    if ($config.gpgKeyId) {
        git -C $config.repoPath config user.signingkey $config.gpgKeyId
        git -C $config.repoPath config commit.gpgsign  true
    }
    Write-Host "Git identity configured in repo-local config."
}

# ---------------------------------------------------------------------------
# Scheduled tasks
# ---------------------------------------------------------------------------

# Principal: run as SYSTEM so tasks fire at startup with no user logged on
$systemPrincipal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

# Watcher — long-running daemon; no execution time limit
$watcherAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -File `"$InstallPath\src\watcher.ps1`"" `
    -WorkingDirectory $InstallPath

$watcherSettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable

Register-ScheduledTask `
    -TaskName "ForensicWatcher" `
    -Action $watcherAction `
    -Trigger (New-ScheduledTaskTrigger -AtStartup) `
    -Principal $systemPrincipal `
    -Settings $watcherSettings `
    -Force

# Weekly maintenance — every Sunday at 02:00
$maintenanceAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -File `"$InstallPath\src\weekly_maintenance.ps1`"" `
    -WorkingDirectory $InstallPath

$maintenanceSettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -StartWhenAvailable

Register-ScheduledTask `
    -TaskName "ForensicWeeklyMaintenance" `
    -Action $maintenanceAction `
    -Trigger (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At "02:00") `
    -Principal $systemPrincipal `
    -Settings $maintenanceSettings `
    -Force

Write-Host "Run '$InstallPath\src\status.ps1' at any time to check system health."
Write-Host "Installation complete. Files installed to: $InstallPath"
