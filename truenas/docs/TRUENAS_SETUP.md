# TrueNAS Scale — Forensic File Integrity Setup

## Overview

This system watches a recordings dataset, computes SHA-256 hashes for every new or changed file, links them into a tamper-evident cryptographic chain, signs each commit with GPG, and pushes to GitHub on the `truenas_camera_server` branch.

---

## Prerequisites

- TrueNAS Scale (Dragonfish or newer)
- Docker available (enabled via Apps > Settings)
- A GitHub repo and a Personal Access Token (classic, `repo` scope)
- A GPG key pair (optional but recommended for non-repudiation)

---

## Step 1 — Create ZFS Datasets

In TrueNAS UI → **Datasets**:

| Dataset path | Purpose |
|---|---|
| `tank/recordings` | Your camera recordings (existing or new) |
| `tank/integrity` | Chain log, Git repo, OTS proofs |

---

## Step 2 — Configure `config/config.json`

Edit `truenas/config/config.json`:

```json
{
    "watchPaths": ["/data/recordings"],
    "repoPath": "/data/store/repo",
    "systemName": "truenas_camera_server",
    "chainLogPath": "/data/store/chain_log.csv",
    "statePath": "/data/store/state.json",
    "logPath": "/data/store/system_log.jsonl",
    "gpgKeyId": "YOUR_GPG_KEY_ID",
    "gitRemote": "origin",
    "gitBranch": "truenas_camera_server",
    "gitRemoteUrl": "https://github.com/YOUR_USER/YOUR_REPO.git",
    "enableOpenTimestamps": true,
    "verifyIntervalSeconds": 300,
    "excludePatterns": ["*.tmp", "*.part", "*.crdownload"]
}
```

Add `"gitRemoteUrl"` — this is used by `setup_git.sh` and `signer.py` when injecting the GitHub token.

---

## Step 3 — Configure `docker-compose.yml`

Edit `truenas/docker-compose.yml` and update the volume paths to match your datasets:

```yaml
volumes:
  - /mnt/tank/recordings:/data/recordings:ro
  - /mnt/tank/integrity:/data/store:rw
  - /mnt/tank/integrity/gnupg:/root/.gnupg:rw
```

Set `GITHUB_TOKEN` to your Personal Access Token:

```yaml
environment:
  GITHUB_TOKEN: "ghp_xxxxxxxxxxxxxxxxxxxx"
```

---

## Step 4 — Generate / Import GPG Key

On the TrueNAS host shell or inside the container:

```bash
# Generate a new key (no passphrase for unattended operation)
gpg --batch --gen-key <<EOF
Key-Type: RSA
Key-Length: 4096
Name-Real: TrueNAS Watcher
Name-Email: watcher@truenas.local
Expire-Date: 0
%no-protection
EOF

# Note the key ID printed (8-char hex after "rsa4096/")
gpg --list-secret-keys

# Export the key for the setup script
gpg --export-secret-keys YOUR_KEY_ID > /mnt/tank/integrity/watcher.gpg.key
```

Update `config.json` with `"gpgKeyId": "YOUR_KEY_ID"`.

---

## Step 5 — Run Setup Script

Copy the `truenas/` folder to the TrueNAS host, then:

```bash
cd /path/to/truenas

# Set env vars for setup
export STORE_PATH=/mnt/tank/integrity
export GITHUB_REMOTE=https://github.com/YOUR_USER/YOUR_REPO.git
export GPG_KEY_FILE=/mnt/tank/integrity/watcher.gpg.key
export GIT_USER_NAME="TrueNAS Watcher"
export GIT_USER_EMAIL="watcher@truenas.local"

bash scripts/setup_git.sh
```

---

## Step 6 — Deploy

```bash
cd /path/to/truenas
bash scripts/install.sh
```

This builds the Docker image and starts the container. On first run it performs a full directory scan and creates the initial Git commit on `truenas_camera_server`.

---

## Step 7 — Verify

```bash
# Check the watcher is running
docker compose logs -f forensic-watcher

# Verify chain integrity
docker compose exec forensic-watcher python src/verifier.py

# Generate a forensic report for all files
docker compose exec forensic-watcher python src/reporter.py

# Report for a specific recording
docker compose exec forensic-watcher \
    python src/reporter.py --file /data/recordings/2024-01-15/cam1_01.mp4
```

---

## Chain Log Format

The CSV at `/mnt/tank/integrity/chain_log.csv` is identical in schema to the Windows system:

```
FileName,FullPath,FileHash,Timestamp,ChainHash
cam1_01.mp4,/data/recordings/cam1_01.mp4,a3f2...,2024-01-15T10:00:00+00:00,8b9c...
```

**Chain formula (same as Windows):**
```
ChainHash_N = SHA256( FileHash_N | PrevChainHash_N-1 | Timestamp_N )
```

Any retroactive modification to any entry invalidates all downstream chain hashes — undetectable tampering is cryptographically impossible.

---

## Monthly Log Rotation

At startup and before each periodic scan the watcher checks if the oldest entry is from a previous month. If so, `chain_log.csv` is renamed to `chain_log_YYYY-MM.csv` and a fresh log is started automatically.

---

## Sharing a Repo with the Windows System

Both systems write into a subfolder named after their `systemName` inside the shared GitHub repo:

```
repo/
├── desktop_pc_shyam/
│   ├── chain_log.csv
│   └── state.json
└── truenas_camera_server/
    ├── chain_log.csv
    └── state.json
```

This means both systems can push to `origin` on their respective branches without overwriting each other.
