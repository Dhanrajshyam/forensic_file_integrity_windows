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

- Copy scripts to `C:\ForensicSystem\`
- Create `data\` and `logs\` directories
- Initialize a Git repo at the configured `repoPath`
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
    "C:\\Recordings",
    "D:\\CameraBackup"
  ],
  "repoPath": "C:\\ForensicRepo",
  "enableOpenTimestamps": true,
  "enablePublicAnchor": false,
  "logLevel": "INFO",
  "verifyIntervalSeconds": 300
}
```

### Configuration Options

| Key                     | Type     | Description                                                      |
| ----------------------- | -------- | ---------------------------------------------------------------- |
| `watchPaths`            | array    | Folders to monitor. Must be non-empty. Warns if path not found. |
| `repoPath`              | string   | Path to the Git repo where chain log is committed. Optional.    |
| `enableOpenTimestamps`  | boolean  | Stamp each chain hash to the Bitcoin blockchain via OTS.        |
| `enablePublicAnchor`    | boolean  | Publish anchor to a public location (future feature).           |
| `logLevel`              | string   | Logging verbosity: `INFO`, `WARNING`, `ERROR`.                  |
| `verifyIntervalSeconds` | integer  | How often (seconds) to run a full directory scan. Min 1.        |

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

To check whether a specific file matches its recorded hash and produce a readable report:

```powershell
.\src\report.ps1 -FilePath "C:\Recordings\video.mp4"
```

The report is written to `data/forensic_report.txt` and includes:

- File name, full path, size, and last modified time
- Current SHA-256 hash vs. recorded hash
- Hash match result
- Chain validity result (all entries, not just this file)
- Number of chain entries for this file
- First and last recorded timestamps
- Final status: `VERIFIED` or `TAMPERING DETECTED`

---

## 8. Creating an Evidence Bundle

Package a file with all supporting evidence into a single zip archive:

```powershell
.\src\bundle.ps1 -FilePath "C:\Recordings\video.mp4"
```

The bundle (`data/evidence_bundle_<timestamp>.zip`) contains:

- The file itself
- `chain_log.csv`
- `latest_hash.txt.ots` (OpenTimestamps proof, if present)
- `forensic_report.txt`
- `git_commit.txt` (last Git commit, if repo is configured)

This archive can be handed to a third party for independent verification.

---

## 9. Running Attack Tests

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

## 10. File and Directory Layout

```text
forensic-file-integrity/
  config/
    config.json         # Configuration (edit before use)
  data/
    chain_log.csv       # Tamper-evident hash chain (runtime)
    state.json          # Last-known hash per file (runtime)
    forensic_report.txt # Most recent report (runtime)
    latest_hash.txt.ots # OpenTimestamps proof (runtime)
  logs/
    system_log.jsonl    # Structured event log, NDJSON format (runtime)
  src/
    watcher.ps1         # File monitoring service
    verifier.ps1        # Chain and signature verifier
    report.ps1          # Forensic report generator
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

## 11. Interpreting the Chain Log

`data/chain_log.csv` is an append-only CSV with four columns:

```text
FileName,FileHash,Timestamp,ChainHash
video.mp4,3A9F...,2026-04-05T10:00:00+05:30,8B2C...
```

- **FileName** — base name of the file
- **FileHash** — SHA-256 hex digest, or `DELETED:<previous-hash>` for deleted files
- **Timestamp** — ISO-8601 with timezone offset
- **ChainHash** — `SHA256(FileHash|PreviousChainHash|Timestamp)` using `|` as separator

Each `ChainHash` depends on the previous row's `ChainHash`, so any edit to any past row invalidates all subsequent entries.

---

## 12. Scheduled Task (Installer)

After running the installer, the watcher runs automatically at system startup under the `ForensicWatcher` scheduled task with elevated privileges.

To manage the task:

```powershell
# Check status
Get-ScheduledTask -TaskName "ForensicWatcher"

# Stop watcher
Stop-ScheduledTask -TaskName "ForensicWatcher"

# Start watcher
Start-ScheduledTask -TaskName "ForensicWatcher"

# Remove task
Unregister-ScheduledTask -TaskName "ForensicWatcher" -Confirm:$false
```

---

## 13. GPG Signing Setup

For Git commit signing to work, configure GPG before running the installer:

```powershell
# List available keys
gpg --list-secret-keys --keyid-format LONG

# Configure Git to use your key
git config --global user.signingkey <YOUR-KEY-ID>
git config --global commit.gpgsign true
```

Without GPG signing, Git commits are still created but the identity verification layer is absent.

---

## 14. Limitations

- **Not tamper-proof**: The system detects tampering; it does not prevent it.
- **Not a substitute for backup**: The chain log records file state, not file content.
- **Single-machine trust**: If the machine running the watcher is compromised before logging begins, pre-compromise files cannot be proven clean.
- **OpenTimestamps latency**: OTS proofs take hours to days to confirm on the Bitcoin blockchain.

---

## 15. Common Issues

| Symptom                             | Likely Cause                                | Fix                                            |
| ----------------------------------- | ------------------------------------------- | ---------------------------------------------- |
| `Config error: watchPaths is empty` | Config not edited before running            | Set at least one path in `config.json`         |
| `Chain INVALID` on first run        | `chain_log.csv` was manually edited         | Delete the file; watcher will recreate it      |
| No `.ots` file generated            | `enableOpenTimestamps` false or no internet | Set to `true` and ensure internet access       |
| Git commit errors in log            | GPG not configured or no Git repo           | Set up GPG or remove `repoPath` from config    |
| `Could not hash file` in log        | File locked by another process              | Normal for temp/locked files; no action needed |

---

## 16. Disclaimer

This system provides **tamper-evidence**, not absolute proof of origin. Use as part of a broader forensic or legal process. See `DISCLAIMER.md`.
