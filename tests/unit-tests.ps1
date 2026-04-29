. "$PSScriptRoot/../src/utils.ps1"

$script:passed = 0
$script:failed = 0

function Confirm-TestResult($testName, $condition) {
    if ($condition) {
        Write-Host "PASS: $testName"
        $script:passed++
    } else {
        Write-Host "FAIL: $testName"
        $script:failed++
    }
}

Write-Host "==============================="
Write-Host "FORENSIC UNIT TEST SUITE"
Write-Host "==============================="

# ── Get-ChainHash ─────────────────────────────────────────────────────────────

Write-Host "`n[GROUP 1] Get-ChainHash"

$_ts = "2024-01-01T00:00:00+0000"

Confirm-TestResult "produces 64-char lowercase hex" (
    (Get-ChainHash "abc" "def" $_ts).Length -eq 64 -and
    (Get-ChainHash "abc" "def" $_ts) -cmatch '^[0-9a-f]{64}$'
)

$_r1 = Get-ChainHash "h1" "p1" "2024-06-01T12:00:00+0000"
$_r2 = Get-ChainHash "h1" "p1" "2024-06-01T12:00:00+0000"
Confirm-TestResult "is deterministic" ($_r1 -eq $_r2)

Confirm-TestResult "changes when file hash changes" (
    (Get-ChainHash "A" "prev" $_ts) -ne (Get-ChainHash "B" "prev" $_ts)
)

Confirm-TestResult "changes when prev hash changes" (
    (Get-ChainHash "h" "prev1" $_ts) -ne (Get-ChainHash "h" "prev2" $_ts)
)

Confirm-TestResult "changes when timestamp changes" (
    (Get-ChainHash "h" "p" "2024-01-01T00:00:00+0000") -ne
    (Get-ChainHash "h" "p" "2024-01-02T00:00:00+0000")
)

# Cross-system parity: SHA256("TESTHASH|PREVHASH|2024-01-15T10:00:00+0000")
# Independently verified by Python hashlib and this PowerShell implementation.
$_expected = "d2f39af05877491d420ffb9c0fa1114f0f3d78f4d7d55a310d1f83f465e3699b"
$_actual   = Get-ChainHash "TESTHASH" "PREVHASH" "2024-01-15T10:00:00+0000"
Confirm-TestResult "cross-system parity with Python (SHA256 formula)" (
    $_actual -eq $_expected
)

# ── Test-ShouldExclude ────────────────────────────────────────────────────────

Write-Host "`n[GROUP 2] Test-ShouldExclude"

# Build a minimal config object; Test-ShouldExclude also checks file attributes,
# so we use a path known to not exist (attributes check catches and returns $false)
# and drive testing through the pattern list only.
function New-TestConfig($patterns) {
    [PSCustomObject]@{ excludePatterns = $patterns }
}

# For attribute-dependent tests we need real temp files to exist.
$_tmpDir = [System.IO.Path]::GetTempPath()
$_tmpFile = [System.IO.Path]::Combine($_tmpDir, "fi_test_$([System.Guid]::NewGuid()).tmp")
"" | Out-File $_tmpFile -Encoding UTF8

Confirm-TestResult "*.tmp pattern excludes matching file" (
    Test-ShouldExclude $_tmpFile (New-TestConfig @("*.tmp"))
)

$_mp4File = [System.IO.Path]::Combine($_tmpDir, "fi_test_$([System.Guid]::NewGuid()).mp4")
"" | Out-File $_mp4File -Encoding UTF8

Confirm-TestResult "non-matching pattern does not exclude" (
    -not (Test-ShouldExclude $_mp4File (New-TestConfig @("*.tmp", "*.part")))
)

Confirm-TestResult "empty patterns never excludes" (
    -not (Test-ShouldExclude $_mp4File (New-TestConfig @()))
)

# Test basename-only: file is inside a directory named with .tmp extension
$_innerDir = [System.IO.Path]::Combine($_tmpDir, "recordings.tmp")
New-Item -ItemType Directory -Force -Path $_innerDir | Out-Null
$_innerFile = [System.IO.Path]::Combine($_innerDir, "fi_test_video.mp4")
"" | Out-File $_innerFile -Encoding UTF8
Confirm-TestResult "basename only checked (directory .tmp does not match video.mp4)" (
    -not (Test-ShouldExclude $_innerFile (New-TestConfig @("*.tmp")))
)

# Prefix wildcard: ~$ lock files (Office temp files)
$_lockFile = [System.IO.Path]::Combine($_tmpDir, "~`$lockfile_$([System.Guid]::NewGuid())")
"" | Out-File $_lockFile -Encoding UTF8
Confirm-TestResult "~`$* prefix wildcard excludes lock file" (
    Test-ShouldExclude $_lockFile (New-TestConfig @("~`$*"))
)

# Cleanup temp files
Remove-Item $_tmpFile   -ErrorAction SilentlyContinue
Remove-Item $_mp4File   -ErrorAction SilentlyContinue
Remove-Item $_innerFile -ErrorAction SilentlyContinue
Remove-Item $_innerDir  -ErrorAction SilentlyContinue
Remove-Item $_lockFile  -ErrorAction SilentlyContinue

# ── Test-Config ───────────────────────────────────────────────────────────────

Write-Host "`n[GROUP 3] Test-Config"

# Create a temp watchPath that actually exists so the path-exists check passes
$_watchDir = [System.IO.Path]::Combine(
    [System.IO.Path]::GetTempPath(), "fi_watchtest_$([System.Guid]::NewGuid())"
)
New-Item -ItemType Directory -Force -Path $_watchDir | Out-Null

$_baseConfig = [PSCustomObject]@{
    watchPaths             = @($_watchDir)
    repoPath               = $_watchDir   # exists, so no "repoPath not set" warning
    gitBranch              = "mybranch"
    systemName             = "test_node"
    gpgKeyId               = ""
    verifyIntervalSeconds  = 300
}

# Throws when systemName missing
$_threw = $false
try {
    $c = $_baseConfig.PSObject.Copy()
    $c.systemName = $null
    Test-Config $c
} catch { $_threw = $true }
Confirm-TestResult "throws when systemName missing" $_threw

# Throws when watchPaths empty
$_threw = $false
try {
    $c = $_baseConfig.PSObject.Copy()
    $c.watchPaths = @()
    Test-Config $c
} catch { $_threw = $true }
Confirm-TestResult "throws when watchPaths empty" $_threw

# Throws when verifyIntervalSeconds <= 0
$_threw = $false
try {
    $c = $_baseConfig.PSObject.Copy()
    $c.verifyIntervalSeconds = 0
    Test-Config $c
} catch { $_threw = $true }
Confirm-TestResult "throws when verifyIntervalSeconds is 0" $_threw

# Warns when gitBranch missing (repoPath set)
$c = [PSCustomObject]@{
    watchPaths             = @($_watchDir)
    repoPath               = $_watchDir
    gitBranch              = $null
    systemName             = "test_node"
    gpgKeyId               = ""
    verifyIntervalSeconds  = 300
}
# 3>&1 merges warning stream into output stream so we can capture it.
# Test-Config has no [CmdletBinding()] so -WarningVariable is ignored; use redirection instead.
$_warnOutput = (Test-Config $c) 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }

Confirm-TestResult "warns when gitBranch not set" (
    @($_warnOutput) | Where-Object { "$_" -like "*gitBranch*" }
)

Remove-Item $_watchDir -Recurse -ErrorAction SilentlyContinue

# ── Chain log integrity (end-to-end) ─────────────────────────────────────────

Write-Host "`n[GROUP 4] Chain Log Integrity"

function Build-TestChain($tmpDir, $n = 3) {
    $log = "$tmpDir\chain_log.csv"
    "FileName,FullPath,FileHash,Timestamp,ChainHash" | Out-File $log -Encoding UTF8
    $prev = ""
    for ($i = 0; $i -lt $n; $i++) {
        $fh  = (New-Object System.Security.Cryptography.SHA256Managed).ComputeHash(
                   [System.Text.Encoding]::UTF8.GetBytes("file$i")) |
               ForEach-Object { $_.ToString("x2") }
        $fh  = $fh -join ""
        $ts  = "2024-01-0$($i+1)T00:00:00+0000"
        $ch  = Get-ChainHash $fh $prev $ts
        "f$i.mp4,`"/data/f$i.mp4`",$fh,$ts,$ch" | Out-File $log -Append -Encoding UTF8
        $prev = $ch
    }
    return $log
}

function Test-ChainFile($log) {
    $prev  = ""
    $valid = $true
    foreach ($row in @(Import-Csv $log)) {
        $calc = Get-ChainHash $row.FileHash $prev $row.Timestamp
        if ($calc -ne $row.ChainHash) { $valid = $false }
        $prev = $row.ChainHash
    }
    return $valid
}

$_tmp1 = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),
          "fi_chain_$([System.Guid]::NewGuid())")
New-Item -ItemType Directory -Force -Path $_tmp1 | Out-Null
$_log1 = Build-TestChain $_tmp1
Confirm-TestResult "clean chain verifies" (Test-ChainFile $_log1)
Remove-Item $_tmp1 -Recurse -ErrorAction SilentlyContinue

$_tmp2 = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),
          "fi_chain_$([System.Guid]::NewGuid())")
New-Item -ItemType Directory -Force -Path $_tmp2 | Out-Null
$_log2 = Build-TestChain $_tmp2
$_rows2 = @(Import-Csv $_log2)
$_rows2[0].FileHash = "FAKEHASH"
$_lines2 = @("FileName,FullPath,FileHash,Timestamp,ChainHash")
foreach ($r in $_rows2) {
    $_lines2 += "$($r.FileName),`"$($r.FullPath)`",$($r.FileHash),$($r.Timestamp),$($r.ChainHash)"
}
$_lines2 | Out-File $_log2 -Encoding UTF8
Confirm-TestResult "tampered file hash breaks chain" (-not (Test-ChainFile $_log2))
Remove-Item $_tmp2 -Recurse -ErrorAction SilentlyContinue

$_tmp3 = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),
          "fi_chain_$([System.Guid]::NewGuid())")
New-Item -ItemType Directory -Force -Path $_tmp3 | Out-Null
$_log3 = Build-TestChain $_tmp3
$_rows3 = @(Import-Csv $_log3)
$_rows3[1].Timestamp = "2000-01-01T00:00:00+0000"
$_lines3 = @("FileName,FullPath,FileHash,Timestamp,ChainHash")
foreach ($r in $_rows3) {
    $_lines3 += "$($r.FileName),`"$($r.FullPath)`",$($r.FileHash),$($r.Timestamp),$($r.ChainHash)"
}
$_lines3 | Out-File $_log3 -Encoding UTF8
Confirm-TestResult "tampered timestamp breaks chain" (-not (Test-ChainFile $_log3))
Remove-Item $_tmp3 -Recurse -ErrorAction SilentlyContinue

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "==============================="
Write-Host "RESULTS: $($script:passed) passed, $($script:failed) failed"
Write-Host "==============================="

if ($script:failed -gt 0) { exit 1 }
