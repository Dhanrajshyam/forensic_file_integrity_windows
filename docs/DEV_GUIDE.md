# Forensic File Integrity System — Developer Guide

## 1. Introduction

This document explains how the system works internally and how to:

* understand core components
* extend functionality
* contribute safely
* avoid breaking forensic guarantees

---

## 2. Core Design Philosophy

### 2.1 Deterministic Behavior

All operations must be:

* repeatable
* predictable
* consistent across runs

If two developers run the same input → output must match exactly.

---

### 2.2 Append-Only Design

Critical data structures (logs, anchors) must:

* NEVER be modified in place
* ONLY appended

Violation of this breaks forensic integrity.

---

### 2.3 Fail-Safe Over Fail-Silent

System must:

* log errors clearly
* stop on critical integrity failures

Silent failures are unacceptable.

---

## 3. Code Structure

```text
src/
  watcher.ps1        # file monitoring
  verifier.ps1       # independent verification
  report.ps1         # forensic report generator
  bundle.ps1         # evidence packaging
  utils.ps1          # shared functions
```

---

## 4. Core Modules

---

### 4.1 Watcher Module

**Responsibility:**

* Monitor file system events

**Key Events:**

* Created
* Changed
* Deleted
* Renamed

**Important Notes:**

* Debounce window: 2 seconds per path — suppresses duplicate OS events for the same file
* Deleted events only record files already in `state.json` — temp file deletions are silently dropped
* Hidden, System, and Temporary file attributes are checked before hashing — OS-managed files are excluded
* `excludePatterns` in config allows additional glob-based exclusions (e.g. `~$*`, `*.tmp`)
* Large-file writes: an exclusive-open probe checks the file is no longer locked before hashing. Retries 5 times at 3-second intervals; if still locked the event is skipped and the periodic scan picks it up
* Batch scan commits: `Start-DirectoryScan` writes all chain entries with `-SkipCommit`, then issues one git commit and one OTS stamp for the whole batch — prevents N×commit overhead on startup or periodic scans over large directories

---

### 4.2 Hash Module

**Function:**

```powershell
Get-FileHash -Algorithm SHA256
```

**Rules:**

* Always use SHA-256
* Never switch algorithm without versioning

---

### 4.3 Chain Module

**Formula:**

```text
ChainHash = SHA256(FileHash|PreviousChainHash|Timestamp)
```

---

**Constraints:**

* PreviousChainHash must be exact
* Timestamp format must be ISO-8601
* No trimming or normalization inconsistencies

---

### 4.4 Git Module

**Responsibilities:**

* Copy `chain_log.csv` and `state.json` from `data/` into `repoPath`
* Stage and commit with a GPG-signed commit
* Commit message format: `[forensic] <filename> at <timestamp>` (single event) or `[forensic] batch scan: N file(s) at <timestamp>` (scan)

**Rules:**

* Always include timestamp in commit message
* Never rewrite history
* GPG key ID is read from `config.gpgKeyId`; falls back to GPG default key if empty
* `chain_log.csv` and `state.json` are copied into `repoPath` before staging — Git tracks files inside its working tree only

---

### 4.5 Anchor Module

Uses:

* OpenTimestamps
* Public log file

---

**Flow:**

```text
ChainHash → .ots file → commit → public anchor
```

---

### 4.6 Verifier Module

Validates:

* chain integrity
* Git history
* timestamp proof

---

## 5. Data Integrity Rules

### 5.1 CSV Log Rules

* Must remain append-only
* No row edits allowed
* No reordering

---

### 5.2 Timestamp Rules

* Must use ISO format:

```text
yyyy-MM-ddTHH:mm:ssK
```

---

### 5.3 Encoding Rules

* Use UTF-8
* Avoid BOM issues

---

## 6. Error Handling

### Critical Errors (Stop System)

* Chain mismatch
* Missing log file
* corrupted state

---

### Non-Critical Errors (Log Only)

* Git push failure
* network issues
* temporary file access errors

---

## 7. Logging Standards

Use structured JSON logs:

```json
{
  "time": "2026-04-05T10:00:00+05:30",
  "event": "FILE_MODIFIED",
  "file": "video.mp4",
  "hash": "ABC123",
  "chain": "XYZ789"
}
```

---

## 8. Adding New Features

Before adding any feature, ask:

1. Does this affect integrity?
2. Does this break determinism?
3. Does this alter existing logs?

---

### Example: Adding new metadata

Allowed:

```json
{
  "camera_id": "CAM01"
}
```

Not allowed:

* modifying existing hash logic
* changing chain structure

---

## 9. Testing Requirements

Every change must pass:

### 9.1 Integrity Tests

* chain validation
* hash verification

---

### 9.2 Attack Tests

* file tampering
* log tampering
* anchor removal

---

### 9.3 Regression Tests

* existing data must remain valid

---

## 10. Security Considerations

### 10.1 Key Handling

* Never commit private keys
* Use environment or secure storage

---

### 10.2 Git Safety

* No force push
* No history rewrite

---

### 10.3 Input Validation

* Validate file paths
* sanitize inputs

---

## 11. Performance Considerations

### 11.1 Large Files

* Hashing large files is expensive — `Get-StableFileHash` probes for an exclusive lock before hashing to ensure the file is complete. Do not add a second `Get-FileHash` call after the probe; that would hash twice.
* State deduplication (`state.json`) means unchanged files are never re-hashed on periodic scans.

---

### 11.2 Event Flooding

* The 2-second debounce window in `Invoke-FileEvent` suppresses rapid successive events for the same path.
* Hidden/System/Temporary attribute check in `Test-ShouldExclude` drops OS-generated files before any hashing occurs.
* `excludePatterns` in config provides additional name-based filtering — extend this for application-specific temp files.

---

### 11.3 Large Directories (Batch Scans)

* `Start-DirectoryScan` uses `-SkipCommit` on every `Add-ChainEntry` call and issues a single git commit + OTS stamp after all entries are written. This reduces a 100,000-file scan from 100,000 GPG signing operations to 1.
* `Get-LastChainHash` uses `-Tail 1` to read only the last line of `chain_log.csv` — O(1) regardless of log size.

---

## 12. Versioning Strategy

If breaking change required:

* bump version
* migrate old logs
* maintain backward compatibility

---

## 13. Contribution Guidelines

### 13.1 Do

✔ Write clean, readable code
✔ Document changes
✔ Add tests

---

### 13.2 Do NOT

❌ Modify chain logic casually
❌ Change hashing algorithm
❌ Rewrite logs

---

## 14. Common Pitfalls

* Inconsistent timestamp format
* Encoding mismatch
* duplicate event handling
* ignoring error states

---

## 15. Example Extension

### Add support for new folder

Modify:

```text
config.json
```

No code changes required

---

## 16. Debugging Guide

### Check logs

```text
logs/system_log.jsonl
```

---

### Validate chain manually

```powershell
.\src\verifier.ps1
```

---

## 17. Future Improvements

* cross-platform support
* GUI dashboard
* distributed verification nodes
* cloud anchoring

---

## 18. Summary

This system depends on:

* strict data integrity
* deterministic processing
* append-only logs

Breaking these rules:

> breaks the entire forensic guarantee

---

## 19. Disclaimer

This system provides **tamper-evidence**, not absolute proof of origin.

Developers must preserve integrity guarantees when contributing.
