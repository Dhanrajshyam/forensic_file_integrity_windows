. "$PSScriptRoot/utils.ps1"

Initialize-Files

$config = Import-Config
Test-Config $config
$logFile = "$script:ProjectRoot/data/chain_log.csv"
$stateFile = "$script:ProjectRoot/data/state.json"

# Load existing file state (path -> last known hash)
if ((Get-Content $stateFile -Raw).Trim() -ne "{}") {
    $fileState = Get-Content $stateFile -Raw | ConvertFrom-Json
} else {
    $fileState = @{}
}

# Debounce tracking (path -> last event time)
$lastEventTime = @{}
$debounceSec = 2

function Save-State {
    $fileState | ConvertTo-Json | Out-File $stateFile
}

function Get-LastChainHash {
    $lines = Get-Content $logFile
    if ($lines.Count -le 1) { return "" }
    $lastLine = $lines[-1]
    $fields = $lastLine -split ","
    return $fields[-1]
}

function Save-ChainState($message) {
    if (-not $config.repoPath -or -not (Test-Path "$($config.repoPath)/.git")) {
        return
    }
    try {
        git -C $config.repoPath add chain_log.csv state.json 2>&1 | Out-Null
        git -C $config.repoPath commit -m "$message" --gpg-sign 2>&1 | Out-Null
    } catch {
        Write-LogEntry "WARNING" "Git commit failed: $_"
    }
}

function New-Timestamp($chainHash) {
    if (-not $config.enableOpenTimestamps) { return }

    $hashFile = "$script:ProjectRoot/data/latest_hash.txt"
    $chainHash | Out-File $hashFile -NoNewline

    try {
        python -m opentimestamps_client.cmds stamp $hashFile 2>&1 | Out-Null
        Write-LogEntry "INFO" "OpenTimestamp created for chain hash: $($chainHash.Substring(0, 12))..."
    } catch {
        Write-LogEntry "WARNING" "OpenTimestamp creation failed: $_"
    }
}

function Add-ChainEntry($fileName, $fileHash) {
    $chainHash = $null
    Invoke-ChainLogLock {
        $timestamp = Get-Timestamp
        $prevHash = Get-LastChainHash
        $script:chainHash = Get-ChainHash $fileHash $prevHash $timestamp

        "$fileName,$fileHash,$timestamp,$($script:chainHash)" | Out-File $logFile -Append
    }

    Write-LogEntry "EVENT" "Recorded: $fileName (Hash: $($fileHash.Substring(0, 12))...)"

    Save-ChainState "[forensic] $fileName at $(Get-Timestamp)"
    New-Timestamp $script:chainHash
}

function Invoke-FileEvent($path, $changeType) {
    # Debounce: skip if same file triggered within 2 seconds
    $now = Get-Date
    if ($lastEventTime.ContainsKey($path)) {
        $elapsed = ($now - $lastEventTime[$path]).TotalSeconds
        if ($elapsed -lt $debounceSec) { return }
    }
    $lastEventTime[$path] = $now

    $fileName = [System.IO.Path]::GetFileName($path)

    switch ($changeType) {
        { $_ -in "Created", "Changed" } {
            if (-not (Test-Path $path)) { return }

            try {
                $hash = (Get-FileHash $path -Algorithm SHA256).Hash
            } catch {
                Write-LogEntry "WARNING" "Could not hash file: $path - $_"
                return
            }

            # Skip if hash hasn't changed
            $stateKey = $path.Replace("\", "/")
            if ($fileState -is [hashtable] -and $fileState.ContainsKey($stateKey) -and $fileState[$stateKey] -eq $hash) {
                return
            }

            Add-ChainEntry $fileName $hash
            $fileState[$stateKey] = $hash
            Save-State

            Write-Host "[$(Get-Timestamp)] $changeType`: $fileName"
        }
        "Deleted" {
            $stateKey = $path.Replace("\", "/")
            $lastKnown = ""
            if ($fileState -is [hashtable] -and $fileState.ContainsKey($stateKey)) {
                $lastKnown = $fileState[$stateKey]
                $fileState.Remove($stateKey)
                Save-State
            }

            $deleteHash = "DELETED:$lastKnown"
            Add-ChainEntry $fileName $deleteHash

            Write-Host "[$(Get-Timestamp)] Deleted: $fileName"
        }
        "Renamed" {
            if (Test-Path $path) {
                try {
                    $hash = (Get-FileHash $path -Algorithm SHA256).Hash
                    Add-ChainEntry $fileName $hash
                    $stateKey = $path.Replace("\", "/")
                    $fileState[$stateKey] = $hash
                    Save-State
                } catch {
                    Write-LogEntry "WARNING" "Could not hash renamed file: $path - $_"
                }
            }

            Write-Host "[$(Get-Timestamp)] Renamed: $fileName"
        }
    }
}

function Start-DirectoryScan($watchPaths) {
    foreach ($watchPath in $watchPaths) {
        if (-not (Test-Path $watchPath)) { continue }

        Get-ChildItem $watchPath -Recurse -File | ForEach-Object {
            $path = $_.FullName
            $stateKey = $path.Replace("\", "/")

            try {
                $hash = (Get-FileHash $path -Algorithm SHA256).Hash
            } catch {
                return  # skip files we can't read
            }

            if (-not ($fileState -is [hashtable]) -or
                -not $fileState.ContainsKey($stateKey) -or
                $fileState[$stateKey] -ne $hash) {

                $fileName = [System.IO.Path]::GetFileName($path)
                Add-ChainEntry $fileName $hash
                $fileState[$stateKey] = $hash
            }
        }
    }
    Save-State
}

# --- Main ---

$watchers = @()
$watchPaths = $config.watchPaths
$verifyInterval = $config.verifyIntervalSeconds
if (-not $verifyInterval -or $verifyInterval -le 0) { $verifyInterval = 300 }

Write-Host "Forensic Watcher starting..."
Write-Host "Watch paths: $($watchPaths -join ', ')"
Write-Host "Verify interval: ${verifyInterval}s"

Write-LogEntry "INFO" "Watcher started. Monitoring: $($watchPaths -join ', ')"

# Initial full scan
Start-DirectoryScan $watchPaths

try {
    # Create FileSystemWatcher for each watch path
    foreach ($watchPath in $watchPaths) {
        if (-not (Test-Path $watchPath)) {
            Write-Warning "Watch path does not exist: $watchPath"
            Write-LogEntry "WARNING" "Watch path does not exist: $watchPath"
            continue
        }

        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $watchPath
        $watcher.IncludeSubdirectories = $true
        $watcher.EnableRaisingEvents = $true

        Register-ObjectEvent $watcher "Created" -Action {
            Invoke-FileEvent $Event.SourceEventArgs.FullPath "Created"
        } | Out-Null

        Register-ObjectEvent $watcher "Changed" -Action {
            Invoke-FileEvent $Event.SourceEventArgs.FullPath "Changed"
        } | Out-Null

        Register-ObjectEvent $watcher "Deleted" -Action {
            Invoke-FileEvent $Event.SourceEventArgs.FullPath "Deleted"
        } | Out-Null

        Register-ObjectEvent $watcher "Renamed" -Action {
            Invoke-FileEvent $Event.SourceEventArgs.FullPath "Renamed"
        } | Out-Null

        $watchers += $watcher
        Write-Host "Watching: $watchPath"
    }

    # Main loop: periodic full scan to catch any missed events
    while ($true) {
        Start-Sleep -Seconds $verifyInterval
        Write-Host "[$(Get-Timestamp)] Running periodic scan..."
        Start-DirectoryScan $watchPaths
    }
} finally {
    # Cleanup
    foreach ($w in $watchers) {
        $w.EnableRaisingEvents = $false
        $w.Dispose()
    }
    Get-EventSubscriber | Unregister-Event -ErrorAction SilentlyContinue
    Write-LogEntry "INFO" "Watcher stopped."
    Write-Host "Watcher stopped."
}
