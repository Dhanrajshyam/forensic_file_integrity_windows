. "$PSScriptRoot/utils.ps1"

$config = Import-Config

function Write-Section($title) {
    Write-Host ""
    Write-Host "── $title " -NoNewline
    Write-Host ("─" * (50 - $title.Length)) -ForegroundColor DarkGray
}

function Write-Ok($label, $value) {
    Write-Host ("  {0,-24} " -f $label) -NoNewline
    Write-Host $value -ForegroundColor Green
}

function Write-Warn($label, $value) {
    Write-Host ("  {0,-24} " -f $label) -NoNewline
    Write-Host $value -ForegroundColor Yellow
}

function Write-Bad($label, $value) {
    Write-Host ("  {0,-24} " -f $label) -NoNewline
    Write-Host $value -ForegroundColor Red
}

Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   Forensic File Integrity — Status   ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan

# ── Watcher process ───────────────────────────────────────────────────────────

Write-Section "Watcher Process"
$procs = @(Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*watcher.ps1*" })
if ($procs.Count -gt 0) {
    Write-Ok  "Status"    "RUNNING (pid $($procs[0].ProcessId))"
} else {
    Write-Bad "Status"    "NOT RUNNING"
}

# ── Last log entry ────────────────────────────────────────────────────────────

Write-Section "Recent Activity"
$logFile = "$script:ProjectRoot/logs/system_log.jsonl"
if (Test-Path $logFile) {
    $lastLine = Get-Content $logFile -Tail 1
    if ($lastLine) {
        $entry   = $lastLine | ConvertFrom-Json
        # ConvertFrom-Json may return a DateTime or a string depending on PS version
        $logTime = if ($entry.time -is [datetime]) {
            $entry.time
        } else {
            [datetime]::Parse([string]$entry.time, $null,
                [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
        $elapsed = [int]([datetime]::Now - $logTime).TotalMinutes
        $label   = if ($elapsed -lt 2) { "just now" } else { "$elapsed min ago" }
        $msg     = [string]$entry.message
        Write-Ok "Last log entry"   "$($entry.type): $($msg.Substring(0, [Math]::Min(60, $msg.Length)))"
        Write-Ok "Logged at"        "$logTime  ($label)"
    }
} else {
    Write-Warn "Log file" "not found at $logFile"
}

# ── Chain log ─────────────────────────────────────────────────────────────────

Write-Section "Chain Log"
$chainLog = "$script:ProjectRoot/data/chain_log.csv"
if (Test-Path $chainLog) {
    $lines    = @(Get-Content $chainLog)
    $count    = [Math]::Max(0, $lines.Count - 1)   # minus header
    $lastEntry = if ($lines.Count -ge 2) { $lines[-1] } else { "" }
    Write-Ok "Entries"    "$count"
    if ($lastEntry) {
        $cols = $lastEntry -split ","
        Write-Ok "Last file"   $cols[0]
        Write-Ok "Last hashed" $cols[3]
    }
} else {
    Write-Warn "Chain log" "not found at $chainLog"
}

# ── Git repo ──────────────────────────────────────────────────────────────────

Write-Section "Git Repository"
$repo = $config.repoPath
if ($repo -and (Test-Path "$repo/.git")) {
    $branch  = git -C $repo rev-parse --abbrev-ref HEAD 2>&1
    $wantBr  = if ($config.gitBranch) { $config.gitBranch } else { "main" }
    if ($branch -eq $wantBr) {
        Write-Ok  "Branch"   $branch
    } else {
        Write-Warn "Branch"  "$branch  (expected: $wantBr)"
    }

    # Staged / unstaged counts
    $staged   = @(git -C $repo diff --cached --name-only 2>&1).Count
    $unstaged = @(git -C $repo diff --name-only 2>&1).Count
    if ($staged -gt 0) {
        Write-Warn "Staged (uncommitted)"  "$staged file(s)"
    } else {
        Write-Ok   "Staged (uncommitted)"  "none"
    }
    if ($unstaged -gt 0) {
        Write-Warn "Unstaged changes"      "$unstaged file(s)"
    } else {
        Write-Ok   "Unstaged changes"      "none"
    }

    # Last commit
    $lastCommit = git -C $repo log --oneline -1 2>&1
    Write-Ok "Last commit"  $lastCommit

    # Ahead/behind
    git -C $repo fetch --quiet 2>&1 | Out-Null
    $ahead = (git -C $repo rev-list "@{u}..HEAD" 2>&1 | Measure-Object -Line).Lines
    if ($ahead -gt 0) {
        Write-Warn "Pending push"  "YES — $ahead commit(s) not yet pushed"
    } else {
        Write-Ok   "Pending push"  "none"
    }
} else {
    Write-Warn "Git repo"  "not configured or missing .git at $repo"
}

# ── OpenTimestamps ────────────────────────────────────────────────────────────

Write-Section "OpenTimestamps"
$otsFile = "$script:ProjectRoot/data/latest_hash.txt.ots"
if ($config.enableOpenTimestamps) {
    if (Test-Path $otsFile) {
        $otsAge = [int]([datetime]::Now - (Get-Item $otsFile).LastWriteTime).TotalHours
        Write-Ok "OTS proof"  "present  (last updated ${otsAge}h ago)"
    } else {
        Write-Warn "OTS proof"  "not yet created (will appear after first scan)"
    }
} else {
    Write-Ok "OpenTimestamps" "disabled in config"
}

Write-Host ""
