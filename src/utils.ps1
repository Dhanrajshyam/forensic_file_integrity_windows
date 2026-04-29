$script:ProjectRoot = Split-Path $PSScriptRoot -Parent

function Get-Timestamp {
    return (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
}

function Get-ChainHash($fileHash, $prevHash, $timestamp) {
    $rawData = "$fileHash|$prevHash|$timestamp"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($rawData)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
    } finally {
        $sha.Dispose()
    }
}

function Write-LogEntry($type, $message) {
    $entry = @{
        time = Get-Timestamp
        type = $type
        message = $message
    }

    $entry | ConvertTo-Json -Compress | Out-File "$script:ProjectRoot/logs/system_log.jsonl" -Append
}

function Import-Config {
    return Get-Content "$script:ProjectRoot/config/config.json" | ConvertFrom-Json
}

function Test-Config($config) {
    if (-not $config.watchPaths -or $config.watchPaths.Count -eq 0) {
        throw "Config error: 'watchPaths' is missing or empty"
    }
    foreach ($p in $config.watchPaths) {
        if (-not (Test-Path $p)) {
            Write-Warning "Watch path does not exist: $p"
        }
    }
    if (-not $config.repoPath) {
        Write-Warning "Config: 'repoPath' not set, Git integration disabled"
    }
    if ($config.repoPath -and -not $config.gitBranch) {
        Write-Warning "Config: 'gitBranch' not set — push will default to current HEAD branch"
    }
    if (-not $config.systemName) {
        throw "Config error: 'systemName' is required (e.g. 'desktop', 'android', 'truenas')"
    }
    if ($config.systemName -match '[\\/:*?"<>|]') {
        throw "Config error: 'systemName' contains invalid characters for a folder name"
    }
    if ($config.gpgKeyId) {
        gpg --list-secret-keys $config.gpgKeyId 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Config: gpgKeyId '$($config.gpgKeyId)' not found in GPG keyring - commits may fail"
        }
    }
    if ($null -eq $config.verifyIntervalSeconds -or $config.verifyIntervalSeconds -le 0) {
        throw "Config error: 'verifyIntervalSeconds' must be a positive integer"
    }
}

function Invoke-ChainLogLock([scriptblock]$Action) {
    $mutex = New-Object System.Threading.Mutex($false, "Global\ForensicChainLogMutex")
    try {
        $mutex.WaitOne() | Out-Null
        & $Action
    } finally {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}

# Attempt to hash a file only once it is no longer being written to.
# Uses an exclusive-open probe: if the file is still locked by a writer,
# [File]::Open with FileShare.None throws IOException. Retries up to
# $maxRetries times with $retryDelaySec between attempts.
# Returns the SHA-256 hash string, or $null if the file is still locked
# after all retries (caller should skip; periodic scan will catch it later).
function Get-StableFileHash($path, $maxRetries = 5, $retryDelaySec = 3) {
    for ($i = 0; $i -lt $maxRetries; $i++) {
        try {
            $stream = [System.IO.File]::Open(
                $path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::None
            )
            $stream.Close()
            $stream.Dispose()
            return (Get-FileHash $path -Algorithm SHA256).Hash
        } catch [System.IO.IOException] {
            # File is still open for writing
            if ($i -lt $maxRetries - 1) {
                Start-Sleep -Seconds $retryDelaySec
            }
        } catch {
            throw  # unexpected error - propagate to caller
        }
    }
    return $null  # still locked; periodic scan will pick it up
}

# Returns $true if the file should be ignored - hidden/system/temp by attribute,
# or matched by a name pattern in config.excludePatterns.
function Test-ShouldExclude($path, $config) {
    try {
        $attrs = [System.IO.File]::GetAttributes($path)
        $skip = [System.IO.FileAttributes]::Hidden -bor
                [System.IO.FileAttributes]::System -bor
                [System.IO.FileAttributes]::Temporary
        if ($attrs -band $skip) { return $true }
    } catch {
        return $false  # can't read attributes; let caller decide
    }

    if ($config.excludePatterns) {
        $name = [System.IO.Path]::GetFileName($path)
        foreach ($pattern in $config.excludePatterns) {
            if ($name -like $pattern) { return $true }
        }
    }
    return $false
}

function Initialize-Files {
    New-Item -ItemType Directory -Force -Path "$script:ProjectRoot/data" | Out-Null
    New-Item -ItemType Directory -Force -Path "$script:ProjectRoot/logs" | Out-Null

    if (!(Test-Path "$script:ProjectRoot/data/chain_log.csv")) {
        "FileName,FullPath,FileHash,Timestamp,ChainHash" | Out-File "$script:ProjectRoot/data/chain_log.csv"
    }

    if (!(Test-Path "$script:ProjectRoot/data/state.json")) {
        "{}" | Out-File "$script:ProjectRoot/data/state.json"
    }
}