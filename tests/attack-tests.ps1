param(
    [string]$TestFile
)

. "$PSScriptRoot/../src/utils.ps1"

if (-not $TestFile) {
    $TestFile = "$script:ProjectRoot/data/test_video.mp4"
}

$logFile = "$script:ProjectRoot/data/chain_log.csv"
$script:passed = 0
$script:failed = 0

Write-Host "==============================="
Write-Host "FORENSIC ATTACK TEST SUITE"
Write-Host "==============================="

function Write-ChainCsv($rows, $path) {
    $lines = @("FileName,FileHash,Timestamp,ChainHash")
    foreach ($row in $rows) {
        $lines += "$($row.FileName),$($row.FileHash),$($row.Timestamp),$($row.ChainHash)"
    }
    $lines | Out-File $path
}

function Reset-State {
    Remove-Item "$script:ProjectRoot/data/chain_log.csv" -ErrorAction SilentlyContinue
    Remove-Item "$script:ProjectRoot/data/state.json" -ErrorAction SilentlyContinue
    Remove-Item "$script:ProjectRoot/logs/system_log.jsonl" -ErrorAction SilentlyContinue
    Remove-Item $TestFile -ErrorAction SilentlyContinue
    Initialize-Files
}

function Start-InitialSetup {
    if (!(Test-Path $TestFile)) {
        "dummydata" | Out-File $TestFile
    }

    $hash = (Get-FileHash $TestFile -Algorithm SHA256).Hash
    $timestamp = Get-Timestamp
    $chain = Get-ChainHash $hash "" $timestamp

    "$([System.IO.Path]::GetFileName($TestFile)),$hash,$timestamp,$chain" | Out-File $logFile -Append
}

function Start-MultiEntrySetup {
    Start-InitialSetup

    # Second entry
    $prevChain = (Import-Csv $logFile | Select-Object -Last 1).ChainHash
    Add-Content $TestFile "second"
    $hash2 = (Get-FileHash $TestFile -Algorithm SHA256).Hash
    $ts2 = Get-Timestamp
    $chain2 = Get-ChainHash $hash2 $prevChain $ts2
    "$([System.IO.Path]::GetFileName($TestFile)),$hash2,$ts2,$chain2" | Out-File $logFile -Append

    # Third entry
    Add-Content $TestFile "third"
    $hash3 = (Get-FileHash $TestFile -Algorithm SHA256).Hash
    $ts3 = Get-Timestamp
    $chain3 = Get-ChainHash $hash3 $chain2 $ts3
    "$([System.IO.Path]::GetFileName($TestFile)),$hash3,$ts3,$chain3" | Out-File $logFile -Append
}

function Confirm-TestResult($testName, $condition) {
    if ($condition) {
        Write-Host "PASS: $testName"
        $script:passed++
    } else {
        Write-Host "FAIL: $testName"
        $script:failed++
    }
}

function Test-ChainIntegrity {
    $prev = ""
    $valid = $true
    Import-Csv $logFile | ForEach-Object {
        $calc = Get-ChainHash $_.FileHash $prev $_.Timestamp
        if ($calc -ne $_.ChainHash) {
            $valid = $false
        }
        $prev = $_.ChainHash
    }
    return $valid
}

# ==============================
# TEST 1: File Tampering
# ==============================
function Test-FileTampering {
    Write-Host "`n[TEST 1] File Tampering"

    Add-Content $TestFile "tampered"

    $currentHash = (Get-FileHash $TestFile -Algorithm SHA256).Hash
    $record = Import-Csv $logFile | Select-Object -Last 1

    Confirm-TestResult "Tampering detected" ($currentHash -ne $record.FileHash)
}

# ==============================
# TEST 2: Log Tampering
# ==============================
function Test-LogTampering {
    Write-Host "`n[TEST 2] Log Tampering"

    $rows = @(Import-Csv $logFile)
    $rows[0].FileHash = "FAKEHASH"
    Write-ChainCsv $rows $logFile

    Confirm-TestResult "Log tampering detected" (-not (Test-ChainIntegrity))
}

# ==============================
# TEST 3: Fake Recompute Attack
# ==============================
function Test-FakeRecompute {
    Write-Host "`n[TEST 3] Fake Recompute Attack"

    Add-Content $TestFile "tampered"
    $newHash = (Get-FileHash $TestFile -Algorithm SHA256).Hash

    $rows = @(Import-Csv $logFile)
    $rows[-1].FileHash = $newHash
    Write-ChainCsv $rows $logFile

    Confirm-TestResult "Fake recompute detected" (-not (Test-ChainIntegrity))
}

# ==============================
# TEST 4: Chain Deletion Attack
# ==============================
function Test-ChainDeletion {
    Write-Host "`n[TEST 4] Chain Deletion Attack"

    $rows = @(Import-Csv $logFile)
    # Remove first entry — remaining entries depend on deleted chain hash
    $rows = $rows[1..($rows.Count - 1)]
    Write-ChainCsv $rows $logFile

    Confirm-TestResult "Chain deletion detected" (-not (Test-ChainIntegrity))
}

# ==============================
# TEST 5: Timestamp Manipulation
# ==============================
function Test-TimestampTampering {
    Write-Host "`n[TEST 5] Timestamp Tampering"

    $rows = @(Import-Csv $logFile)
    $rows[0].Timestamp = "2000-01-01T00:00:00Z"
    Write-ChainCsv $rows $logFile

    Confirm-TestResult "Timestamp tampering detected" (-not (Test-ChainIntegrity))
}

# ==============================
# RUN ALL TESTS
# ==============================

Reset-State
Start-InitialSetup
Test-FileTampering

Reset-State
Start-InitialSetup
Test-LogTampering

Reset-State
Start-InitialSetup
Test-FakeRecompute

Reset-State
Start-MultiEntrySetup
Test-ChainDeletion

Reset-State
Start-InitialSetup
Test-TimestampTampering

Write-Host "`n==============================="
Write-Host "TEST SUITE COMPLETED"
Write-Host "$($script:passed) passed, $($script:failed) failed out of 5 tests"
Write-Host "==============================="

exit $script:failed
