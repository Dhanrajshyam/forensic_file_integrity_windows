#Requires -RunAsAdministrator

Write-Host "Installing Forensic Integrity System..."

# Read installPath from config before copying anything
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

# Initialize Git evidence repo if configured
if ($config.repoPath -and -not (Test-Path "$($config.repoPath)\.git")) {
    New-Item -ItemType Directory -Force -Path $config.repoPath | Out-Null
    git init $config.repoPath
    Write-Host "Git repo initialized at $($config.repoPath)"
}

# Setup scheduled task
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -File `"$InstallPath\src\watcher.ps1`"" `
    -WorkingDirectory $InstallPath

$trigger = New-ScheduledTaskTrigger -AtStartup

Register-ScheduledTask `
    -TaskName "ForensicWatcher" `
    -Action $action `
    -Trigger $trigger `
    -RunLevel Highest `
    -Force

Write-Host "Installation complete. Files installed to: $InstallPath"
