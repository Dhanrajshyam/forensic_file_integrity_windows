param([string]$FilePath)

. "$PSScriptRoot/utils.ps1"

$logFile = "$script:ProjectRoot/data/chain_log.csv"
$output = "$script:ProjectRoot/data/forensic_report.txt"

if (!(Test-Path $FilePath)) {
    Write-Host "File not found"
    exit
}

$file = Get-Item $FilePath
$currentHash = (Get-FileHash $FilePath -Algorithm SHA256).Hash

$allEntries = $null
Invoke-ChainLogLock { $script:allEntries = @(Import-Csv $logFile) }

$entries = $allEntries | Where-Object { $_.FileName -eq $file.Name }

if ($entries.Count -eq 0) {
    Write-Host "No record found"
    exit
}

$last = $entries[-1]

# Chain validation
$prev = ""
$chainValid = $true

$allEntries | ForEach-Object {
    $calc = Get-ChainHash $_.FileHash $prev $_.Timestamp
    if ($calc -ne $_.ChainHash) { $chainValid = $false }
    $prev = $_.ChainHash
}

$match = ($currentHash -eq $last.FileHash)

$first = $entries[0]
$entryCount = @($entries).Count
$totalChainLength = $allEntries.Count

$report = @()
$report += "FORENSIC REPORT"
$report += "Generated: $(Get-Timestamp)"
$report += "========================================"
$report += ""
$report += "File: $($file.Name)"
$report += "Full Path: $($file.FullName)"
$report += "File Size: $($file.Length) bytes"
$report += "Last Modified: $($file.LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ssK'))"
$report += ""
$report += "Current Hash: $currentHash"
$report += "Recorded Hash: $($last.FileHash)"
$report += "Hash Match: $match"
$report += ""
$report += "Chain Entries for File: $entryCount"
$report += "Total Chain Length: $totalChainLength"
$report += "First Recorded: $($first.Timestamp)"
$report += "Last Recorded: $($last.Timestamp)"
$report += "Chain Valid: $chainValid"
$report += ""
$report += "========================================"

if ($match -and $chainValid) {
    $report += "STATUS: VERIFIED"
} else {
    $report += "STATUS: TAMPERING DETECTED"
}

$report | Out-File $output

Write-Host "Report generated: $output"