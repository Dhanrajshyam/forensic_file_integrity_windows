param([string]$FilePath)

. "$PSScriptRoot/utils.ps1"

if (-not $FilePath -or -not (Test-Path $FilePath)) {
    Write-Error "File not found: $FilePath"
    exit 1
}

$config = Import-Config
$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$bundle = "$script:ProjectRoot/data/evidence_bundle_$timestamp"

New-Item -ItemType Directory -Path $bundle

Copy-Item $FilePath $bundle
Copy-Item "$script:ProjectRoot/data/chain_log.csv" $bundle -ErrorAction SilentlyContinue
Copy-Item "$script:ProjectRoot/data/latest_hash.txt.ots" $bundle -ErrorAction SilentlyContinue
Copy-Item "$script:ProjectRoot/data/forensic_report.txt" $bundle -ErrorAction SilentlyContinue

if ($config.repoPath -and (Test-Path "$($config.repoPath)/.git")) {
    git -C $config.repoPath log -1 > "$bundle/git_commit.txt"
}

Compress-Archive -Path $bundle -DestinationPath "$bundle.zip"

Write-Host "Bundle created: $bundle.zip"
