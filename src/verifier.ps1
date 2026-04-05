. "$PSScriptRoot/utils.ps1"

Initialize-Files

$logFile = "$script:ProjectRoot/data/chain_log.csv"

$entries = $null
Invoke-ChainLogLock { $script:entries = @(Import-Csv $logFile) }

$prev = ""
$valid = $true

$entries | ForEach-Object {
    $calc = Get-ChainHash $_.FileHash $prev $_.Timestamp

    if ($calc -ne $_.ChainHash) {
        Write-LogEntry "ALERT" "Chain broken at $($_.FileName)"
        $valid = $false
    }

    $prev = $_.ChainHash
}

if ($valid) {
    Write-Host "Chain VALID"
} else {
    Write-Host "Chain INVALID"
}

# Git verification
$config = Import-Config
if ($config.repoPath -and (Test-Path "$($config.repoPath)/.git")) {
    try {
        $gitCheck = git -C $config.repoPath log --pretty="%G?"
        if ($gitCheck -match "N") {
            Write-Host "Unsigned commits detected"
        } else {
            Write-Host "Git signatures OK"
        }
    } catch {
        Write-Warning "Git verification failed: $_"
        Write-LogEntry "WARNING" "Git verification failed: $_"
    }
} else {
    Write-Host "Git verification skipped (no repo configured)"
}

# OpenTimestamp verify
if ($config.enableOpenTimestamps -and (Test-Path "$script:ProjectRoot/data/latest_hash.txt.ots")) {
    try {
        python -m opentimestamps_client.cmds verify "$script:ProjectRoot/data/latest_hash.txt.ots"
    } catch {
        Write-Warning "OpenTimestamps verification failed: $_"
        Write-LogEntry "WARNING" "OpenTimestamps verification failed: $_"
    }
}
