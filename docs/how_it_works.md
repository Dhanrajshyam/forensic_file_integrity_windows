# How It Works — Forensic File Integrity System

This document explains the internal mechanics of the system: how file integrity is maintained, how changes are detected, and why the design is forensically and legally defensible.

---

## 1. The Core Problem

A file hash alone is not enough to prove integrity. Anyone can:

- Modify a file, recompute its hash, and update the record
- Backdoor timestamps on a local system
- Delete or rewrite log entries

This system solves this by building **multiple cryptographically linked layers** that an attacker would have to compromise simultaneously, and independently, to forge a clean record.

---

## 2. System Components at a Glance

```
File System Events
       |
  [ Watcher ]          ← monitors folders in real-time (FileSystemWatcher + periodic scan)
       |
  [ Hash Engine ]      ← computes SHA-256 of each changed file
       |
  [ Chain Logger ]     ← appends a chained entry to chain_log.csv
       |
  [ Git Engine ]       ← commits chain_log.csv and state.json with GPG signature
       |
  [ Anchor Engine ]    ← stamps the chain hash to the Bitcoin blockchain via OpenTimestamps
       |
  [ Verifier ]         ← independently validates the entire chain, Git history, and OTS proofs
```

---

## 3. How File Integrity Is Maintained

### 3.1 SHA-256 File Hashing

Every time a file is created, modified, renamed, or deleted, the system computes its **SHA-256 hash** — a 64-character fingerprint that is unique to the exact byte content of the file.

```
SHA-256("hello world") = b94d27b9...
SHA-256("hello World") = completely different hash
```

This hash is stored alongside the filename and a precise ISO 8601 timestamp (with timezone offset).

### 3.2 The Hash Chain

Entries in `chain_log.csv` are not independent — each one is **cryptographically linked** to the one before it:

```
ChainHash_N = SHA-256( FileHash_N | ChainHash_(N-1) | Timestamp_N )
```

This means:

- You cannot change any past entry without invalidating every entry after it
- You cannot reorder entries
- You cannot insert or delete entries silently

The chain is verified by `verifier.ps1`, which replays every entry from the beginning and checks that each `ChainHash` field was computed correctly.

### 3.3 File State Tracking

`data/state.json` stores the last-known hash for every monitored file path. This allows the watcher to:

- **Skip duplicate events** — if a file triggers two events but the hash hasn't changed, the second is silently ignored
- **Detect deletions** — when a file disappears, the last known hash is recorded as `DELETED:<hash>` in the chain log, preserving the evidence of what existed

---

## 4. How Changes Are Identified

### 4.1 Real-Time Monitoring

The watcher registers event listeners on each configured folder using .NET's `System.IO.FileSystemWatcher`. It listens for four event types:

| Event | Trigger |
|---|---|
| `Created` | A new file appears |
| `Changed` | An existing file is written to |
| `Deleted` | A file is removed |
| `Renamed` | A file is moved or renamed |

Subdirectories are included automatically (`IncludeSubdirectories = $true`).

### 4.2 Debouncing

File system events can fire multiple times in rapid succession for a single logical save. The watcher suppresses duplicate events for the same file path within a **2-second window** to avoid redundant log entries.

### 4.3 Periodic Full Scan

Every `verifyIntervalSeconds` (default: 300 seconds), the watcher performs a full recursive scan of all watched directories. This acts as a safety net to catch any events that the `FileSystemWatcher` may have missed (e.g. during high I/O load or brief process restarts).

During the scan, each file's hash is computed and compared to `state.json`. Only files whose hash has changed produce a new chain entry.

### 4.4 Startup Scan

When the watcher first starts, it immediately runs a full directory scan. This ensures that any files already present are recorded before real-time monitoring begins.

---

## 5. Forensic Safety — Chain of Custody

The system is designed to satisfy the requirements of a **forensic chain of custody**: the ability to prove, to a court or investigator, that evidence has not been altered since it was first recorded.

### 5.1 Append-Only Log

`chain_log.csv` is written to with `-Append`. Entries are never overwritten or deleted by the system. Every state change — including deletions — creates a new entry, preserving the complete history.

### 5.2 Mutex-Protected Writes

All reads and writes to `chain_log.csv` are protected by a named Windows system mutex (`Global\ForensicChainLogMutex`). This prevents race conditions if multiple processes or event handlers attempt concurrent writes.

### 5.3 Tamper-Evident Chain

Because each entry's `ChainHash` depends on the previous entry, any retroactive modification — including:

- editing a past hash value
- changing a timestamp
- inserting or removing a row
- reordering rows

...will cause the chain to fail validation from that point forward. The `verifier.ps1` script detects this and reports which entry broke the chain.

### 5.4 Git Signed Commits

After every chain log update, the system copies `chain_log.csv` and `state.json` from `data/` into `repoPath` (Git can only track files inside its own working tree), then runs:

```
git add chain_log.csv state.json
git commit -m "[forensic] <filename> at <timestamp>" --gpg-sign=<gpgKeyId>
```

The GPG key is set via `config.gpgKeyId`. Leave it empty to use GPG's default key. The watcher validates the key exists in the keyring at startup and warns if it does not.

This creates a **cryptographically signed, timestamped snapshot** of the log state in Git history. The GPG signature ties each commit to a specific key holder's identity, establishing accountability.

Git history provides:
- An ordered sequence of all changes to the log
- Identity of the operator (via GPG key)
- Commit timestamps (local + remote)

### 5.5 Blockchain Anchoring (OpenTimestamps)

The current chain hash is submitted to the **OpenTimestamps** service, which anchors it to the Bitcoin blockchain. This provides:

- A **trustless, immutable timestamp** not controlled by any single party
- Proof that a specific hash existed no later than a certain Bitcoin block
- Independent verification that requires no trust in the system operator

The `.ots` proof file is stored at `data/latest_hash.txt.ots` and can be verified offline against the Bitcoin blockchain at any time.

---

## 6. Legal Defensibility

The system is designed to produce evidence that is:

### Reproducible

All verification steps can be re-run by any party with access to:
- `chain_log.csv`
- The `.ots` proof file
- The Git repository

No proprietary tools or secrets are required.

### Independent

No single point of trust:

| Layer | Controlled by |
|---|---|
| Chain hash | Mathematics (SHA-256) |
| Git history | Git protocol + remote repos |
| GPG signature | Operator's key (auditable) |
| OTS proof | Bitcoin blockchain (decentralized) |

### Non-repudiable

GPG-signed commits bind the log entries to a key identity. Blockchain anchoring binds the chain hash to a public, immutable timeline.

### Documented

Every change produces a structured log entry in `logs/system_log.jsonl` (NDJSON format) with a timestamp, event type, and message. This log is separate from `chain_log.csv` and records system events, warnings, and alerts.

---

## 7. What the Evidence Bundle Contains

Running `bundle.ps1 -FilePath <file>` produces a `.zip` archive containing:

| File | Purpose |
|---|---|
| The monitored file itself | The subject of the investigation |
| `chain_log.csv` | Full history of all recorded events |
| `latest_hash.txt.ots` | Bitcoin blockchain timestamp proof |
| `forensic_report.txt` | Human-readable verification report |
| `git_commit.txt` | Latest Git commit log entry |

This bundle is suitable for submission to investigators, legal counsel, or court as a self-contained evidence package.

---

## 8. Verification Summary

To verify a file's integrity:

1. **Hash check** — does the current SHA-256 match the last recorded hash?
2. **Chain check** — does every `ChainHash` in the log recompute correctly?
3. **Git check** — are all commits signed, with no unsigned entries or unexpected gaps?
4. **Timestamp check** — does the `.ots` proof verify against the Bitcoin blockchain?

All four must pass for evidence to be considered **strong**.

---

## 9. What This System Cannot Prove

This system provides **tamper-evidence after the point of first recording**, not absolute authenticity.

It cannot prove:
- That a file was genuine when it was first created
- That the system was not compromised before monitoring began
- The intent behind any modification

These limitations are inherent to any after-the-fact integrity system and should be disclosed in any legal or forensic context.

---

## 10. Data Flow Diagram

```
File event detected
        |
        v
Compute SHA-256 hash
        |
        v
Compare with state.json (last known hash)
        |
      same? --> skip (no change)
        |
     different (or new/deleted)
        |
        v
Append to chain_log.csv:
  FileName, FileHash, Timestamp, ChainHash
  where ChainHash = SHA-256(FileHash|PrevChainHash|Timestamp)
        |
        v
Update state.json
        |
        v
Git commit (GPG-signed)
        |
        v
OpenTimestamps stamp (anchors to Bitcoin)
        |
        v
Write event to logs/system_log.jsonl
```

---

## 11. Key Files Reference

| File | Role |
|---|---|
| `src/watcher.ps1` | Main monitoring process — watches folders, hashes files, drives the chain |
| `src/utils.ps1` | Shared functions: timestamps, chain hash computation, config loading, mutex |
| `src/verifier.ps1` | Full chain validation, Git signature check, OTS verification |
| `src/report.ps1` | Per-file forensic report comparing current hash to chain history |
| `src/bundle.ps1` | Packages evidence for export/submission |
| `config/config.json` | Watch paths, install path, repo path, GPG key ID, OTS toggle, exclude patterns, scan interval |
| `data/chain_log.csv` | Append-only tamper-evident event log |
| `data/state.json` | Last-known hash per monitored file path |
| `data/latest_hash.txt.ots` | Bitcoin blockchain proof of chain hash |
| `logs/system_log.jsonl` | Structured system event log (NDJSON) |
