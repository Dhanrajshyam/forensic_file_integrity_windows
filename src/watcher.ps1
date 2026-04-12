. "$PSScriptRoot/utils.ps1"

Initialize-Files

$config = Import-Config
Test-Config $config
$logFile = "$script:ProjectRoot/data/chain_log.csv"
$stateFile = "$script:ProjectRoot/data/state.json"

# Load existing file state (path -> last known hash) as a proper Hashtable.
# ConvertFrom-Json returns PSCustomObject, not Hashtable, so .ContainsKey() would
# never work. We explicitly convert each property into a hashtable entry.
$fileState = @{}
$raw = (Get-Content $stateFile -Raw).Trim()
if ($raw -ne "{}" -and $raw -ne "") {
    $loaded = $raw | ConvertFrom-Json
    $loaded.PSObject.Properties | ForEach-Object { $fileState[$_.Name] = $_.Value }
}

# Debounce tracking (path -> last event time)
$lastEventTime = @{}
$debounceSec = 2

function Save-State {
    $fileState | ConvertTo-Json | Out-File $stateFile
}

function Get-LastChainHash {
    # -Tail 1 reads only the final line - avoids O(n) full-file read on every entry
    $lastLine = Get-Content $logFile -Tail 1
    if (-not $lastLine -or $lastLine -match "^FileName") { return "" }
    # ChainHash is always a 64-char lowercase hex string at end of line
    if ($lastLine -match '[0-9a-f]{64}$') { return $matches[0] }
    return ""
}

# Archive chain_log.csv to chain_log_YYYY-MM.csv when the month changes.
# Called at startup and before each periodic scan. Runs inside the chain log
# mutex so no write can race with the rename.
function Invoke-ChainLogRotation {
    Invoke-ChainLogLock {
        $lines = Get-Content $logFile -TotalCount 2
        if ($lines.Count -lt 2) { return }
        $firstDataLine = $lines[1]
        if (-not $firstDataLine.Trim()) { return }

        # ConvertFrom-Csv handles quoted FullPath field correctly
        $firstEntry = $firstDataLine | ConvertFrom-Csv -Header "FileName","FullPath","FileHash","Timestamp","ChainHash"
        if (-not $firstEntry.Timestamp) { return }

        $logMonth     = $firstEntry.Timestamp.Substring(0, 7)   # "yyyy-MM"
        $currentMonth = Get-Date -Format "yyyy-MM"

        if ($logMonth -ne $currentMonth) {
            $archiveName = "$script:ProjectRoot/data/chain_log_$logMonth.csv"
            Move-Item $logFile $archiveName -Force
            "FileName,FullPath,FileHash,Timestamp,ChainHash" | Out-File $logFile -Encoding UTF8
            Write-LogEntry "INFO" "Chain log rotated: archived as chain_log_$logMonth.csv"
            Write-Host "Chain log rotated: new log started for $currentMonth"
        }
    }
}

function Save-ChainState($message) {
    if (-not $config.repoPath -or -not (Test-Path "$($config.repoPath)/.git")) {
        return
    }
    # GPG: use configured key ID when set, otherwise use GPG default key
    $gpgArg = if ($config.gpgKeyId) { "--gpg-sign=$($config.gpgKeyId)" } else { "--gpg-sign" }

    # Each system writes into its own named subfolder inside the shared repo.
    # This allows desktop, android, truenas etc. to share one repo without
    # overwriting each other's chain_log.csv and state.json.
    $systemFolder = Join-Path $config.repoPath $config.systemName
    $rel          = $config.systemName   # relative path used in git add

    try {
        New-Item -ItemType Directory -Force -Path $systemFolder | Out-Null

        Copy-Item "$script:ProjectRoot/data/chain_log.csv" $systemFolder -Force
        Copy-Item "$script:ProjectRoot/data/state.json"    $systemFolder -Force

        git -C "$($config.repoPath)" add "$rel/chain_log.csv" "$rel/state.json" 2>&1 | Out-Null

        # Include the OTS proof if it already exists from a previous stamp cycle
        $otsLocal = "$script:ProjectRoot/data/latest_hash.txt.ots"
        if (Test-Path $otsLocal) {
            Copy-Item $otsLocal $systemFolder -Force
            git -C "$($config.repoPath)" add "$rel/latest_hash.txt.ots" 2>&1 | Out-Null
        }

        git -C "$($config.repoPath)" commit -m "$message" $gpgArg 2>&1 | Out-Null
        # --set-upstream handles both the first push and all subsequent ones
        git -C "$($config.repoPath)" push --set-upstream origin HEAD 2>&1 | Out-Null
    } catch {
        Write-LogEntry "WARNING" "Git commit/push failed: $_"
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

function Add-ChainEntry($fileName, $fullPath, $fileHash, [switch]$SkipCommit) {
    Invoke-ChainLogLock {
        $timestamp = Get-Timestamp
        $prevHash = Get-LastChainHash
        $script:chainHash = Get-ChainHash $fileHash $prevHash $timestamp

        # Quote FullPath to handle spaces and special characters in CSV
        "$fileName,`"$fullPath`",$fileHash,$timestamp,$($script:chainHash)" | Out-File $logFile -Append
    }

    Write-LogEntry "EVENT" "Recorded: $fileName (Hash: $($fileHash.Substring(0, 12))...)"

    if (-not $SkipCommit) {
        Save-ChainState "[autocommit - desktop_pc_shyam] $fileName at $(Get-Timestamp)"
        New-Timestamp $script:chainHash
    }
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
            if (Test-ShouldExclude $path $config) { return }

            $hash = Get-StableFileHash $path
            if ($null -eq $hash) {
                Write-LogEntry "INFO" "Skipped (still being written, periodic scan will catch it): $fileName"
                return
            }

            # Skip if hash hasn't changed
            $stateKey = $path.Replace("\", "/")
            if ($fileState.ContainsKey($stateKey) -and $fileState[$stateKey] -eq $hash) {
                return
            }

            Add-ChainEntry $fileName $path $hash
            $fileState[$stateKey] = $hash
            Save-State

            Write-Host "[$(Get-Timestamp)] $changeType`: $fileName"
        }
        "Deleted" {
            $stateKey = $path.Replace("\", "/")

            # Only record deletion if the file was previously tracked.
            # This silently drops deletions of temp/hidden files that were
            # never recorded in the first place (e.g. ~$lock files).
            if (-not $fileState.ContainsKey($stateKey)) { return }

            $lastKnown = $fileState[$stateKey]
            $fileState.Remove($stateKey)
            Save-State

            $deleteHash = "DELETED:$lastKnown"
            Add-ChainEntry $fileName $path $deleteHash

            Write-Host "[$(Get-Timestamp)] Deleted: $fileName"
        }
        "Renamed" {
            if (Test-Path $path) {
                if (Test-ShouldExclude $path $config) { return }

                $hash = Get-StableFileHash $path
                if ($null -eq $hash) {
                    Write-LogEntry "INFO" "Skipped renamed file (still locked): $fileName"
                    return
                }
                Add-ChainEntry $fileName $path $hash
                $stateKey = $path.Replace("\", "/")
                $fileState[$stateKey] = $hash
                Save-State
            }

            Write-Host "[$(Get-Timestamp)] Renamed: $fileName"
        }
    }
}

function Start-DirectoryScan($watchPaths) {
    $changedCount = 0

    foreach ($watchPath in $watchPaths) {
        if (-not (Test-Path $watchPath)) { continue }

        Get-ChildItem $watchPath -Recurse -File | ForEach-Object {
            $path = $_.FullName
            $stateKey = $path.Replace("\", "/")

            if (Test-ShouldExclude $path $config) { return }

            $hash = Get-StableFileHash $path
            if ($null -eq $hash) {
                Write-LogEntry "INFO" "Skipped during scan (still being written): $([System.IO.Path]::GetFileName($path))"
                return
            }

            if (-not $fileState.ContainsKey($stateKey) -or $fileState[$stateKey] -ne $hash) {

                $fileName = [System.IO.Path]::GetFileName($path)
                # -SkipCommit: accumulate all entries first, commit once at the end
                Add-ChainEntry $fileName $path $hash -SkipCommit
                $fileState[$stateKey] = $hash
                $changedCount++
            }
        }
    }

    Save-State

    # One batched commit + OTS stamp for the entire scan
    if ($changedCount -gt 0) {
        Save-ChainState "[autocommit - desktop_pc_shyam] batch scan: $changedCount file(s) at $(Get-Timestamp)"
        New-Timestamp $script:chainHash
        Write-LogEntry "INFO" "Batch scan committed $changedCount file(s)"
    }
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

# Check for month rollover and rotate log before first scan
Invoke-ChainLogRotation

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

    # Main loop: check for month rollover then run periodic full scan
    while ($true) {
        Start-Sleep -Seconds $verifyInterval
        Invoke-ChainLogRotation
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
