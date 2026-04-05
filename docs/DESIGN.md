# Forensic File Integrity System — Design Document

## 1. Overview

This system provides a **tamper-evident file integrity framework** using:

* Cryptographic hashing (SHA-256)
* Hash chaining (linked log structure)
* Version control (Git)
* Cryptographic signing (GPG)
* Public timestamp anchoring (OpenTimestamps + public logs)
* Independent verification

The goal is **not to prevent tampering**, but to ensure:

> Any tampering is **detectable, provable, and traceable**.

---

## 2. Core Principles

### 2.1 Tamper-Evident, Not Tamper-Proof

This system does **not prevent modification** of files.
Instead, it ensures that:

* Any modification leaves **cryptographic evidence**
* Any attempt to rewrite history is **detectable**

---

### 2.2 Chain of Trust

The system builds trust through multiple independent layers:

1. File Hash (Integrity)
2. Hash Chain (Log Integrity)
3. Git History (Version Tracking)
4. Signed Commits (Identity)
5. External Anchors (Timeline Proof)
6. Independent Verifier (Trust Separation)

---

### 2.3 Defense in Depth

No single component is trusted completely.

| Layer    | Purpose              |
| -------- | -------------------- |
| Hash     | Detect file change   |
| Chain    | Detect log tampering |
| Git      | Track history        |
| GPG      | Verify identity      |
| Anchor   | Prove time           |
| Verifier | Detect compromise    |

---

## 3. System Architecture

### 3.1 High-Level Components

```text
[ File System ]
      ↓
[ Watcher Service ]
      ↓
[ Hash + Chain Logger ]
      ↓
[ Git Commit Engine ]
      ↓
[ OpenTimestamp Anchor ]
      ↓
[ Remote Repositories ]
      ↓
[ Independent Verifier ]
```

---

### 3.2 Component Responsibilities

#### Watcher

* Monitors configured folders
* Detects file events (create/modify/delete)

#### Hash Engine

* Computes SHA-256 hash
* Ensures deterministic output

#### Chain Logger

* Maintains append-only log
* Links each entry to previous entry

#### Git Engine

* Commits changes
* Pushes to multiple remotes

#### Anchor Engine

* Generates OpenTimestamps proof
* Publishes public anchor

#### Verifier

* Independently validates:

  * chain integrity
  * Git integrity
  * timestamp proofs

---

## 4. Data Model

### 4.1 Chain Log Format

Stored in: `chain_log.csv`

```text
FileName,FileHash,Timestamp,ChainHash
video1.mp4,ABC123...,2026-04-05T10:00:00+05:30,XYZ789...
```

---

### 4.2 Chain Hash Formula

Each entry depends on previous entry:

```text
ChainHash = SHA256(FileHash|PreviousChainHash|Timestamp)
```

Fields are joined with `|` as the separator.

---

### 4.3 Example

#### Entry 1

```text
FileHash = H1
Previous = ""
ChainHash = SHA256(H1|""|T1)
```

#### Entry 2

```text
FileHash = H2
Previous = ChainHash1
ChainHash = SHA256(H2|ChainHash1|T2)
```

---

### 4.4 Why This Matters

If attacker modifies:

* any past file hash
* any timestamp

👉 Entire chain breaks from that point forward

---

## 5. Workflow

### 5.1 File Creation

1. File created in monitored folder
2. System computes SHA-256
3. Chain hash calculated
4. Entry appended to log
5. Git commit created
6. Anchor generated

---

### 5.2 File Modification

1. File modified
2. New hash computed
3. Compared with previous state

If different:

* Mark as **tamper event**
* Append new chain entry

---

### 5.3 Verification Workflow

To verify a file:

1. Compute current hash
2. Compare with recorded hash
3. Validate chain integrity
4. Verify Git history
5. Verify OpenTimestamp proof

---

## 6. Trust Model

### 6.1 Trusted Components

* Cryptographic hash (SHA-256)
* OpenTimestamps proof
* GPG signatures (if keys are secure)

---

### 6.2 Semi-Trusted Components

* Git repositories
* Local system

---

### 6.3 Untrusted Scenarios

Assume attacker may:

* Modify files
* Modify logs
* Attempt Git rewrite
* Attempt replay attack

---

## 7. Threat Model

### 7.1 Threat: File Tampering

**Attack:**
Modify video file

**Detection:**

* Hash mismatch

---

### 7.2 Threat: Log Tampering

**Attack:**
Modify CSV file

**Detection:**

* Chain validation fails

---

### 7.3 Threat: Git History Rewrite

**Attack:**
Force push rewritten history

**Mitigation:**

* Protected branches
* External anchors
* Verifier mismatch

---

### 7.4 Threat: Fake Recompute Attack

**Attack:**
Modify file → recompute hash → update log

**Detection:**

* Chain mismatch
* Anchor mismatch

---

### 7.5 Threat: Key Compromise

**Attack:**
Attacker uses stolen GPG key

**Impact:**

* Can forge commits

**Mitigation:**

* Hardware keys (recommended)
* External anchors still provide resistance

---

## 8. Anchoring Strategy

### 8.1 OpenTimestamps

* Anchors hash to Bitcoin network
* Provides cryptographic timestamp

---

### 8.2 Public Anchor

Example:

```text
2026-04-05T10:00:00+05:30 | XYZ789...
```

Published to:

* public repo
* email
* other public systems

---

### 8.3 Why Anchoring is Critical

Without anchor:

* attacker can rewrite entire history

With anchor:

* attacker must match external timeline → extremely hard

---

## 9. Independent Verification

### 9.1 Purpose

Prevents single-point trust failure

---

### 9.2 Verifier Responsibilities

* Pull latest repo
* Validate:

  * chain
  * signatures
  * anchors

---

### 9.3 Example

If attacker rewrites repo:

* Recorder looks clean
* Verifier detects mismatch

---

## 10. Limitations

### 10.1 What This System CAN Prove

* File integrity after recording
* Timeline consistency
* Detection of tampering

---

### 10.2 What This System CANNOT Prove

* Original authenticity of file
* Whether system was compromised before logging
* Intent behind modification

---

## 11. Design Trade-offs

| Decision       | Reason                    |
| -------------- | ------------------------- |
| CSV log        | Simple, portable          |
| SHA-256        | Strong + widely supported |
| Git            | Distributed history       |
| OpenTimestamps | Free + strong timestamp   |
| PowerShell     | Native Windows support    |

---

## 12. Example End-to-End Scenario

### Step 1 — Record File

```text
video.mp4 created
```

System logs:

```text
Hash = H1
ChainHash = C1
```

---

### Step 2 — Anchor

```text
C1 → OpenTimestamp → blockchain proof
```

---

### Step 3 — After 1 Year

Verification:

* Current hash = H1
* Chain valid = true
* Anchor valid = true

---

### Conclusion

> File has not been modified since recorded time

---

## 13. Summary

This system provides:

* Multi-layer tamper detection
* Cryptographic verification
* Independent validation
* Public timestamp anchoring

It is designed to be:

* Transparent
* Reproducible
* Defensible

---

## 14. Disclaimer

This system provides **tamper-evidence**, not absolute proof of origin.

It should be used as part of a broader forensic or audit process.
