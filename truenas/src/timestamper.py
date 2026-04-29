"""OpenTimestamps integration — stamp and verify chain hashes."""
import os
import subprocess
import sys

_OTS_MODULE = "opentimestamps_client.cmds"


def stamp(chain_hash: str, store_path: str, log_fn) -> None:
    """Write chain hash to a file and submit it to OpenTimestamps."""
    hash_file = os.path.join(store_path, "latest_hash.txt")
    with open(hash_file, "w", encoding="utf-8") as fh:
        fh.write(chain_hash)
    try:
        subprocess.run(
            [sys.executable, "-m", _OTS_MODULE, "stamp", hash_file],
            check=True, capture_output=True,
        )
        short = chain_hash[:12]
        log_fn("INFO", f"OTS stamp created for hash: {short}...")
    except subprocess.CalledProcessError as exc:
        msg = exc.stderr.decode(errors="replace")
        log_fn("WARNING", f"OTS stamp failed: {msg}")
    except FileNotFoundError:
        log_fn(
            "WARNING",
            "opentimestamps-client not installed or not on PATH",
        )


def verify(store_path: str, log_fn) -> str:
    """Verify the latest OTS proof. Returns a human-readable result."""
    ots_file = os.path.join(store_path, "latest_hash.txt.ots")
    if not os.path.exists(ots_file):
        return "OTS proof not found"
    try:
        result = subprocess.run(
            [sys.executable, "-m", _OTS_MODULE, "verify", ots_file],
            capture_output=True, text=True, check=False,
        )
        return result.stdout.strip() or result.stderr.strip()
    except OSError as exc:
        log_fn("WARNING", f"OTS verify failed: {exc}")
        return f"OTS verify error: {exc}"
