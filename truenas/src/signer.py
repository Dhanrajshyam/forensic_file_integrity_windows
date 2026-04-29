import os
import shutil
import subprocess
from urllib.parse import urlparse, urlunparse


def ensure_repo(
    repo_path: str,
    remote_url: str,
    branch: str,
    gpg_key_id: str,
    github_token: str = "",
) -> None:
    """Init or clone the Git repo, then configure identity + signing.

    On first run (no .git present):
      - Clones from remote_url if reachable (preserves existing history).
      - Falls back to fresh init if clone fails or no remote is set.
    On every run:
      - Writes git user identity from env vars (survives container recreation).
      - Stores the GitHub token in a repo-local credential file (600 perms)
        so it never appears in command args or Docker logs.
    """
    git_dir = os.path.join(repo_path, ".git")
    if not os.path.exists(git_dir):
        _init_or_clone(repo_path, remote_url, branch, github_token)

    # Always refresh identity — container recreation loses /root/.gitconfig
    git_name = os.environ.get("GIT_USER_NAME", "TrueNAS Watcher")
    git_email = os.environ.get(
        "GIT_USER_EMAIL", "watcher@truenas.local"
    )
    subprocess.run(
        ["git", "config", "user.name", git_name],
        cwd=repo_path, check=True, capture_output=True,
    )
    subprocess.run(
        ["git", "config", "user.email", git_email],
        cwd=repo_path, check=True, capture_output=True,
    )

    # Store token in per-repo credential file — token never in command args
    if github_token and remote_url:
        _configure_credentials(repo_path, remote_url, github_token)

    if gpg_key_id:
        subprocess.run(
            ["git", "config", "user.signingkey", gpg_key_id],
            cwd=repo_path, check=True, capture_output=True,
        )
        subprocess.run(
            ["git", "config", "commit.gpgsign", "true"],
            cwd=repo_path, check=True, capture_output=True,
        )


def _init_or_clone(
    repo_path: str,
    remote_url: str,
    branch: str,
    github_token: str,
) -> None:
    """Clone from remote (reusing existing history) or init fresh."""
    os.makedirs(repo_path, exist_ok=True)

    if remote_url:
        clone_url = _authenticated_url(remote_url, github_token)

        # Attempt 1: clone with exact branch
        r = subprocess.run(
            [
                "git", "clone",
                "--branch", branch, "--single-branch",
                clone_url, ".",
            ],
            cwd=repo_path, capture_output=True, text=True,
        )
        if r.returncode == 0:
            return

        # Attempt 2: branch not on remote yet — clone default, create ours
        r2 = subprocess.run(
            ["git", "clone", "--single-branch", clone_url, "."],
            cwd=repo_path, capture_output=True, text=True,
        )
        if r2.returncode == 0:
            subprocess.run(
                ["git", "checkout", "-b", branch],
                cwd=repo_path, check=True, capture_output=True,
            )
            return

    # Fallback: fresh local init
    subprocess.run(
        ["git", "init", "-b", branch],
        cwd=repo_path, check=True, capture_output=True,
    )
    if remote_url:
        subprocess.run(
            ["git", "remote", "add", "origin", remote_url],
            cwd=repo_path, check=True, capture_output=True,
        )


def _configure_credentials(
    repo_path: str, remote_url: str, github_token: str
) -> None:
    """Write token to a repo-local credential file (mode 0o600).

    Using git credential store means the token is never passed in
    command args and never appears in /proc/<pid>/cmdline or Docker logs.
    """
    parsed = urlparse(remote_url)
    host = parsed.hostname or "github.com"
    cred_file = os.path.join(repo_path, ".git", ".credentials")
    with open(cred_file, "w", encoding="utf-8") as fh:
        fh.write(f"https://x-access-token:{github_token}@{host}\n")
    os.chmod(cred_file, 0o600)
    subprocess.run(
        ["git", "config", "credential.helper", f"store --file {cred_file}"],
        cwd=repo_path, check=True, capture_output=True,
    )


def _authenticated_url(remote_url: str, github_token: str) -> str:
    """Inject token into HTTPS URL for one-time clone operations only."""
    if not github_token:
        return remote_url
    parsed = urlparse(remote_url)
    host = parsed.hostname or ""
    if parsed.port:
        host = f"{host}:{parsed.port}"
    return urlunparse(
        parsed._replace(netloc=f"x-access-token:{github_token}@{host}")
    )


def commit_and_push(
    repo_path: str,
    system_name: str,
    chain_log_path: str,
    state_path: str,
    ots_path: str | None,
    message: str,
    gpg_key_id: str,
    remote: str,
    branch: str,
    github_token: str,
    remote_url: str,
) -> None:
    """Copy chain artifacts into a system subfolder, commit, push."""
    if not os.path.exists(os.path.join(repo_path, ".git")):
        return

    system_folder = os.path.join(repo_path, system_name)
    os.makedirs(system_folder, exist_ok=True)

    shutil.copy2(chain_log_path, system_folder)
    shutil.copy2(state_path, system_folder)

    rel = system_name
    subprocess.run(
        ["git", "add", f"{rel}/chain_log.csv", f"{rel}/state.json"],
        cwd=repo_path, capture_output=True,
    )

    if ots_path and os.path.exists(ots_path):
        shutil.copy2(ots_path, system_folder)
        subprocess.run(
            ["git", "add", f"{rel}/latest_hash.txt.ots"],
            cwd=repo_path, capture_output=True,
        )

    gpg_args: list[str] = []
    if gpg_key_id:
        gpg_args = [f"--gpg-sign={gpg_key_id}"]
    elif _gpg_signing_enabled(repo_path):
        gpg_args = ["--gpg-sign"]

    result = subprocess.run(
        ["git", "commit", "-m", message] + gpg_args,
        cwd=repo_path, capture_output=True, text=True,
    )

    if result.returncode != 0:
        combined = result.stdout + result.stderr
        if "nothing to commit" in combined:
            return
        raise RuntimeError(
            f"git commit failed (rc={result.returncode}): "
            f"{combined.strip()[:200]}"
        )

    _push(repo_path, remote, branch, github_token, remote_url)


def _gpg_signing_enabled(repo_path: str) -> bool:
    result = subprocess.run(
        ["git", "config", "commit.gpgsign"],
        cwd=repo_path, capture_output=True, text=True,
    )
    return result.stdout.strip().lower() == "true"


def _push(
    repo_path: str,
    remote: str,
    branch: str,
    github_token: str = "",
    remote_url: str = "",
) -> None:
    """Push to remote.

    Prefers the repo-local credential store (configured by ensure_repo)
    so the token is never in command args.  Falls back to URL-embedded
    token only when the credential helper is absent.
    """
    has_cred_helper = subprocess.run(
        ["git", "config", "credential.helper"],
        cwd=repo_path, capture_output=True, check=False,
    ).returncode == 0

    if not has_cred_helper and github_token and remote_url:
        target = _authenticated_url(remote_url, github_token)
    else:
        target = remote  # credential store handles auth transparently

    subprocess.run(
        ["git", "push", "--set-upstream", target, branch],
        cwd=repo_path, capture_output=True, check=False,
    )
