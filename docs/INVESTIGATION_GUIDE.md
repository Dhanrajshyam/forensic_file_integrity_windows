# Forensic File Integrity System — Investigation Guide

## 1. Purpose

This guide explains how to:

* Investigate file integrity issues
* Interpret forensic reports
* Identify tampering attempts
* Validate evidence credibility

---

## 2. Investigation Principles

### 2.1 Never Trust a Single Signal

Do NOT rely only on:

* hash match
* or report status

Always validate:

1. File hash
2. Chain integrity
3. Git history
4. Timestamp proof

---

### 2.2 Reproducibility

All findings must be:

* repeatable
* independently verifiable

If another person cannot reproduce your result → it is weak evidence

---

### 2.3 Assume Compromise

Always assume:

* system may be partially compromised
* logs may be manipulated

Your job is to **prove consistency across layers**

---

## 3. Standard Investigation Workflow

### Step 1 — Identify Target File

Example:

```text
C:\Recordings\video.mp4
```

---

### Step 2 — Generate Report

```powershell
.\report.ps1 -FilePath "C:\Recordings\video.mp4"
```

---

### Step 3 — Validate Hash

Compare:

* current hash (from report)
* recorded hash (from log)

---

### Step 4 — Validate Chain

Check:

* chain integrity = TRUE

If FALSE:
👉 log tampering suspected

---

### Step 5 — Validate Git History

Check:

* commits exist
* no unexpected gaps
* signatures valid

---

### Step 6 — Validate Timestamp

Check:

* OpenTimestamp proof exists
* proof verifies successfully

---

### Step 7 — Cross-check Anchors

Compare:

* local chain hash
* public anchor records

---

## 4. Investigation Scenarios

---

### 4.1 Scenario: File is Untouched

#### Indicators

* Hash match = TRUE
* Chain valid = TRUE
* Timestamp valid = TRUE

#### Conclusion

> File has not been modified since recorded time

---

### 4.2 Scenario: File Tampering

#### Indicators

* Hash mismatch
* Chain still valid

#### Interpretation

* File was modified AFTER logging

#### Example

```text
Original hash: ABC123
Current hash: XYZ999
```

#### Conclusion

> File integrity compromised

---

### 4.3 Scenario: Log Tampering

#### Indicators

* Chain validation FAILED

#### Interpretation

* CSV or log edited manually

#### Conclusion

> Evidence log is unreliable

---

### 4.4 Scenario: History Rewrite Attempt

#### Indicators

* Missing commits
* Inconsistent timeline
* Anchor mismatch

#### Example

```text
Expected chain hash: C123
Current chain hash: C999
```

#### Conclusion

> Git history manipulation suspected

---

### 4.5 Scenario: Fake Recompute Attack

#### Attack

1. Modify file
2. Recompute hash
3. Update CSV

#### Indicators

* Hash matches
* Chain mismatch
* Anchor mismatch

#### Conclusion

> Attempt to forge history detected

---

### 4.6 Scenario: Missing Timestamp Proof

#### Indicators

* `.ots` file missing
* verification fails

#### Interpretation

* timestamp proof unavailable

#### Conclusion

> Timeline cannot be independently verified

---

## 5. Red Flags (Immediate Attention)

* Chain validation fails
* Missing `.ots` files
* Unsigned Git commits
* Sudden large gaps in commit history
* Manual edits in CSV
* Inconsistent timestamps

---

## 6. Evidence Validation Checklist

Before accepting evidence:

✔ Hash matches
✔ Chain valid
✔ Git history intact
✔ Commits signed
✔ Timestamp verified
✔ Anchor matches

If ANY fails → investigation required

---

## 7. Evidence Strength Levels

| Level    | Description                      |
| -------- | -------------------------------- |
| Strong   | All checks pass                  |
| Moderate | Minor gaps (e.g. missing anchor) |
| Weak     | Chain or Git issues              |
| Invalid  | Multiple failures                |

---

## 8. Example Investigation (End-to-End)

### Case

User claims:

> “This video was not modified”

---

### Step 1 — Generate report

```text
STATUS: VERIFIED
```

---

### Step 2 — Validate chain

Result:

```text
Chain Valid: TRUE
```

---

### Step 3 — Validate timestamp

Result:

```text
OpenTimestamp: VERIFIED
```

---

### Final Conclusion

> File integrity confirmed since recorded timestamp

---

## 9. Reporting Findings

When documenting results:

Include:

* file name
* hash values
* verification results
* timestamp proof status
* final conclusion

---

### Example Statement

> The file "video.mp4" was verified using SHA-256 hashing.
> The computed hash matches the recorded value.
> The integrity chain is valid and unbroken.
> Timestamp proof confirms existence prior to recorded date.
> No evidence of tampering detected.

---

## 10. Common Mistakes

❌ Trusting only hash match
❌ Ignoring chain validation
❌ Skipping timestamp verification
❌ Not checking Git history
❌ Accepting incomplete evidence

---

## 11. Limitations

This system CANNOT prove:

* original authenticity of file
* intent of modification
* absence of compromise before logging

---

## 12. Best Practices

✔ Always verify independently
✔ Preserve original files
✔ Keep evidence read-only
✔ Document every step
✔ Maintain audit trail

---

## 13. Summary

A valid investigation requires:

* multiple independent verifications
* consistent results across layers
* reproducibility

If everything aligns:

> Evidence is strong and defensible

---

## 14. Disclaimer

This guide supports technical verification.

Final legal interpretation depends on:

* jurisdiction
* procedures
* expert testimony
