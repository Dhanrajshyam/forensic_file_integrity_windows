"""Run as: python src/verifier.py [--output /path/to/report.txt]"""

import argparse
import csv
import json
import os
import subprocess

from chain import compute_chain_hash, write_log
from timestamper import verify as ots_verify


def load_config_from_env() -> dict:
    config_path = os.environ.get("CONFIG_PATH", "/app/config/config.json")
    with open(config_path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def verify_chain(chain_log_path: str) -> tuple[bool, list[str]]:
    """Walk every CSV row and recompute chain hashes. Returns (valid, broken_files)."""
    if not os.path.exists(chain_log_path):
        return True, []

    broken = []
    prev = ""
    with open(chain_log_path, "r", encoding="utf-8", newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            calc = compute_chain_hash(row["FileHash"], prev, row["Timestamp"])
            if calc != row["ChainHash"]:
                broken.append(row.get("FileName", "unknown"))
            prev = row["ChainHash"]
    return len(broken) == 0, broken


def verify_git_signatures(repo_path: str) -> str:
    if not repo_path or not os.path.exists(os.path.join(repo_path, ".git")):
        return "Git verification skipped (no repo configured)"
    try:
        result = subprocess.run(
            ["git", "-C", repo_path, "log", "--pretty=%G?"],
            capture_output=True, text=True
        )
        if "N" in result.stdout:
            return "Unsigned commits detected"
        return "Git signatures OK"
    except Exception as exc:
        return f"Git verification failed: {exc}"


def main():
    parser = argparse.ArgumentParser(description="Verify forensic chain integrity")
    parser.add_argument("--output", default="", help="Write results to this file path")
    args = parser.parse_args()

    cfg = load_config_from_env()
    lines = []

    def out(msg: str) -> None:
        print(msg)
        lines.append(msg)

    valid, broken = verify_chain(cfg["chainLogPath"])
    if valid:
        out("Chain VALID")
    else:
        out(f"Chain INVALID — broken at: {', '.join(broken)}")
        write_log(cfg["logPath"], "ALERT", f"Chain broken at: {', '.join(broken)}")

    out(verify_git_signatures(cfg.get("repoPath", "")))

    if cfg.get("enableOpenTimestamps"):
        store_path = os.path.dirname(cfg["chainLogPath"])
        ots_result = ots_verify(store_path,
                                lambda lvl, msg: write_log(cfg["logPath"], lvl, msg))
        out(f"OpenTimestamps: {ots_result}")

    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
