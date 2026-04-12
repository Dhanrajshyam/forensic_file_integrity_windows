param([string]$FilePath = "")

. "$PSScriptRoot/utils.ps1"

$logFile = "$script:ProjectRoot/data/chain_log.csv"
$ts      = Get-Date -Format "yyyyMMddHHmmss"
$output  = "$script:ProjectRoot/data/forensic_report_$ts.txt"
$config  = Import-Config

$allEntries = $null
Invoke-ChainLogLock { $script:allEntries = @(Import-Csv $logFile) }

# Validate the full chain once - used in both modes.
# foreach statement runs in the current scope, unlike ForEach-Object which
# creates a child scope where assignments to $chainValid would be invisible here.
$prev       = ""
$chainValid = $true
foreach ($entry in $allEntries) {
    $calc = Get-ChainHash $entry.FileHash $prev $entry.Timestamp
    if ($calc -ne $entry.ChainHash) { $chainValid = $false }
    $prev = $entry.ChainHash
}

$report = @()
$report += "FORENSIC FILE INTEGRITY REPORT"
$report += "Generated     : $(Get-Timestamp)"
$report += "System        : $($config.systemName)"
$report += "Chain Entries : $($allEntries.Count)"
$report += "Chain Valid   : $chainValid"
$report += "========================================"

if ($FilePath) {
    # ── Single file mode ──────────────────────────────────────────────────────
    $fileName = [System.IO.Path]::GetFileName($FilePath)
    # Prefer FullPath match (unambiguous); fall back to FileName for entries
    # written before the FullPath column was added.
    $entries  = @($allEntries | Where-Object {
        ($_.FullPath -and $_.FullPath -eq $FilePath) -or
        (-not $_.FullPath -and $_.FileName -eq $fileName)
    })

    if ($entries.Count -eq 0) {
        Write-Host "No chain record found for: $fileName"
        exit
    }

    $last      = $entries[-1]
    $first     = $entries[0]
    $isDeleted = $last.FileHash -like "DELETED:*"

    $report += ""
    $report += "File           : $fileName"
    $report += "Requested Path : $FilePath"
    $report += "Chain Entries  : $($entries.Count)"
    $report += "First Recorded : $($first.Timestamp)"

    if ($isDeleted) {
        $lastHash = $last.FileHash -replace "^DELETED:", ""
        $report += "Last Hash      : $lastHash"
        $report += "Deleted At     : $($last.Timestamp)"
        $report += ""
        $report += "========================================"
        $report += "STATUS: DELETED (deletion recorded in chain)"
    } elseif (-not (Test-Path $FilePath)) {
        $report += "Recorded Hash  : $($last.FileHash)"
        $report += "Last Recorded  : $($last.Timestamp)"
        $report += ""
        $report += "========================================"
        $report += "STATUS: FILE MISSING (not on disk, no deletion record)"
    } else {
        $file        = Get-Item $FilePath
        $currentHash = (Get-FileHash $FilePath -Algorithm SHA256).Hash
        $match       = ($currentHash -eq $last.FileHash)

        $report += "Full Path      : $($file.FullName)"
        $report += "File Size      : $($file.Length) bytes"
        $report += "Last Modified  : $($file.LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ssK'))"
        $report += "Current Hash   : $currentHash"
        $report += "Recorded Hash  : $($last.FileHash)"
        $report += "Hash Match     : $match"
        $report += "Last Recorded  : $($last.Timestamp)"
        $report += ""
        $report += "========================================"
        if ($match -and $chainValid) {
            $report += "STATUS: VERIFIED"
        } else {
            $report += "STATUS: TAMPERING DETECTED"
        }
    }

} else {
    # ── All files mode ────────────────────────────────────────────────────────

    # Load state.json - full paths of currently tracked files
    $stateRaw     = (Get-Content "$script:ProjectRoot/data/state.json" -Raw).Trim()
    $trackedFiles = @{}
    if ($stateRaw -ne "{}" -and $stateRaw -ne "") {
        ($stateRaw | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
            $trackedFiles[$_.Name] = $_.Value
        }
    }

    # Find files whose most recent chain entry is a deletion record.
    # Key by FullPath when available; fall back to FileName for old entries.
    $lastByKey = @{}
    foreach ($entry in $allEntries) {
        $key = if ($entry.FullPath) { $entry.FullPath } else { $entry.FileName }
        $lastByKey[$key] = $entry
    }
    $deletedFiles = [ordered]@{}
    foreach ($key in $lastByKey.Keys) {
        if ($lastByKey[$key].FileHash -like "DELETED:*") {
            $deletedFiles[$key] = $lastByKey[$key]
        }
    }

    $verified = 0; $modified = 0; $missing = 0

    $report += ""
    $report += "CURRENTLY TRACKED FILES ($($trackedFiles.Count))"
    $report += "----------------------------------------"

    $idx = 1
    foreach ($stateKey in ($trackedFiles.Keys | Sort-Object)) {
        $fullPath     = $stateKey.Replace("/", "\")
        $fileName     = [System.IO.Path]::GetFileName($fullPath)
        $recordedHash = $trackedFiles[$stateKey]
        $fileEntries  = @($allEntries | Where-Object {
            ($_.FullPath -and $_.FullPath -eq $fullPath) -or
            (-not $_.FullPath -and $_.FileName -eq $fileName)
        })
        $firstTs      = if ($fileEntries.Count -gt 0) { $fileEntries[0].Timestamp  } else { "N/A" }
        $lastTs       = if ($fileEntries.Count -gt 0) { $fileEntries[-1].Timestamp } else { "N/A" }

        $report += ""
        $report += "[$idx] $fileName"
        $report += "    Path           : $fullPath"
        $report += "    First Recorded : $firstTs"
        $report += "    Last Recorded  : $lastTs"

        if (Test-Path $fullPath) {
            try {
                $currentHash = (Get-FileHash $fullPath -Algorithm SHA256).Hash
                $match = ($currentHash -eq $recordedHash)
                $report += "    Current Hash   : $currentHash"
                $report += "    Recorded Hash  : $recordedHash"
                $report += "    Hash Match     : $match"
                if ($match) { $report += "    STATUS: VERIFIED"; $verified++ }
                else        { $report += "    STATUS: MODIFIED - TAMPERING DETECTED"; $modified++ }
            } catch {
                $report += "    ERROR: Could not read file - $_"
                $missing++
            }
        } else {
            $report += "    Recorded Hash  : $recordedHash"
            $report += "    STATUS: FILE MISSING (not on disk, no deletion record)"
            $missing++
        }
        $idx++
    }

    if ($deletedFiles.Count -gt 0) {
        $report += ""
        $report += "DELETED FILES ($($deletedFiles.Count) - deletion recorded in chain)"
        $report += "----------------------------------------"
        $idx = 1
        foreach ($name in $deletedFiles.Keys) {
            $entry    = $deletedFiles[$name]
            $lastHash = $entry.FileHash -replace "^DELETED:", ""
            $report += ""
            $report += "[$idx] $name"
            $report += "    Last Hash  : $lastHash"
            $report += "    Deleted At : $($entry.Timestamp)"
            $report += "    STATUS: DELETED (recorded)"
            $idx++
        }
    }

    $overall = if ($modified -eq 0 -and $missing -eq 0 -and $chainValid) { "ALL VERIFIED" } else { "ISSUES FOUND" }

    $report += ""
    $report += "========================================"
    $report += "SUMMARY"
    $report += "  Verified : $verified"
    $report += "  Modified : $modified"
    $report += "  Missing  : $missing"
    $report += "  Deleted  : $($deletedFiles.Count)"
    $report += "  Chain    : $(if ($chainValid) { 'VALID' } else { 'INVALID' })"
    $report += "  Overall  : $overall"
}

$report | Out-File $output -Encoding UTF8
Write-Host "Report generated: $output"
