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

$prev    = ""
$valid   = $true
$broken  = [System.Collections.Generic.List[string]]@()

foreach ($entry in $entries) {
    $calc = Get-ChainHash $entry.FileHash $prev $entry.Timestamp

    if ($calc -ne $entry.ChainHash) {
        Write-LogEntry "ALERT" "Chain broken at $($entry.FileName)"
        $valid = $false
        $broken.Add($entry.FileName) | Out-Null
    }

    $prev = $entry.ChainHash
}

if ($valid) {
    Out-Result "Chain VALID — $($entries.Count) entries verified"
} else {
    Out-Result "Chain INVALID"
    Out-Result "  Broken at entries: $($broken -join ', ')"
}

# Git signature verification
$config = Import-Config
if ($config.repoPath -and (Test-Path "$($config.repoPath)/.git")) {
    try {
        # --pretty=%G? returns one char per commit: G=good N=no-sig B=bad
        $gitCheck = git -C $config.repoPath log --pretty="%G?" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Out-Result "Git verification failed (exit $LASTEXITCODE)"
            Write-LogEntry "WARNING" "git log failed: $gitCheck"
        } elseif ($gitCheck -match "N") {
            Out-Result "WARNING: Unsigned commits detected"
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

# OpenTimestamp verification
if ($config.enableOpenTimestamps -and
    (Test-Path "$script:ProjectRoot/data/latest_hash.txt.ots")) {
    try {
        $otsResult = python -m opentimestamps_client.cmds verify `
            "$script:ProjectRoot/data/latest_hash.txt.ots" 2>&1
        Out-Result "OpenTimestamps: $otsResult"
    } catch {
        Write-Warning "OpenTimestamps verification failed: $_"
        Write-LogEntry "WARNING" "OpenTimestamps verification failed: $_"
    }
}

if ($OutputPath) {
    $output | Out-File $OutputPath -Encoding UTF8
}
