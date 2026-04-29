"""Run as: python src/reporter.py [--file /path/to/file] [--output out.txt]"""
import argparse
import csv
import json
import os
from datetime import datetime

from chain import (
    compute_chain_hash,
    compute_file_hash,
    get_timestamp,
    write_log,
)


def load_config_from_env() -> dict:
    config_path = os.environ.get("CONFIG_PATH", "/app/config/config.json")
    with open(config_path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _validate_chain(entries: list[dict]) -> bool:
    prev = ""
    for row in entries:
        calc = compute_chain_hash(row["FileHash"], prev, row["Timestamp"])
        if calc != row["ChainHash"]:
            return False
        prev = row["ChainHash"]
    return True


def _load_entries(chain_log_path: str) -> list[dict]:
    if not os.path.exists(chain_log_path):
        return []
    with open(chain_log_path, "r", encoding="utf-8", newline="") as fh:
        return list(csv.DictReader(fh))


def _build_index(entries: list[dict]) -> dict[str, list[dict]]:
    """Index entries by FullPath (or FileName for legacy rows) — O(n)."""
    idx: dict[str, list[dict]] = {}
    for e in entries:
        key = e.get("FullPath") or e.get("FileName", "")
        idx.setdefault(key, []).append(e)
    return idx


def generate_report(cfg: dict, target_path: str = "") -> list[str]:
    all_entries = _load_entries(cfg["chainLogPath"])
    chain_valid = _validate_chain(all_entries)

    report = [
        "FORENSIC FILE INTEGRITY REPORT",
        f"Generated     : {get_timestamp()}",
        f"System        : {cfg.get('systemName', 'truenas_camera_server')}",
        f"Chain Entries : {len(all_entries)}",
        f"Chain Valid   : {chain_valid}",
        "========================================",
    ]

    if target_path:
        _report_single(cfg, report, all_entries, target_path, chain_valid)
    else:
        _report_all(cfg, report, all_entries, chain_valid)

    return report


def _report_single(
    cfg: dict,
    report: list[str],
    all_entries: list[dict],
    target_path: str,
    chain_valid: bool,
) -> None:
    file_name = os.path.basename(target_path)
    idx = _build_index(all_entries)
    entries = idx.get(target_path) or idx.get(file_name, [])

    if not entries:
        report.append(f"No chain record found for: {file_name}")
        return

    first, last = entries[0], entries[-1]
    is_deleted = last["FileHash"].startswith("DELETED:")

    report += [
        "",
        f"File           : {file_name}",
        f"Requested Path : {target_path}",
        f"Chain Entries  : {len(entries)}",
        f"First Recorded : {first['Timestamp']}",
    ]

    if is_deleted:
        last_hash = last["FileHash"][len("DELETED:"):]
        report += [
            f"Last Hash      : {last_hash}",
            f"Deleted At     : {last['Timestamp']}",
            "",
            "========================================",
            "STATUS: DELETED (deletion recorded in chain)",
        ]
    elif not os.path.exists(target_path):
        report += [
            f"Recorded Hash  : {last['FileHash']}",
            f"Last Recorded  : {last['Timestamp']}",
            "",
            "========================================",
            "STATUS: FILE MISSING (not on disk, no deletion record)",
        ]
    else:
        stat = os.stat(target_path)
        # Use compute_file_hash (retries on locked files) to avoid
        # hashing a partial file if a recording is still being written.
        current_hash = compute_file_hash(target_path) or ""
        match = current_hash == last["FileHash"]
        mtime = datetime.fromtimestamp(stat.st_mtime).strftime(
            "%Y-%m-%dT%H:%M:%S"
        )
        report += [
            f"Full Path      : {target_path}",
            f"File Size      : {stat.st_size} bytes",
            f"Last Modified  : {mtime}",
            f"Current Hash   : {current_hash}",
            f"Recorded Hash  : {last['FileHash']}",
            f"Hash Match     : {match}",
            f"Last Recorded  : {last['Timestamp']}",
            "",
            "========================================",
            (
                "STATUS: VERIFIED"
                if (match and chain_valid)
                else "STATUS: TAMPERING DETECTED"
            ),
        ]


def _report_all(
    cfg: dict,
    report: list[str],
    all_entries: list[dict],
    chain_valid: bool,
) -> None:
    state_path = cfg["statePath"]
    state: dict = {}
    if os.path.exists(state_path):
        with open(state_path, "r", encoding="utf-8") as fh:
            state = json.load(fh)

    # Build O(n) index — avoids O(n²) per-file scan
    idx = _build_index(all_entries)

    deleted_files = {
        k: entries[-1]
        for k, entries in idx.items()
        if entries[-1]["FileHash"].startswith("DELETED:")
    }

    verified = modified = missing = 0
    report += ["", f"CURRENTLY TRACKED FILES ({len(state)})", "-" * 40]

    for i, state_key in enumerate(sorted(state.keys()), 1):
        full_path = state_key.replace("/", os.sep)
        fname = os.path.basename(full_path)
        recorded_hash = state[state_key]
        file_entries = idx.get(full_path) or idx.get(fname, [])
        first_ts = file_entries[0]["Timestamp"] if file_entries else "N/A"
        last_ts = file_entries[-1]["Timestamp"] if file_entries else "N/A"

        report += [
            "",
            f"[{i}] {fname}",
            f"    Path           : {full_path}",
            f"    First Recorded : {first_ts}",
            f"    Last Recorded  : {last_ts}",
        ]

        if os.path.exists(full_path):
            try:
                current_hash = compute_file_hash(full_path) or ""
                match = current_hash == recorded_hash
                report += [
                    f"    Current Hash   : {current_hash}",
                    f"    Recorded Hash  : {recorded_hash}",
                    f"    Hash Match     : {match}",
                    (
                        "    STATUS: VERIFIED"
                        if match
                        else "    STATUS: MODIFIED — TAMPERING DETECTED"
                    ),
                ]
                if match:
                    verified += 1
                else:
                    modified += 1
            except OSError as exc:
                report.append(f"    ERROR: Could not read file — {exc}")
                missing += 1
        else:
            report += [
                f"    Recorded Hash  : {recorded_hash}",
                "    STATUS: FILE MISSING (not on disk, no deletion record)",
            ]
            missing += 1

    if deleted_files:
        report += [
            "",
            f"DELETED FILES ({len(deleted_files)} — recorded in chain)",
            "-" * 40,
        ]
        for i, (key, entry) in enumerate(deleted_files.items(), 1):
            last_hash = entry["FileHash"][len("DELETED:"):]
            report += [
                "",
                f"[{i}] {key}",
                f"    Last Hash  : {last_hash}",
                f"    Deleted At : {entry['Timestamp']}",
                "    STATUS: DELETED (recorded)",
            ]

    overall = (
        "ALL VERIFIED"
        if (modified == 0 and missing == 0 and chain_valid)
        else "ISSUES FOUND"
    )
    report += [
        "",
        "========================================",
        "SUMMARY",
        f"  Verified : {verified}",
        f"  Modified : {modified}",
        f"  Missing  : {missing}",
        f"  Deleted  : {len(deleted_files)}",
        f"  Chain    : {'VALID' if chain_valid else 'INVALID'}",
        f"  Overall  : {overall}",
    ]


def main():
    parser = argparse.ArgumentParser(
        description="Generate forensic integrity report"
    )
    parser.add_argument(
        "--file", default="", help="Report on a specific file path"
    )
    parser.add_argument(
        "--output", default="", help="Write report to this file path"
    )
    args = parser.parse_args()

    cfg = load_config_from_env()
    report = generate_report(cfg, args.file)

    for line in report:
        print(line)

    if args.output:
        out_path = args.output
    else:
        ts = datetime.now().strftime("%Y%m%d%H%M%S")
        store = os.path.dirname(cfg["chainLogPath"])
        out_path = os.path.join(store, f"forensic_report_{ts}.txt")

    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(report) + "\n")
    print(f"\nReport written: {out_path}")

    write_log(
        cfg["logPath"], "INFO", f"Report generated: {out_path}"
    )


if __name__ == "__main__":
    main()
