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

* Avoid duplicate event handling
* Debounce rapid file changes

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

* Stage changes
* Commit with timestamp
* Push to remotes

---

**Rules:**

* Always include timestamp in commit message
* Never rewrite history
* Ensure commits are signed

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

* Hashing large videos is expensive
* Avoid duplicate hashing

---

### 11.2 Event Flooding

* Use debounce mechanism
* ignore temporary file states

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
