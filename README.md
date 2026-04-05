# Forensic File Integrity System

A **tamper-evident file integrity framework** that provides cryptographic proof of file history, timeline, and integrity.

---

## What Problem This Solves

If someone asks:

> "How do you prove this file was not modified?"

Most answers are weak:

- "hash matches" — easily forgeable
- "stored in database" — can be edited
- "timestamp in system" — can be manipulated

This system solves that by creating:

> **cryptographically verifiable, independently anchored, tamper-evident records**

---

## Key Features

- Real-time folder monitoring
- SHA-256 file hashing
- Hash chain (detects log tampering)
- Git-based audit trail with signed commits (identity proof)
- Blockchain-backed timestamps (OpenTimestamps)
- Forensic report generation
- Evidence bundle export
- Attack simulation tests

---

## What This Tool Does NOT Do

- Does NOT prevent file modification
- Does NOT guarantee original authenticity
- Does NOT protect against compromised systems before logging

This tool provides **tamper-evidence, not absolute truth**.

---

## How It Works

```text
File → SHA256 → Chain Log → Git Commit → Timestamp Anchor → Verification
```

Each step adds a layer of protection:

| Layer    | Purpose             |
| -------- | ------------------- |
| Hash     | Detect file changes |
| Chain    | Detect log edits    |
| Git      | Track history       |
| GPG      | Verify identity     |
| Anchor   | Prove time          |
| Verifier | Detect compromise   |

---

## Quick Start

### 1. Clone

```bash
git clone <your-repo-url>
cd forensic-file-integrity
```

### 2. Install dependencies

```bash
pip install opentimestamps-client
```

Also install: **Git**, **GPG**, **Python 3**

### 3. Configure

Edit `config/config.json`:

```json
{
  "watchPaths": ["C:\\Recordings"],
  "repoPath": "C:\\ForensicRepo",
  "enableOpenTimestamps": true,
  "enablePublicAnchor": false,
  "logLevel": "INFO",
  "verifyIntervalSeconds": 300
}
```

### 4. Install system (runs at startup)

```powershell
cd installer
.\install.ps1
```

Or run the watcher directly:

```powershell
.\src\watcher.ps1
```

---

## Verify a File

```powershell
.\src\report.ps1 -FilePath "C:\Recordings\video.mp4"
```

Output is written to `data/forensic_report.txt`.

---

## Validate the Full Chain

```powershell
.\src\verifier.ps1
```

---

## Generate an Evidence Bundle

```powershell
.\src\bundle.ps1 -FilePath "C:\Recordings\video.mp4"
```

Creates `data/evidence_bundle_<timestamp>.zip` containing the file, chain log, OTS proof, and forensic report.

---

## Run Attack Tests

```powershell
.\tests\attack-tests.ps1
```

Simulates 5 attack scenarios: file tampering, log tampering, fake recompute, chain deletion, and timestamp manipulation. Exit code equals the number of failed tests (0 = all passed).

---

## Output Files

| File                          | Description                         |
| ----------------------------- | ----------------------------------- |
| `data/chain_log.csv`          | Append-only hash chain log          |
| `data/state.json`             | Last-known hash per monitored file  |
| `data/forensic_report.txt`    | Generated integrity report          |
| `data/latest_hash.txt.ots`    | OpenTimestamps blockchain proof     |
| `data/evidence_bundle_*.zip`  | Packaged evidence archive           |
| `logs/system_log.jsonl`       | Structured event log (NDJSON)       |

---

## Example Scenarios

### File NOT modified

- Hash matches recorded value
- Chain valid
- Timestamp valid

Result: **Integrity confirmed**

### File modified after logging

- Hash mismatch detected

Result: **Tampering detected**

### Log file modified

- Chain validation fails

Result: **Evidence log compromised**

---

## Architecture

```text
Watcher → Hash → Chain → Git → Anchor → Verifier
```

---

## Documentation

| File                             | Contents                           |
| -------------------------------- | ---------------------------------- |
| `docs/USER_GUIDE.md`             | Installation, configuration, usage |
| `docs/DESIGN.md`                 | Architecture and data model        |
| `docs/DEV_GUIDE.md`              | Developer reference                |
| `docs/INVESTIGATION_GUIDE.md`    | How to investigate findings        |
| `docs/USE_CASES.md`              | Real-world use cases               |

---

## Security Model

This system assumes:

- Attacker may access and modify files
- Attacker may attempt log modification
- Attacker may attempt Git history rewrite

Protection is achieved through:

- Chained hashes (log edit detection)
- Signed commits (identity verification)
- External timestamping (timeline proof)
- Independent verification (trust separation)

---

## Limitations

This system cannot prove:

- File authenticity at creation time
- Absence of system compromise before logging began
- Intent behind any changes

---

## Key Insight

This system proves:

> "This file has not changed since time T"

NOT:

> "This file was always correct"

---

## Testing

Run attack simulations from the project root:

```powershell
.\tests\attack-tests.ps1
```

---

## Contributing

See `docs/DEV_GUIDE.md`.

---

## License

MIT License — see `LICENSE`.

---

## Disclaimer

This project provides **tamper-evidence**, not guaranteed truth. Use as part of a broader forensic or legal process. See `DISCLAIMER.md`.
