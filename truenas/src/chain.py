import csv
import fcntl
import fnmatch
import hashlib
import json
import os
import time
from datetime import datetime, timezone


def get_timestamp() -> str:
    return datetime.now(timezone.utc).astimezone().strftime(
        "%Y-%m-%dT%H:%M:%S%z"
    )


def compute_file_hash(
    path: str,
    max_retries: int = 5,
    retry_delay: float = 3.0,
) -> str | None:
    """SHA-256 a file, retrying if it is still open for writing.

    Returns the hex digest, or None after all retries are exhausted.
    The caller should skip and let the periodic scan catch it later.
    """
    for attempt in range(max_retries):
        try:
            with open(path, "rb") as fh:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                try:
                    h = hashlib.sha256()
                    for chunk in iter(lambda: fh.read(65536), b""):
                        h.update(chunk)
                    return h.hexdigest()
                finally:
                    fcntl.flock(fh, fcntl.LOCK_UN)
        except BlockingIOError:
            if attempt < max_retries - 1:
                time.sleep(retry_delay)
        except FileNotFoundError:
            return None  # gone between event and hash — not an error
        except OSError:
            if attempt < max_retries - 1:
                time.sleep(retry_delay)
    return None


def compute_chain_hash(
    file_hash: str, prev_chain_hash: str, timestamp: str
) -> str:
    """Identical formula to the Windows system: SHA256(fh|prev|ts)."""
    raw = f"{file_hash}|{prev_chain_hash}|{timestamp}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def get_last_chain_hash(chain_log_path: str) -> str:
    """True O(tail) read — seeks near end of file, never reads full log."""
    if not os.path.exists(chain_log_path):
        return ""
    try:
        with open(chain_log_path, "rb") as fh:
            fh.seek(0, 2)
            size = fh.tell()
            if size == 0:
                return ""
            # 512 bytes is far more than enough for one CSV row
            chunk = min(size, 512)
            fh.seek(size - chunk)
            tail = fh.read().decode("utf-8", errors="replace")
    except OSError:
        return ""

    lines = [ln.strip() for ln in tail.splitlines() if ln.strip()]
    if not lines:
        return ""
    last_line = lines[-1]
    if last_line.startswith("FileName"):
        return ""
    # ChainHash is always the last column — 64-char lowercase hex
    parts = last_line.split(",")
    if parts:
        candidate = parts[-1].strip()
        if (
            len(candidate) == 64
            and all(c in "0123456789abcdef" for c in candidate)
        ):
            return candidate
    return ""


def append_chain_entry(
    chain_log_path: str,
    file_name: str,
    full_path: str,
    file_hash: str,
    timestamp: str,
    chain_hash: str,
) -> None:
    """Append one entry to the CSV under an exclusive advisory file lock.

    The header is written when the file is empty, checked atomically
    under the lock — no TOCTOU race.
    """
    dir_path = os.path.dirname(chain_log_path)
    if dir_path:
        os.makedirs(dir_path, exist_ok=True)
    with open(chain_log_path, "a", newline="", encoding="utf-8") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            writer = csv.writer(fh)
            if fh.tell() == 0:  # checked under lock — no race
                writer.writerow([
                    "FileName", "FullPath", "FileHash",
                    "Timestamp", "ChainHash",
                ])
            writer.writerow(
                [file_name, full_path, file_hash, timestamp, chain_hash]
            )
            fh.flush()
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


def load_state(state_path: str) -> dict:
    if not os.path.exists(state_path):
        return {}
    with open(state_path, "r", encoding="utf-8") as fh:
        try:
            return json.load(fh)
        except json.JSONDecodeError:
            return {}


def save_state(state_path: str, state: dict) -> None:
    dir_path = os.path.dirname(state_path)
    if dir_path:
        os.makedirs(dir_path, exist_ok=True)
    # Atomic write: temp + os.replace so a crash never corrupts state.json
    tmp = state_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2)
    os.replace(tmp, state_path)


def write_log(log_path: str, level: str, message: str) -> None:
    dir_path = os.path.dirname(log_path)
    if dir_path:
        os.makedirs(dir_path, exist_ok=True)
    entry = json.dumps({
        "time": get_timestamp(), "type": level, "message": message,
    })
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(entry + "\n")


def should_exclude(path: str, exclude_patterns: list[str]) -> bool:
    name = os.path.basename(path)
    return any(fnmatch.fnmatch(name, p) for p in exclude_patterns)


def rotate_chain_log_if_needed(
    chain_log_path: str, log_path: str
) -> None:
    """Archive the log if the oldest entry is from a previous month.

    Reads only the first data row — never loads the full file into memory.
    """
    if not os.path.exists(chain_log_path):
        return
    log_month = None
    with open(chain_log_path, "r", encoding="utf-8") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            reader = csv.DictReader(fh)
            try:
                first_row = next(reader)  # only the first data row
            except StopIteration:
                return  # header-only — nothing to rotate
            first_ts = first_row.get("Timestamp", "")
            if not first_ts or len(first_ts) < 7:
                return
            log_month = first_ts[:7]
            current_month = datetime.now().strftime("%Y-%m")
            if log_month == current_month:
                return
            archive = chain_log_path.replace(
                "chain_log.csv", f"chain_log_{log_month}.csv"
            )
            os.rename(chain_log_path, archive)
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)

    if log_month is None:
        return
    # Write fresh header (lock released; old file already renamed)
    with open(chain_log_path, "w", newline="", encoding="utf-8") as fh:
        csv.writer(fh).writerow([
            "FileName", "FullPath", "FileHash", "Timestamp", "ChainHash",
        ])
    write_log(
        log_path, "INFO",
        f"Chain log rotated: archived as chain_log_{log_month}.csv",
    )
