. "$PSScriptRoot/utils.ps1"

$logFile = "$script:ProjectRoot/data/chain_log.csv"
$config  = Import-Config
$ts      = Get-Date -Format "yyyyMMddHHmmss"
$output  = "$script:ProjectRoot/data/audit_report_$ts.txt"

$allEntries = $null
Invoke-ChainLogLock { $script:allEntries = @(Import-Csv $logFile) }

$report = @()
$report += "FORENSIC FILE AUDIT REPORT"
$report += "Generated : $(Get-Timestamp)"
$report += "System    : $($config.systemName)"
$report += "========================================"

# ---------------------------------------------------------------------------
# Section 1: Files with more than one recorded hash (modification history)
# ---------------------------------------------------------------------------

$report += ""
$report += "FILES WITH MODIFICATION HISTORY (multiple hashes recorded)"
$report += "----------------------------------------"

$modified = @()

# Group by FullPath when available (unambiguous); fall back to FileName for
# entries written before the FullPath column was added.
$grouped = @{}
foreach ($entry in $allEntries) {
    $key = if ($entry.FullPath) { $entry.FullPath } else { $entry.FileName }
    if (-not $grouped.ContainsKey($key)) { $grouped[$key] = [System.Collections.ArrayList]@() }
    $grouped[$key].Add($entry) | Out-Null
}

foreach ($key in $grouped.Keys) {
    $distinctHashes = $grouped[$key] |
        Where-Object { $_.FileHash -notlike "DELETED:*" } |
        Select-Object -ExpandProperty FileHash -Unique
    if ($distinctHashes.Count -gt 1) {
        $modified += [PSCustomObject]@{ Key = $key; Entries = $grouped[$key] }
    }
}

if ($modified.Count -eq 0) {
    $report += "  (none)"
} else {
    $idx = 1
    foreach ($item in $modified) {
        $report += ""
        $report += "[$idx] $($item.Key)  ($($item.Entries.Count) chain entries)"
        foreach ($entry in $item.Entries) {
            if ($entry.FileHash -like "DELETED:*") {
                $display = $entry.FileHash
            } else {
                $display = $entry.FileHash.Substring(0, 16) + "..."
            }
            $report += "    $($entry.Timestamp)  $display"
        }
        $idx++
    }
}

# ---------------------------------------------------------------------------
# Section 2: Tracked files not found on disk (no deletion record)
# ---------------------------------------------------------------------------

$report += ""
$report += "TRACKED FILES NOT FOUND ON DISK (no deletion record)"
$report += "----------------------------------------"

$stateRaw = (Get-Content "$script:ProjectRoot/data/state.json" -Raw).Trim()
$trackedFiles = @{}
if ($stateRaw -ne "{}" -and $stateRaw -ne "") {
    ($stateRaw | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
        $trackedFiles[$_.Name] = $_.Value
    }
}

$notFound = @()
foreach ($stateKey in $trackedFiles.Keys) {
    $fullPath = $stateKey.Replace("/", "\")
    if (-not (Test-Path $fullPath)) {
        $fileName   = [System.IO.Path]::GetFileName($fullPath)
        $fileEntries = @($allEntries | Where-Object {
            ($_.FullPath -and $_.FullPath -eq $fullPath) -or
            (-not $_.FullPath -and $_.FileName -eq $fileName)
        })
        $lastEntry   = if ($fileEntries.Count -gt 0) { $fileEntries[-1] } else { $null }

        # Skip if the chain log recorded a deletion - those appear in the deleted section
        if ($lastEntry -and $lastEntry.FileHash -like "DELETED:*") { continue }

        $notFound += [PSCustomObject]@{
            Path     = $fullPath
            LastHash = $trackedFiles[$stateKey]
            LastSeen = if ($lastEntry) { $lastEntry.Timestamp } else { "N/A" }
        }
    }
}

if ($notFound.Count -eq 0) {
    $report += "  (all tracked files found on disk)"
} else {
    $idx = 1
    foreach ($item in $notFound) {
        $report += ""
        $report += "[$idx] $([System.IO.Path]::GetFileName($item.Path))"
        $report += "    Path      : $($item.Path)"
        $report += "    Last Hash : $($item.LastHash)"
        $report += "    Last Seen : $($item.LastSeen)"
        $report += "    STATUS    : MISSING - in state but not on disk, no deletion recorded"
        $idx++
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$report += ""
$report += "========================================"
$report += "SUMMARY"
$report += "  Files with modification history : $($modified.Count)"
$report += "  Missing (no deletion record)    : $($notFound.Count)"

$report | Out-File $output -Encoding UTF8
$report | ForEach-Object { Write-Host $_ }
Write-Host ""
Write-Host "Audit report saved: $output"
