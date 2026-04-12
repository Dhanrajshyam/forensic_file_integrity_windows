param([string]$FilePath = "")

. "$PSScriptRoot/utils.ps1"

$config    = Import-Config
$timestamp = Get-Date -Format "yyyyMMddHHmmss"
$bundle    = "$script:ProjectRoot/data/evidence_bundle_$timestamp"

New-Item -ItemType Directory -Force -Path $bundle | Out-Null

# Always include chain log, OTS proof, report, and git commit record
Copy-Item "$script:ProjectRoot/data/chain_log.csv"          $bundle -ErrorAction SilentlyContinue
Copy-Item "$script:ProjectRoot/data/latest_hash.txt.ots"    $bundle -ErrorAction SilentlyContinue
# Include the most recent timestamped forensic report if one exists
$latestReport = Get-ChildItem "$script:ProjectRoot/data/forensic_report_*.txt" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latestReport) { Copy-Item $latestReport.FullName $bundle -Force }

if ($config.repoPath -and (Test-Path "$($config.repoPath)/.git")) {
    git -C "$($config.repoPath)" log -5 --pretty=fuller > "$bundle/git_log.txt" 2>&1
}

if ($FilePath) {
    # ── Single file mode ──────────────────────────────────────────────────────
    if (-not (Test-Path $FilePath)) {
        Write-Error "File not found: $FilePath"
        exit 1
    }
    Copy-Item $FilePath $bundle
    Write-Host "Bundling: $FilePath"

} else {
    # ── All files mode ────────────────────────────────────────────────────────
    # Load state.json to get full paths of all currently tracked files
    $stateRaw = (Get-Content "$script:ProjectRoot/data/state.json" -Raw).Trim()
    if ($stateRaw -ne "{}" -and $stateRaw -ne "") {
        $filesDir = Join-Path $bundle "files"
        New-Item -ItemType Directory -Force -Path $filesDir | Out-Null

        ($stateRaw | ConvertFrom-Json).PSObject.Properties | ForEach-Object {
            $fullPath = $_.Name.Replace("/", "\")
            if (Test-Path $fullPath) {
                try {
                    # Preserve subfolders relative to the drive root to avoid
                    # name collisions when multiple folders are watched
                    $relative = $fullPath -replace '^[A-Za-z]:\\', ''
                    $dest     = Join-Path $filesDir $relative
                    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
                    Copy-Item $fullPath $dest -Force
                } catch {
                    Write-Warning "Could not copy $fullPath`: $_"
                }
            }
        }
        Write-Host "Bundled all tracked files into: $filesDir"
    }
}

Compress-Archive -Path "$bundle\*" -DestinationPath "$bundle.zip" -Force
Remove-Item $bundle -Recurse -Force

Write-Host "Bundle created: $bundle.zip"
