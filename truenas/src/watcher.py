import json
import os
import signal
import threading
import time

from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

from chain import (
    append_chain_entry,
    compute_chain_hash,
    compute_file_hash,
    get_last_chain_hash,
    get_timestamp,
    load_state,
    rotate_chain_log_if_needed,
    save_state,
    should_exclude,
    write_log,
)
from signer import commit_and_push, ensure_repo
from timestamper import stamp


# ── Config ──────────────────────────────────────────────────────────────────

def load_config() -> dict:
    config_path = os.environ.get(
        "CONFIG_PATH", "/app/config/config.json"
    )
    with open(config_path, "r", encoding="utf-8") as fh:
        return json.load(fh)


# ── Global state ────────────────────────────────────────────────────────────

# RLock so _handle_file (holding the lock) can call _add_chain_entry
# (which also acquires the lock) without deadlocking.
_lock = threading.RLock()

_debounce: dict[str, float] = {}  # path -> last event epoch
_DEBOUNCE_SEC = 2.0
_last_chain_hash: str = ""        # updated inside _lock


# ── Core logic ──────────────────────────────────────────────────────────────

def _add_chain_entry(
    cfg: dict,
    state: dict,
    file_name: str,
    full_path: str,
    file_hash: str,
    state_key: str = "",
    *,
    skip_commit: bool = False,
) -> None:
    """Append one chain entry; updates state[state_key] under _lock."""
    global _last_chain_hash
    with _lock:
        timestamp = get_timestamp()
        prev = get_last_chain_hash(cfg["chainLogPath"])
        chain_hash = compute_chain_hash(file_hash, prev, timestamp)
        append_chain_entry(
            cfg["chainLogPath"], file_name, full_path,
            file_hash, timestamp, chain_hash,
        )
        _last_chain_hash = chain_hash
        if state_key:
            state[state_key] = file_hash  # inside lock — thread-safe

    write_log(
        cfg["logPath"], "EVENT",
        f"Recorded: {file_name} (Hash: {file_hash[:12]}...)",
    )

    if not skip_commit:
        msg = (
            f"[autocommit - {cfg['systemName']}]"
            f" {file_name} at {get_timestamp()}"
        )
        _save_chain_state(cfg, msg)
        if cfg.get("enableOpenTimestamps"):
            store = os.path.dirname(cfg["chainLogPath"])
            stamp(
                _last_chain_hash, store,
                lambda lvl, m: write_log(cfg["logPath"], lvl, m),
            )


def _save_chain_state(cfg: dict, message: str) -> None:
    repo_path = cfg.get("repoPath", "")
    git_dir = os.path.join(repo_path, ".git")
    if not repo_path or not os.path.exists(git_dir):
        return
    store = os.path.dirname(cfg["chainLogPath"])
    ots_path = os.path.join(store, "latest_hash.txt.ots")
    try:
        commit_and_push(
            repo_path=repo_path,
            system_name=cfg["systemName"],
            chain_log_path=cfg["chainLogPath"],
            state_path=cfg["statePath"],
            ots_path=ots_path if os.path.exists(ots_path) else None,
            message=message,
            gpg_key_id=cfg.get("gpgKeyId", ""),
            remote=cfg.get("gitRemote", "origin"),
            branch=cfg.get("gitBranch", "truenas_camera_server"),
            github_token=os.environ.get("GITHUB_TOKEN", ""),
            remote_url=cfg.get("gitRemoteUrl", ""),
        )
    except Exception as exc:
        write_log(cfg["logPath"], "WARNING", f"Git commit/push failed: {exc}")


def _handle_file(
    cfg: dict, state: dict, path: str, change_type: str,
) -> None:
    now = time.monotonic()
    if path in _debounce and (now - _debounce[path]) < _DEBOUNCE_SEC:
        return
    _debounce[path] = now

    file_name = os.path.basename(path)
    exclude_patterns = cfg.get("excludePatterns", [])

    if change_type in {"created", "modified"}:
        if not os.path.exists(path):
            return
        if should_exclude(path, exclude_patterns):
            return

        # Hash outside the lock — large video files take seconds
        file_hash = compute_file_hash(path)
        if file_hash is None:
            write_log(
                cfg["logPath"], "INFO",
                f"Skipped (still being written, "
                f"periodic scan will catch it): {file_name}",
            )
            return

        state_key = path.replace("\\", "/")
        with _lock:
            if state.get(state_key) == file_hash:
                return
            _add_chain_entry(cfg, state, file_name, path, file_hash, state_key)
        save_state(cfg["statePath"], state)
        print(f"[{get_timestamp()}] {change_type.capitalize()}: {file_name}")

    elif change_type == "deleted":
        state_key = path.replace("\\", "/")
        with _lock:
            if state_key not in state:
                return
            last_known = state.pop(state_key)
        save_state(cfg["statePath"], state)
        _add_chain_entry(
            cfg, state, file_name, path, f"DELETED:{last_known}",
        )
        print(f"[{get_timestamp()}] Deleted: {file_name}")


def _handle_move(
    cfg: dict, state: dict, src_path: str, dest_path: str,
) -> None:
    """Handle renames/moves: record deletion of src, addition of dest.

    Also correctly handles move-out (dest outside watched dirs) by
    removing the source key from state without adding the destination.
    """
    exclude_patterns = cfg.get("excludePatterns", [])
    src_key = src_path.replace("\\", "/")
    src_name = os.path.basename(src_path)
    dest_name = os.path.basename(dest_path)

    # Remove source from state if it was tracked
    with _lock:
        last_known = state.pop(src_key, None)

    if last_known is not None:
        # Record the old path as deleted
        save_state(cfg["statePath"], state)
        _add_chain_entry(
            cfg, state, src_name, src_path, f"DELETED:{last_known}",
        )

    # Add destination only if it lands inside a watched directory
    watch_paths = cfg.get("watchPaths", [])
    dest_in_watch = any(dest_path.startswith(wp) for wp in watch_paths)
    if (
        dest_in_watch
        and not should_exclude(dest_path, exclude_patterns)
        and os.path.exists(dest_path)
    ):
        file_hash = compute_file_hash(dest_path)
        if file_hash:
            dest_key = dest_path.replace("\\", "/")
            with _lock:
                _add_chain_entry(
                    cfg, state, dest_name, dest_path, file_hash, dest_key,
                )
            save_state(cfg["statePath"], state)

    print(f"[{get_timestamp()}] Moved: {src_name} → {dest_name}")


def _directory_scan(cfg: dict, state: dict) -> int:
    changed = 0
    exclude_patterns = cfg.get("excludePatterns", [])
    for watch_path in cfg["watchPaths"]:
        if not os.path.exists(watch_path):
            continue
        for root, _, files in os.walk(watch_path):
            for fname in files:
                full_path = os.path.join(root, fname)
                if should_exclude(full_path, exclude_patterns):
                    continue

                # Hash outside the lock — large video files take seconds
                file_hash = compute_file_hash(full_path)
                if file_hash is None:
                    write_log(
                        cfg["logPath"], "INFO",
                        f"Skipped during scan "
                        f"(still being written): {fname}",
                    )
                    continue

                state_key = full_path.replace("\\", "/")
                with _lock:
                    if state.get(state_key) != file_hash:
                        _add_chain_entry(
                            cfg, state, fname, full_path, file_hash,
                            state_key, skip_commit=True,
                        )
                        changed += 1

    save_state(cfg["statePath"], state)
    return changed


def _prune_debounce() -> None:
    """Remove debounce entries older than 60 s to prevent unbounded growth."""
    cutoff = time.monotonic() - 60.0
    stale = [k for k, v in list(_debounce.items()) if v < cutoff]
    for k in stale:
        _debounce.pop(k, None)


# ── Watchdog handler ────────────────────────────────────────────────────────

class _Handler(FileSystemEventHandler):
    def __init__(self, cfg: dict, state: dict):
        self._cfg = cfg
        self._state = state

    def on_created(self, event):
        if not event.is_directory:
            _handle_file(
                self._cfg, self._state, event.src_path, "created"
            )

    def on_modified(self, event):
        if not event.is_directory:
            _handle_file(
                self._cfg, self._state, event.src_path, "modified"
            )

    def on_deleted(self, event):
        if not event.is_directory:
            _handle_file(
                self._cfg, self._state, event.src_path, "deleted"
            )

    def on_moved(self, event):
        if not event.is_directory:
            _handle_move(
                self._cfg, self._state,
                event.src_path, event.dest_path,
            )


# ── Entry point ─────────────────────────────────────────────────────────────

def main():
    cfg = load_config()
    state = load_state(cfg["statePath"])

    verify_interval = cfg.get("verifyIntervalSeconds", 300)
    if verify_interval <= 0:
        verify_interval = 300

    repo_path = cfg.get("repoPath", "")
    remote_url = cfg.get("gitRemoteUrl", "")
    github_token = os.environ.get("GITHUB_TOKEN", "")

    if repo_path and remote_url:
        try:
            ensure_repo(
                repo_path, remote_url,
                cfg.get("gitBranch", "truenas_camera_server"),
                cfg.get("gpgKeyId", ""),
                github_token=github_token,
            )
        except Exception as exc:
            write_log(cfg["logPath"], "WARNING", f"Git repo init failed: {exc}")

    print("Forensic Watcher starting...")
    print(f"Watch paths: {', '.join(cfg['watchPaths'])}")
    print(f"Verify interval: {verify_interval}s")
    write_log(
        cfg["logPath"], "INFO",
        f"Watcher started. Monitoring: {', '.join(cfg['watchPaths'])}",
    )

    rotate_chain_log_if_needed(cfg["chainLogPath"], cfg["logPath"])

    # Initial full scan
    changed = _directory_scan(cfg, state)
    if changed:
        msg = (
            f"[autocommit - {cfg['systemName']}]"
            f" batch scan: {changed} file(s) at {get_timestamp()}"
        )
        _save_chain_state(cfg, msg)
        if cfg.get("enableOpenTimestamps") and _last_chain_hash:
            store = os.path.dirname(cfg["chainLogPath"])
            stamp(
                _last_chain_hash, store,
                lambda lvl, m: write_log(cfg["logPath"], lvl, m),
            )

    # Start filesystem observers
    observers = []
    for watch_path in cfg["watchPaths"]:
        if not os.path.exists(watch_path):
            print(f"Warning: watch path does not exist: {watch_path}")
            write_log(
                cfg["logPath"], "WARNING",
                f"Watch path does not exist: {watch_path}",
            )
            continue
        obs = Observer()
        obs.schedule(_Handler(cfg, state), watch_path, recursive=True)
        obs.start()
        observers.append(obs)
        print(f"Watching: {watch_path}")

    stop_event = threading.Event()

    def _shutdown(signum, frame):
        write_log(cfg["logPath"], "INFO", "Watcher stopped.")
        print("Watcher stopped.")
        stop_event.set()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    try:
        while not stop_event.is_set():
            stop_event.wait(timeout=verify_interval)
            if stop_event.is_set():
                break
            _prune_debounce()  # prevent unbounded dict growth
            rotate_chain_log_if_needed(cfg["chainLogPath"], cfg["logPath"])
            print(f"[{get_timestamp()}] Running periodic scan...")
            changed = _directory_scan(cfg, state)
            if changed:
                msg = (
                    f"[autocommit - {cfg['systemName']}]"
                    f" batch scan: {changed} file(s)"
                    f" at {get_timestamp()}"
                )
                _save_chain_state(cfg, msg)
                if cfg.get("enableOpenTimestamps") and _last_chain_hash:
                    store = os.path.dirname(cfg["chainLogPath"])
                    stamp(
                        _last_chain_hash, store,
                        lambda lvl, m: write_log(cfg["logPath"], lvl, m),
                    )
                write_log(
                    cfg["logPath"], "INFO",
                    f"Batch scan committed {changed} file(s)",
                )
    finally:
        for obs in observers:
            obs.stop()
        for obs in observers:
            obs.join()


if __name__ == "__main__":
    main()
