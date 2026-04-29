#!/usr/bin/env bash
# Run this once inside the container (or on TrueNAS shell) to initialise
# the Git repo and import your GPG key before starting the watcher.
set -euo pipefail

STORE_PATH="${STORE_PATH:-/data/store}"
REPO_PATH="${REPO_PATH:-$STORE_PATH/repo}"
BRANCH="${BRANCH:-truenas_camera_server}"
GITHUB_REMOTE="${GITHUB_REMOTE:-}"   # e.g. https://github.com/you/your-repo.git
GPG_KEY_FILE="${GPG_KEY_FILE:-}"     # path to exported GPG private key (optional)

# ── Git repo ──────────────────────────────────────────────────────────────────
mkdir -p "$REPO_PATH"

if [ ! -d "$REPO_PATH/.git" ]; then
    git -C "$REPO_PATH" init -b "$BRANCH"
    echo "Git repo initialised at $REPO_PATH"
fi

if [ -n "$GITHUB_REMOTE" ]; then
    if git -C "$REPO_PATH" remote get-url origin &>/dev/null; then
        git -C "$REPO_PATH" remote set-url origin "$GITHUB_REMOTE"
    else
        git -C "$REPO_PATH" remote add origin "$GITHUB_REMOTE"
    fi
    echo "Remote 'origin' set to $GITHUB_REMOTE"
fi

# ── GPG key ───────────────────────────────────────────────────────────────────
if [ -n "$GPG_KEY_FILE" ] && [ -f "$GPG_KEY_FILE" ]; then
    gpg --batch --import "$GPG_KEY_FILE"
    echo "GPG key imported"
fi

# ── Git identity (required for commits) ───────────────────────────────────────
git config --global user.name  "${GIT_USER_NAME:-TrueNAS Watcher}"
git config --global user.email "${GIT_USER_EMAIL:-watcher@truenas.local}"

echo "Setup complete. Update config/config.json with your gpgKeyId and gitRemoteUrl, then start the container."
