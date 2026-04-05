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

function Initialize-Files {
    if (!(Test-Path "$script:ProjectRoot/data/chain_log.csv")) {
        "FileName,FileHash,Timestamp,ChainHash" | Out-File "$script:ProjectRoot/data/chain_log.csv"
    }

    if (!(Test-Path "$script:ProjectRoot/data/state.json")) {
        "{}" | Out-File "$script:ProjectRoot/data/state.json"
    }
}