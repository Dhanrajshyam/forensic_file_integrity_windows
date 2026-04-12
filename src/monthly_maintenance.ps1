. "$PSScriptRoot/utils.ps1"

$config = Import-Config
$month  = Get-Date -Format "yyyy-MM"
$ts     = Get-Date -Format "yyyyMMddHHmmss"

Write-Host "Running monthly maintenance for $month..."

# Destination folders inside the repo
$repoBase = "$($config.repoPath)/$($config.systemName)"
foreach ($d in @("reports", "verifier_reports", "audit_reports")) {
    New-Item -ItemType Directory -Force -Path "$repoBase/$d" | Out-Null
}

# --- Forensic report (all files mode) ---
Write-Host "Generating forensic report..."
& "$PSScriptRoot/report.ps1"
$latestReport = Get-ChildItem "$script:ProjectRoot/data/forensic_report_*.txt" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latestReport) {
    Copy-Item $latestReport.FullName "$repoBase/reports/forensic_report_$month.txt" -Force
    Write-Host "Forensic report saved: reports/forensic_report_$month.txt"
}

# --- Verifier report ---
Write-Host "Running verifier..."
$verifierOut = "$script:ProjectRoot/data/verifier_report_$ts.txt"
& "$PSScriptRoot/verifier.ps1" -OutputPath $verifierOut
if (Test-Path $verifierOut) {
    Copy-Item $verifierOut "$repoBase/verifier_reports/verifier_report_$month.txt" -Force
    Write-Host "Verifier report saved: verifier_reports/verifier_report_$month.txt"
}

# --- Audit report ---
Write-Host "Running audit..."
& "$PSScriptRoot/audit.ps1"
$latestAudit = Get-ChildItem "$script:ProjectRoot/data/audit_report_*.txt" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latestAudit) {
    Copy-Item $latestAudit.FullName "$repoBase/audit_reports/audit_report_$month.txt" -Force
    Write-Host "Audit report saved: audit_reports/audit_report_$month.txt"
}

# --- Commit and push to git ---
if ($config.repoPath -and (Test-Path "$($config.repoPath)/.git")) {
    $rel    = $config.systemName
    $gpgArg = if ($config.gpgKeyId) { "--gpg-sign=$($config.gpgKeyId)" } else { "--gpg-sign" }

    git -C $config.repoPath add "$rel/reports/" "$rel/verifier_reports/" "$rel/audit_reports/" 2>&1 | Out-Null
    git -C $config.repoPath commit -m "[monthly-maintenance] $($config.systemName) $month" $gpgArg 2>&1 | Out-Null
    git -C $config.repoPath push --set-upstream origin HEAD 2>&1 | Out-Null
    Write-Host "Monthly reports committed and pushed to git"
}

Write-Host "Monthly maintenance complete."
