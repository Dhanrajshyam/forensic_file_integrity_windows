"""Unit tests for chain.py — hash logic, CSV I/O, state, exclusion, integrity."""

import csv
import hashlib
import json
import os
import tempfile

import pytest

import chain  # noqa: E402 (path set by conftest.py)

# Pre-computed expected value for cross-system parity test.
# Verified independently: SHA256("TESTHASH|PREVHASH|2024-01-15T10:00:00+0000")
_PARITY_HASH = "d2f39af05877491d420ffb9c0fa1114f0f3d78f4d7d55a310d1f83f465e3699b"


# ── compute_chain_hash ────────────────────────────────────────────────────────

class TestComputeChainHash:

    def test_formula_is_sha256_of_pipe_joined_fields(self):
        fh, prev, ts = "abc", "def", "2024-01-01T00:00:00+0000"
        raw = f"{fh}|{prev}|{ts}"
        assert chain.compute_chain_hash(fh, prev, ts) == (
            hashlib.sha256(raw.encode("utf-8")).hexdigest()
        )

    def test_first_entry_empty_prev_produces_valid_64char_hex(self):
        result = chain.compute_chain_hash("somehash", "", "2024-01-01T00:00:00+0000")
        assert len(result) == 64
        assert all(c in "0123456789abcdef" for c in result)

    def test_is_deterministic(self):
        args = ("h1", "p1", "2024-06-01T12:00:00+0000")
        assert chain.compute_chain_hash(*args) == chain.compute_chain_hash(*args)

    def test_changing_file_hash_changes_result(self):
        ts = "2024-01-01T00:00:00+0000"
        assert (chain.compute_chain_hash("A", "prev", ts) !=
                chain.compute_chain_hash("B", "prev", ts))

    def test_changing_prev_changes_result(self):
        ts = "2024-01-01T00:00:00+0000"
        assert (chain.compute_chain_hash("h", "prev1", ts) !=
                chain.compute_chain_hash("h", "prev2", ts))

    def test_changing_timestamp_changes_result(self):
        assert (chain.compute_chain_hash("h", "p", "2024-01-01T00:00:00+0000") !=
                chain.compute_chain_hash("h", "p", "2024-01-02T00:00:00+0000"))

    def test_cross_system_parity_with_powershell(self):
        """Python result must match PowerShell Get-ChainHash for the same inputs.

        PowerShell formula:
          $raw = "TESTHASH|PREVHASH|2024-01-15T10:00:00+0000"
          [SHA256]::Create().ComputeHash([UTF8]::GetBytes($raw)) | hex join
        """
        result = chain.compute_chain_hash(
            "TESTHASH", "PREVHASH", "2024-01-15T10:00:00+0000"
        )
        assert result == _PARITY_HASH


# ── get_last_chain_hash ───────────────────────────────────────────────────────

class TestGetLastChainHash:

    def test_missing_file_returns_empty(self, tmp_path):
        assert chain.get_last_chain_hash(str(tmp_path / "nope.csv")) == ""

    def test_header_only_file_returns_empty(self, tmp_path):
        p = tmp_path / "chain_log.csv"
        p.write_text("FileName,FullPath,FileHash,Timestamp,ChainHash\n")
        assert chain.get_last_chain_hash(str(p)) == ""

    def test_single_entry_returns_its_hash(self, tmp_path):
        p = tmp_path / "chain_log.csv"
        expected = "a" * 64
        p.write_text(
            "FileName,FullPath,FileHash,Timestamp,ChainHash\n"
            f"f.mp4,/data/f.mp4,hash,2024-01-01T00:00:00+0000,{expected}\n"
        )
        assert chain.get_last_chain_hash(str(p)) == expected

    def test_multiple_entries_returns_last(self, tmp_path):
        p = tmp_path / "chain_log.csv"
        first = "b" * 64
        last = "c" * 64
        p.write_text(
            "FileName,FullPath,FileHash,Timestamp,ChainHash\n"
            f"a.mp4,/data/a.mp4,h1,2024-01-01T00:00:00+0000,{first}\n"
            f"b.mp4,/data/b.mp4,h2,2024-01-02T00:00:00+0000,{last}\n"
        )
        assert chain.get_last_chain_hash(str(p)) == last


# ── append_chain_entry ────────────────────────────────────────────────────────

class TestAppendChainEntry:

    def _read_csv(self, path):
        with open(path, newline="", encoding="utf-8") as f:
            return list(csv.DictReader(f))

    def test_creates_file_with_header_on_first_call(self, tmp_path):
        p = str(tmp_path / "chain_log.csv")
        chain.append_chain_entry(p, "f.mp4", "/data/f.mp4", "h1",
                                 "2024-01-01T00:00:00+0000", "c1")
        rows = self._read_csv(p)
        assert len(rows) == 1
        assert rows[0]["FileName"] == "f.mp4"

    def test_header_written_exactly_once(self, tmp_path):
        p = str(tmp_path / "chain_log.csv")
        for i in range(3):
            chain.append_chain_entry(p, f"f{i}.mp4", f"/data/f{i}.mp4",
                                     f"h{i}", "2024-01-01T00:00:00+0000",
                                     f"{'a' * 64}")
        with open(p, encoding="utf-8") as f:
            content = f.read()
        assert content.count("FileName") == 1

    def test_all_fields_stored_correctly(self, tmp_path):
        p = str(tmp_path / "chain_log.csv")
        chain_hash = "d" * 64
        chain.append_chain_entry(p, "cam.mp4", "/mnt/rec/cam.mp4",
                                 "filehash", "2024-06-01T10:00:00+0000",
                                 chain_hash)
        rows = self._read_csv(p)
        assert rows[0] == {
            "FileName": "cam.mp4",
            "FullPath": "/mnt/rec/cam.mp4",
            "FileHash": "filehash",
            "Timestamp": "2024-06-01T10:00:00+0000",
            "ChainHash": chain_hash,
        }

    def test_path_with_spaces_and_commas_survives_csv_roundtrip(self, tmp_path):
        p = str(tmp_path / "chain_log.csv")
        tricky = "/mnt/Camera Recordings/2024, Jan/cam1.mp4"
        chain.append_chain_entry(p, "cam1.mp4", tricky, "h",
                                 "2024-01-01T00:00:00+0000", "e" * 64)
        rows = self._read_csv(p)
        assert rows[0]["FullPath"] == tricky


# ── save_state / load_state ───────────────────────────────────────────────────

class TestState:

    def test_round_trip(self, tmp_path):
        p = str(tmp_path / "state.json")
        data = {"/mnt/rec/a.mp4": "hash1", "/mnt/rec/b.mp4": "hash2"}
        chain.save_state(p, data)
        assert chain.load_state(p) == data

    def test_missing_file_returns_empty_dict(self, tmp_path):
        assert chain.load_state(str(tmp_path / "nope.json")) == {}

    def test_corrupt_json_returns_empty_dict(self, tmp_path):
        p = tmp_path / "state.json"
        p.write_text("{broken json")
        assert chain.load_state(str(p)) == {}

    def test_save_state_is_atomic_no_tmp_left_behind(self, tmp_path):
        p = str(tmp_path / "state.json")
        chain.save_state(p, {"k": "v"})
        # After a successful save the .tmp file must be gone
        assert not os.path.exists(p + ".tmp")
        assert os.path.exists(p)

    def test_save_empty_dict(self, tmp_path):
        p = str(tmp_path / "state.json")
        chain.save_state(p, {})
        assert chain.load_state(p) == {}


# ── should_exclude ────────────────────────────────────────────────────────────

class TestShouldExclude:

    def test_exact_extension_pattern(self):
        assert chain.should_exclude("/data/file.tmp", ["*.tmp"])

    def test_prefix_wildcard_pattern(self):
        assert chain.should_exclude("/data/~$lockfile", ["~$*"])

    def test_non_matching_pattern_not_excluded(self):
        assert not chain.should_exclude("/data/video.mp4", ["*.tmp", "*.part"])

    def test_empty_patterns_never_excludes(self):
        assert not chain.should_exclude("/data/anything.mp4", [])

    def test_multiple_patterns_first_match_wins(self):
        patterns = ["*.tmp", "*.part", "desktop.ini"]
        assert chain.should_exclude("/data/desktop.ini", patterns)
        assert chain.should_exclude("/data/clip.part", patterns)

    def test_basename_only_checked(self):
        # The directory name should not trigger the pattern
        assert not chain.should_exclude("/tmp/recordings/video.mp4", ["*.tmp"])


# ── end-to-end chain integrity ────────────────────────────────────────────────

class TestChainIntegrity:
    """Build a multi-entry chain and verify tamper-detection properties."""

    def _build_chain(self, tmp_path, n=4):
        """Append n entries and return the CSV path."""
        log = str(tmp_path / "chain_log.csv")
        prev = ""
        for i in range(n):
            fh = hashlib.sha256(f"file{i}".encode()).hexdigest()
            ts = f"2024-01-0{i + 1}T00:00:00+0000"
            ch = chain.compute_chain_hash(fh, prev, ts)
            chain.append_chain_entry(log, f"f{i}.mp4", f"/data/f{i}.mp4",
                                     fh, ts, ch)
            prev = ch
        return log

    def _verify(self, log_path):
        rows = []
        with open(log_path, newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        prev = ""
        for row in rows:
            calc = chain.compute_chain_hash(
                row["FileHash"], prev, row["Timestamp"]
            )
            if calc != row["ChainHash"]:
                return False
            prev = row["ChainHash"]
        return True

    def test_clean_chain_verifies(self, tmp_path):
        log = self._build_chain(tmp_path)
        assert self._verify(log)

    def test_tampering_file_hash_breaks_chain(self, tmp_path):
        log = self._build_chain(tmp_path)
        with open(log, newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        rows[0]["FileHash"] = "FAKEHASH"
        with open(log, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=rows[0].keys())
            w.writeheader()
            w.writerows(rows)
        assert not self._verify(log)

    def test_tampering_timestamp_breaks_chain(self, tmp_path):
        log = self._build_chain(tmp_path)
        with open(log, newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        rows[1]["Timestamp"] = "2000-01-01T00:00:00+0000"
        with open(log, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=rows[0].keys())
            w.writeheader()
            w.writerows(rows)
        assert not self._verify(log)

    def test_deleting_first_entry_breaks_all_subsequent(self, tmp_path):
        log = self._build_chain(tmp_path, n=4)
        with open(log, newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        # Remove first data row — row 1 and beyond now reference wrong prev hash
        rows = rows[1:]
        with open(log, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=rows[0].keys())
            w.writeheader()
            w.writerows(rows)
        assert not self._verify(log)

    def test_inserting_a_fake_entry_breaks_chain(self, tmp_path):
        log = self._build_chain(tmp_path, n=2)
        with open(log, newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        fake = {
            "FileName": "fake.mp4",
            "FullPath": "/data/fake.mp4",
            "FileHash": "fakehash",
            "Timestamp": "2024-01-01T06:00:00+0000",
            "ChainHash": "f" * 64,  # wrong chain hash
        }
        rows.insert(1, fake)
        with open(log, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=rows[0].keys())
            w.writeheader()
            w.writerows(rows)
        assert not self._verify(log)


# ── compute_file_hash ─────────────────────────────────────────────────────────

class TestComputeFileHash:

    def test_produces_correct_sha256_for_known_content(self, tmp_path):
        p = tmp_path / "test.mp4"
        p.write_bytes(b"hello world")
        expected = hashlib.sha256(b"hello world").hexdigest()
        result = chain.compute_file_hash(str(p))
        assert result == expected

    def test_different_content_different_hash(self, tmp_path):
        a = tmp_path / "a.mp4"
        b = tmp_path / "b.mp4"
        a.write_bytes(b"content A")
        b.write_bytes(b"content B")
        assert chain.compute_file_hash(str(a)) != chain.compute_file_hash(str(b))

    def test_missing_file_returns_none_after_retries(self, tmp_path):
        result = chain.compute_file_hash(
            str(tmp_path / "missing.mp4"), max_retries=1, retry_delay=0.0
        )
        assert result is None
