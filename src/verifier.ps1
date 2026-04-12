param([string]$OutputPath = "")

. "$PSScriptRoot/utils.ps1"

Initialize-Files

$logFile = "$script:ProjectRoot/data/chain_log.csv"
$output  = [System.Collections.ArrayList]@()

function Out-Result($message) {
    Write-Host $message
    $output.Add($message) | Out-Null
}

$entries = $null
Invoke-ChainLogLock { $script:entries = @(Import-Csv $logFile) }

$prev  = ""
$valid = $true

foreach ($entry in $entries) {
    $calc = Get-ChainHash $entry.FileHash $prev $entry.Timestamp

    if ($calc -ne $entry.ChainHash) {
        Write-LogEntry "ALERT" "Chain broken at $($entry.FileName)"
        $valid = $false
    }

    $prev = $entry.ChainHash
}

if ($valid) {
    Out-Result "Chain VALID"
} else {
    Out-Result "Chain INVALID"
}

# Git verification
$config = Import-Config
if ($config.repoPath -and (Test-Path "$($config.repoPath)/.git")) {
    try {
        $gitCheck = git -C $config.repoPath log --pretty="%G?"
        if ($gitCheck -match "N") {
            Out-Result "Unsigned commits detected"
        } else {
            Out-Result "Git signatures OK"
        }
    } catch {
        Write-Warning "Git verification failed: $_"
        Write-LogEntry "WARNING" "Git verification failed: $_"
    }
} else {
    Out-Result "Git verification skipped (no repo configured)"
}

# OpenTimestamp verify
if ($config.enableOpenTimestamps -and (Test-Path "$script:ProjectRoot/data/latest_hash.txt.ots")) {
    try {
        $otsResult = python -m opentimestamps_client.cmds verify "$script:ProjectRoot/data/latest_hash.txt.ots" 2>&1
        Out-Result "OpenTimestamps: $otsResult"
    } catch {
        Write-Warning "OpenTimestamps verification failed: $_"
        Write-LogEntry "WARNING" "OpenTimestamps verification failed: $_"
    }
}

if ($OutputPath) {
    $output | Out-File $OutputPath -Encoding UTF8
}
