Write-Host "Installing Forensic Integrity System..."

# Create directories
New-Item -ItemType Directory -Force -Path "C:\ForensicSystem"

# Copy files
Copy-Item ..\src C:\ForensicSystem -Recurse -Force
Copy-Item ..\config C:\ForensicSystem -Recurse -Force

# Create data and logs directories
New-Item -ItemType Directory -Force -Path "C:\ForensicSystem\data"
New-Item -ItemType Directory -Force -Path "C:\ForensicSystem\logs"

# Initialize Git repo if configured
$configPath = "C:\ForensicSystem\config\config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath | ConvertFrom-Json
    if ($config.repoPath -and -not (Test-Path "$($config.repoPath)/.git")) {
        New-Item -ItemType Directory -Force -Path $config.repoPath
        git init $config.repoPath
        Write-Host "Git repo initialized at $($config.repoPath)"
    }
}

# Setup scheduled task
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -File C:\ForensicSystem\src\watcher.ps1" `
    -WorkingDirectory "C:\ForensicSystem"

$trigger = New-ScheduledTaskTrigger -AtStartup

Register-ScheduledTask `
    -TaskName "ForensicWatcher" `
    -Action $action `
    -Trigger $trigger `
    -RunLevel Highest `
    -Force

Write-Host "Installation complete."