# Forensic File Integrity System — User Guide

## 1. Overview

This guide covers installation, configuration, and day-to-day use of the Forensic File Integrity System.

For architecture and design details see `DESIGN.md`. For investigation workflows see `INVESTIGATION_GUIDE.md`.

---

## 2. Prerequisites

Before installing, ensure the following are available on the system:

| Requirement           | Purpose                             | Notes                                |
| --------------------- | ----------------------------------- | ------------------------------------ |
| PowerShell 5+         | Runs all scripts                    | Built into Windows 10/11             |
| Git                   | Audit trail and signed commits      | <https://git-scm.com>                |
| GPG                   | Commit signing (identity proof)     | <https://gpg4win.org>                |
| Python 3              | OpenTimestamps blockchain anchoring | <https://python.org>                 |
| opentimestamps-client | OTS proof generation/verify         | `pip install opentimestamps-client`  |

GPG and OpenTimestamps are optional. The system degrades gracefully if they are unavailable (chain integrity still works without them).

---

## 3. Installation

### 3.1 Quick install (recommended)

Run from the `installer/` directory as Administrator:

```powershell
cd installer
.\install.ps1
```

This will:

- Read `installPath` from `config/config.json`
- Copy scripts to `installPath` (e.g. `E:\ForensicSystem\`)
- Create `data\` and `logs\` directories
- Initialize a Git evidence repo at the configured `repoPath`
- Register a scheduled task (`ForensicWatcher`) that runs the watcher at system startup

### 3.2 Manual / portable install

Scripts can be run directly from the project directory without the installer:

```powershell
.\src\watcher.ps1
```

All scripts resolve paths relative to their own location using `$PSScriptRoot`, so they work correctly from any directory.

---

## 4. Configuration

Edit `config/config.json` before running:

```json
{
  "watchPaths": [
    "E:\\Recordings",
    "D:\\CameraBackup"
  ],
  "installPath": "E:\\ForensicSystem",
  "repoPath": "E:\\ForensicRepo",
  "gpgKeyId": "",
  "enableOpenTimestamps": true,
  "enablePublicAnchor": false,
  "logLevel": "INFO",
  "verifyIntervalSeconds": 300,
  "excludePatterns": [
    "*.tmp",
    "~$*",
    "*.part",
    "*.crdownload",
    "desktop.ini",
    "thumbs.db"
  ]
}
```

### Configuration Options

| Key | Type | Description |
| --- | --- | --- |
| `watchPaths` | array | Folders to monitor. Must be non-empty. Warns if path not found. |
| `installPath` | string | Where the installer copies files (e.g. `E:\ForensicSystem`). Required. |
| `repoPath` | string | Path to the Git evidence repo. Optional; disables Git if omitted. |
| `systemName` | string | Subfolder in `repoPath` for this machine (e.g. `desktop`, `android`, `truenas`). Required if `repoPath` is set. |
| `gpgKeyId` | string | GPG key ID for signed commits. Leave `""` to use GPG default key. |
| `enableOpenTimestamps` | boolean | Stamp each chain hash to the Bitcoin blockchain via OTS. |
| `enablePublicAnchor` | boolean | Publish anchor to a public location (future feature). |
| `logLevel` | string | Logging verbosity: `INFO`, `WARNING`, `ERROR`. |
| `verifyIntervalSeconds` | integer | How often (seconds) to run a full directory scan. Min 1. |
| `excludePatterns` | array | Filename glob patterns to skip (e.g. `"*.tmp"`, `"~$*"`). |

---

## 5. Running the Watcher

The watcher is the core service. It monitors configured folders and records every file event to the tamper-evident chain log.

```powershell
.\src\watcher.ps1
```

On startup it:

1. Validates configuration
2. Performs an initial full scan of all watch paths
3. Registers file system watchers for real-time event capture
4. Runs a periodic full scan every `verifyIntervalSeconds`

**Events tracked:** Created, Changed, Deleted, Renamed

Each event appends a new entry to `data/chain_log.csv` with:

- File name
- SHA-256 hash (or `DELETED:<last-hash>` for deletions)
- ISO-8601 timestamp
- Chain hash (links to previous entry)

Stop the watcher with `Ctrl+C`. It cleans up watchers and logs a stop event before exiting.

---

## 6. Verifying Chain Integrity

Run the verifier to check whether the chain log has been tampered with:

```powershell
.\src\verifier.ps1
```

Output:

```text
Chain VALID
Git signatures OK
```

Or if tampering is detected:

```text
Chain INVALID
```

The verifier also checks Git commit signatures (if `repoPath` is configured) and validates the OpenTimestamps proof (if the `.ots` file exists).

---

## 7. Generating a Forensic Report

### Report — single file

```powershell
.\src\report.ps1 -FilePath "E:\Recordings\video.mp4"
```

Checks whether the named file matches its recorded hash. Output includes current hash, recorded hash, match result, first/last recorded timestamps, chain validity, and a final status of `VERIFIED` or `TAMPERING DETECTED`. Handles deleted files (reports last known hash and deletion timestamp) and missing files with no deletion record.

### Report — all tracked files

```powershell
.\src\report.ps1
```

Iterates every file in `state.json` and every deletion record in `chain_log.csv`. Produces a full integrity report with per-file status and a summary:

```text
  Verified : 581
  Modified : 0
  Missing  : 0
  Deleted  : 3
  Chain    : VALID
  Overall  : ALL VERIFIED
```

The report is written to `data/forensic_report.txt` in both modes.

---

## 8. Creating an Evidence Bundle

### Bundle — single file

```powershell
.\src\bundle.ps1 -FilePath "E:\Recordings\video.mp4"
```

### Bundle — all tracked files

```powershell
.\src\bundle.ps1
```

Both modes produce `data/evidence_bundle_<timestamp>.zip`. The bundle always contains:

- `chain_log.csv`
- `latest_hash.txt.ots` (OpenTimestamps proof, if present)
- `forensic_report.txt`
- `git_log.txt` (last 5 Git commits, if repo is configured)

Single-file mode adds the named file. All-files mode adds every currently tracked file under a `files/` subfolder, preserving relative paths to avoid name collisions across watched directories.

This archive can be handed to a third party for independent verification.

---

## 9. Running the Audit Script

The audit script surfaces two specific conditions that the forensic report does not highlight:

```powershell
.\src\audit.ps1
```

**What it reports:**

| Section | What it shows |
| --- | --- |
| Files with modification history | Files that have more than one distinct hash recorded — i.e., the watcher observed at least one content change while it was running |
| Missing files (no deletion record) | Files tracked in `state.json` that are no longer on disk, but for which no deletion event was recorded |

Output is printed to the console and saved to `data/audit_report_<timestamp>.txt`.

**Why modifications are not flagged in the main report:**  
`report.ps1` compares the current hash against the last recorded hash. If the watcher was running when a file changed, it recorded the new hash — so the current state matches the last recorded state and the file shows `VERIFIED`. The modification is preserved in `chain_log.csv` as a second entry with a different hash. `audit.ps1` makes that history visible.

---

## 10. Weekly Maintenance

The installer registers a scheduled task (`ForensicWeeklyMaintenance`) that runs every Sunday at 02:00. It can also be run manually at any time:

```powershell
.\src\weekly_maintenance.ps1
```

It runs the forensic report, verifier, and audit script in sequence, then copies each report to the forensic Git repo under `repoPath/systemName/`:

```text
reports/          forensic_report_yyyy-MM-dd.txt
verifier_reports/ verifier_report_yyyy-MM-dd.txt
audit_reports/    audit_report_yyyy-MM-dd.txt
```

All three are committed and pushed in a single signed commit so the weekly snapshot is preserved in the tamper-evident audit trail.

To manage the task:

```powershell
# Run now (without waiting for Sunday)
Start-ScheduledTask -TaskName "ForensicWeeklyMaintenance"

# Check status
Get-ScheduledTask -TaskName "ForensicWeeklyMaintenance"

# Disable
Disable-ScheduledTask -TaskName "ForensicWeeklyMaintenance"
```

---

## 11. Running Attack Tests

The test suite simulates five attack scenarios against the chain:

```powershell
.\tests\attack-tests.ps1
```

Tests run in isolation (state is reset between each test):

| Test | Scenario                  | What is checked                            |
| ---- | ------------------------- | ------------------------------------------ |
| 1    | File tampering            | Hash mismatch detected                     |
| 2    | Log tampering             | Chain broken after CSV edit                |
| 3    | Fake recompute attack     | Chain broken even after hash update in log |
| 4    | Chain deletion            | Missing entry breaks downstream entries    |
| 5    | Timestamp manipulation    | Chain broken after timestamp edit          |

Exit code equals the number of failed tests (0 = all passed).

---

## 12. File and Directory Layout

```text
forensic-file-integrity/
  config/
    config.json                      # Configuration (edit before use)
  data/
    chain_log.csv                    # Tamper-evident hash chain (runtime)
    state.json                       # Last-known hash per file (runtime)
    forensic_report_<timestamp>.txt  # Reports generated by report.ps1 (runtime)
    audit_report_<timestamp>.txt     # Audit reports generated by audit.ps1 (runtime)
    latest_hash.txt.ots              # OpenTimestamps proof (runtime)
  logs/
    system_log.jsonl                 # Structured event log, NDJSON format (runtime)
  src/
    watcher.ps1         # File monitoring service
    verifier.ps1        # Chain and signature verifier
    report.ps1          # Forensic report generator
    audit.ps1           # Modification history and missing file audit
    bundle.ps1          # Evidence archive packager
    utils.ps1           # Shared utility functions
  tests/
    attack-tests.ps1    # Attack simulation test suite
  installer/
    install.ps1         # System installer (scheduled task)
  docs/
    USER_GUIDE.md       # This file
    DESIGN.md           # Architecture and data model
    DEV_GUIDE.md        # Developer reference
    INVESTIGATION_GUIDE.md  # Investigation workflows
    USE_CASES.md        # Real-world use cases
```

---

## 13. Interpreting the Chain Log

`data/chain_log.csv` is an append-only CSV with five columns:

```text
FileName,FullPath,FileHash,Timestamp,ChainHash
video.mp4,"E:\Recordings\video.mp4",3A9F...,2026-04-05T10:00:00+05:30,8B2C...
```

- **FileName** — base name of the file
- **FullPath** — absolute path on disk (quoted; allows disambiguation when two watched folders contain files with the same name)
- **FileHash** — SHA-256 hex digest, or `DELETED:<previous-hash>` for deleted files
- **Timestamp** — ISO-8601 with timezone offset
- **ChainHash** — `SHA256(FileHash|PreviousChainHash|Timestamp)` using `|` as separator

Each `ChainHash` depends on the previous row's `ChainHash`, so any edit to any past row invalidates all subsequent entries.

**Chain log rotation:** At startup and before each periodic scan the watcher checks whether the log's oldest entry belongs to a past month. If so, the log is archived as `chain_log_YYYY-MM.csv` and a fresh `chain_log.csv` is started. Each monthly archive is independently verifiable.

**Upgrading from an older version:** The chain log format changed from 4 columns to 5 columns (`FullPath` was added). To upgrade an existing installation, delete `data/chain_log.csv` and `data/state.json` and let the watcher recreate them on next startup.

**Note:** If `report.ps1` or `audit.ps1` prints no results or shows an empty chain, you may be running it from the project source directory instead of the install directory (`E:\ForensicSystem\src\`). The scripts resolve `data/` relative to their own location via `$PSScriptRoot`.

---

## 14. Scheduled Tasks (Installer)

The installer registers two scheduled tasks:

| Task | Trigger | Script |
| --- | --- | --- |
| `ForensicWatcher` | At system startup | `watcher.ps1` |
| `ForensicWeeklyMaintenance` | Every Sunday at 02:00 | `weekly_maintenance.ps1` |

```powershell
# Check watcher status
Get-ScheduledTask -TaskName "ForensicWatcher"

# Stop / start watcher
Stop-ScheduledTask  -TaskName "ForensicWatcher"
Start-ScheduledTask -TaskName "ForensicWatcher"

# Run weekly maintenance immediately (without waiting for Sunday)
Start-ScheduledTask -TaskName "ForensicWeeklyMaintenance"

# Remove both tasks
Unregister-ScheduledTask -TaskName "ForensicWatcher"            -Confirm:$false
Unregister-ScheduledTask -TaskName "ForensicWeeklyMaintenance"  -Confirm:$false
```

---

## 15. GPG Signing Setup

For Git commit signing to work, install GPG and set your key ID in `config.json`:

```powershell
# List available keys — copy the long ID (e.g. ABCD1234EFGH5678)
gpg --list-secret-keys --keyid-format LONG
```

Then set it in `config/config.json`:

```json
"gpgKeyId": "ABCD1234EFGH5678"
```

Leave `gpgKeyId` as `""` to fall back to GPG's default key. The watcher validates that the key exists in your keyring on startup and warns if it is not found.

Without GPG signing, Git commits are still created but the identity verification layer is absent.

---

## 16. Limitations

- **Not tamper-proof**: The system detects tampering; it does not prevent it.
- **Not a substitute for backup**: The chain log records file state, not file content.
- **Single-machine trust**: If the machine running the watcher is compromised before logging begins, pre-compromise files cannot be proven clean.
- **OpenTimestamps latency**: OTS proofs take hours to days to confirm on the Bitcoin blockchain.

---

## 17. Common Issues

| Symptom                               | Likely Cause                                    | Fix                                                        |
| ------------------------------------- | ----------------------------------------------- | ---------------------------------------------------------- |
| `Config error: watchPaths is empty`   | Config not edited before running                | Set at least one path in `config.json`                     |
| `Config error: installPath not set`   | `installPath` missing from config               | Add `"installPath": "E:\\ForensicSystem"` to `config.json` |
| `Chain INVALID` on first run          | `chain_log.csv` was manually edited             | Delete the file; watcher will recreate it                  |
| No `.ots` file generated              | `enableOpenTimestamps` false or no internet     | Set to `true` and ensure internet access                   |
| Git commit errors in log              | GPG key not found or no Git repo initialised    | Check `gpgKeyId` in config or run `install.ps1` first      |
| GPG key warning on startup            | `gpgKeyId` not in keyring                       | Run `gpg --list-secret-keys` and correct the ID in config  |
| Skipped (still being written) in log  | Large file copy in progress                     | Normal — periodic scan will record it once copy finishes   |
| `Could not hash file` in log          | File locked by another process                  | Normal for temp/locked files; no action needed             |

---

## 18. Disclaimer

This system provides **tamper-evidence**, not absolute proof of origin. Use as part of a broader forensic or legal process. See `DISCLAIMER.md`.
