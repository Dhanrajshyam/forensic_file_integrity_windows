"""Unit tests for signer.py — all subprocess/fs calls are mocked."""

import os
from unittest.mock import MagicMock, patch

import pytest

import signer  # noqa: E402 (path set by conftest.py)


def _ok(returncode=0, stdout="", stderr=""):
    r = MagicMock()
    r.returncode = returncode
    r.stdout = stdout
    r.stderr = stderr
    return r


def _fail(stdout="", stderr="err"):
    return _ok(returncode=1, stdout=stdout, stderr=stderr)


# ── ensure_repo ──────────────────────────────────────────────────────────────

class TestEnsureRepo:

    def _run(self, tmp_path, branch="main", gpg_key_id="",
             extra_env=None, dot_git=False, token=""):
        if dot_git:
            (tmp_path / ".git").mkdir()
        env = {
            "GIT_USER_NAME": "Test User",
            "GIT_USER_EMAIL": "t@x.com",
        }
        if extra_env:
            env.update(extra_env)
        with patch("subprocess.run", return_value=_ok()) as m, \
                patch.dict(os.environ, env, clear=False):
            signer.ensure_repo(
                str(tmp_path),
                "https://github.com/x/y.git",
                branch, gpg_key_id,
                github_token=token,
            )
        return m

    def test_skips_init_when_repo_exists(self, tmp_path):
        m = self._run(tmp_path, dot_git=True)
        args = [c.args[0] for c in m.call_args_list]
        assert not any("init" in a for a in args)

    def test_writes_user_name_from_env(self, tmp_path):
        m = self._run(
            tmp_path,
            extra_env={"GIT_USER_NAME": "Alice"},
            dot_git=True,
        )
        args = [c.args[0] for c in m.call_args_list]
        assert ["git", "config", "user.name", "Alice"] in args

    def test_writes_user_email_from_env(self, tmp_path):
        m = self._run(
            tmp_path,
            extra_env={"GIT_USER_EMAIL": "a@x.com"},
            dot_git=True,
        )
        args = [c.args[0] for c in m.call_args_list]
        assert ["git", "config", "user.email", "a@x.com"] in args

    def test_default_identity_when_env_absent(self, tmp_path):
        (tmp_path / ".git").mkdir()
        clean = {
            k: v for k, v in os.environ.items()
            if k not in ("GIT_USER_NAME", "GIT_USER_EMAIL")
        }
        with patch("subprocess.run", return_value=_ok()) as m, \
                patch.dict(os.environ, clean, clear=True):
            signer.ensure_repo(
                str(tmp_path),
                "https://github.com/x/y.git",
                "main", "",
            )
        args = [c.args[0] for c in m.call_args_list]
        assert ["git", "config", "user.name", "TrueNAS Watcher"] in args
        assert ["git", "config", "user.email",
                "watcher@truenas.local"] in args

    def test_configures_gpg_when_key_provided(self, tmp_path):
        m = self._run(tmp_path, gpg_key_id="KEY1", dot_git=True)
        args = [c.args[0] for c in m.call_args_list]
        assert ["git", "config", "user.signingkey", "KEY1"] in args
        assert ["git", "config", "commit.gpgsign", "true"] in args

    def test_skips_gpg_when_key_empty(self, tmp_path):
        m = self._run(tmp_path, gpg_key_id="", dot_git=True)
        args = [c.args[0] for c in m.call_args_list]
        assert not any("signingkey" in str(a) for a in args)


# ── _init_or_clone ───────────────────────────────────────────────────────────

class TestInitOrClone:

    def test_clones_branch_when_remote_provided(self, tmp_path):
        with patch("subprocess.run", return_value=_ok()) as m:
            signer._init_or_clone(
                str(tmp_path),
                "https://github.com/x/y.git",
                "main", "",
            )
        args = [c.args[0] for c in m.call_args_list]
        clone = [a for a in args if "clone" in a]
        assert clone
        assert "--branch" in clone[0]

    def test_fresh_init_when_no_remote(self, tmp_path):
        with patch("subprocess.run", return_value=_ok()) as m:
            signer._init_or_clone(str(tmp_path), "", "br", "")
        args = [c.args[0] for c in m.call_args_list]
        assert any("init" in a for a in args)

    def test_injects_token_into_clone_url(self, tmp_path):
        # Collect any HTTPS URL passed to a clone command.
        # The destination "." is the last arg; the URL is the one before it.
        urls: list[str] = []

        def capture(args, **kw):
            if "clone" in args:
                urls.extend(
                    a for a in args
                    if isinstance(a, str) and "://" in a
                )
            return _ok()

        with patch("subprocess.run", side_effect=capture):
            signer._init_or_clone(
                str(tmp_path),
                "https://github.com/x/y.git",
                "main", "tok",
            )
        assert any("tok" in u for u in urls)

    def test_creates_branch_when_specific_clone_fails(self, tmp_path):
        """Branch not on remote — clone default, then checkout -b."""
        checked_out = []

        def fake(args, **kw):
            if "clone" in args and "--branch" in args:
                return _fail()
            if "checkout" in args:
                checked_out.append(args)
            return _ok()

        with patch("subprocess.run", side_effect=fake):
            signer._init_or_clone(
                str(tmp_path),
                "https://github.com/x/y.git",
                "newbranch", "",
            )
        assert any("newbranch" in str(a) for a in checked_out)


# ── _configure_credentials ───────────────────────────────────────────────────

class TestConfigureCredentials:

    def test_writes_credential_file_with_600_perms(self, tmp_path):
        # os.chmod(0o600) is a no-op on Windows, so mock it and assert the
        # correct mode is requested rather than checking st_mode directly.
        (tmp_path / ".git").mkdir()
        cred = tmp_path / ".git" / ".credentials"
        with patch("subprocess.run", return_value=_ok()), \
                patch("signer.os.chmod") as mc:
            signer._configure_credentials(
                str(tmp_path),
                "https://github.com/x/y.git",
                "tok123",
            )
        assert cred.exists()
        assert "tok123" in cred.read_text()
        mc.assert_called_once_with(str(cred), 0o600)

    def test_configures_git_credential_store(self, tmp_path):
        (tmp_path / ".git").mkdir()
        with patch("subprocess.run", return_value=_ok()) as m:
            signer._configure_credentials(
                str(tmp_path),
                "https://github.com/x/y.git",
                "tok123",
            )
        args = [c.args[0] for c in m.call_args_list]
        cred = [a for a in args if "credential.helper" in a]
        assert len(cred) == 1 and "store" in cred[0][-1]


# ── commit_and_push ──────────────────────────────────────────────────────────

class TestCommitAndPush:

    def _call(self, tmp_path, ots_path=None,
              commit_rc=0, commit_out="", commit_err="",
              gpg_key_id=""):
        log = tmp_path / "chain_log.csv"
        st = tmp_path / "state.json"
        log.write_text(
            "FileName,FullPath,FileHash,Timestamp,ChainHash\n"
        )
        st.write_text("{}")
        (tmp_path / ".git").mkdir()

        def fake(args, **kw):
            if args[:2] == ["git", "commit"]:
                return _ok(commit_rc, commit_out, commit_err)
            if (args[:2] == ["git", "config"]
                    and "commit.gpgsign" in args):
                return _ok(0, "false", "")
            return _ok()

        with patch("subprocess.run", side_effect=fake) as m, \
                patch("shutil.copy2") as mc, \
                patch("os.makedirs"):
            signer.commit_and_push(
                repo_path=str(tmp_path),
                system_name="mynode",
                chain_log_path=str(log),
                state_path=str(st),
                ots_path=ots_path,
                message="test commit",
                gpg_key_id=gpg_key_id,
                remote="origin",
                branch="main",
                github_token="",
                remote_url="",
            )
        return m, mc

    def test_no_op_when_dot_git_missing(self, tmp_path):
        log = tmp_path / "chain_log.csv"
        st = tmp_path / "state.json"
        log.write_text("")
        st.write_text("{}")
        with patch("subprocess.run") as m:
            signer.commit_and_push(
                repo_path=str(tmp_path), system_name="x",
                chain_log_path=str(log), state_path=str(st),
                ots_path=None, message="m", gpg_key_id="",
                remote="origin", branch="main",
                github_token="", remote_url="",
            )
        m.assert_not_called()

    def test_copies_chain_log_and_state(self, tmp_path):
        _, mc = self._call(tmp_path)
        dests = [str(c.args[1]) for c in mc.call_args_list]
        folder = str(tmp_path / "mynode")
        assert any(folder in d for d in dests)
        assert mc.call_count >= 2

    def test_stages_chain_log_and_state(self, tmp_path):
        m, _ = self._call(tmp_path)
        adds = [
            c for c in m.call_args_list
            if c.args[0][:2] == ["git", "add"]
        ]
        assert adds
        a = adds[0].args[0]
        assert "mynode/chain_log.csv" in a
        assert "mynode/state.json" in a

    def test_includes_ots_when_present(self, tmp_path):
        ots = tmp_path / "latest_hash.txt.ots"
        ots.write_text("proof")
        m, _ = self._call(tmp_path, ots_path=str(ots))
        adds = [
            c for c in m.call_args_list
            if c.args[0][:2] == ["git", "add"]
        ]
        assert any(
            "latest_hash.txt.ots" in str(c.args[0]) for c in adds
        )

    def test_raises_on_commit_failure(self, tmp_path):
        with pytest.raises(RuntimeError, match="git commit failed"):
            self._call(tmp_path, commit_rc=1, commit_err="bad error")

    def test_silent_on_nothing_to_commit(self, tmp_path):
        self._call(
            tmp_path,
            commit_rc=1,
            commit_out="nothing to commit",
        )

    def test_gpg_flag_when_key_provided(self, tmp_path):
        m, _ = self._call(tmp_path, gpg_key_id="K123")
        commits = [
            c for c in m.call_args_list
            if c.args[0][:2] == ["git", "commit"]
        ]
        assert len(commits) == 1
        assert "--gpg-sign=K123" in commits[0].args[0]


# ── _authenticated_url ───────────────────────────────────────────────────────

class TestAuthenticatedUrl:

    def test_injects_token(self):
        url = signer._authenticated_url(
            "https://github.com/user/repo.git", "tok"
        )
        assert "tok@github.com" in url
        assert url.startswith("https://")

    def test_preserves_port(self):
        url = signer._authenticated_url(
            "https://ghe.example.com:8443/org/repo.git", "tok"
        )
        assert "8443" in url
        assert "tok@ghe.example.com:8443" in url

    def test_no_token_returns_original(self):
        orig = "https://github.com/user/repo.git"
        assert signer._authenticated_url(orig, "") == orig


# ── _push ────────────────────────────────────────────────────────────────────

class TestPush:

    def _push(self, tmp_path, token="", remote_url="",
              branch="main", has_cred=False):
        cred_rc = 0 if has_cred else 1

        def fake(args, **kw):
            if args[:2] == ["git", "config"]:
                return _ok(cred_rc)
            return _ok()

        with patch("subprocess.run", side_effect=fake) as m:
            signer._push(
                str(tmp_path), "origin", branch, token, remote_url
            )
        return m

    def test_uses_remote_name_with_cred_helper(self, tmp_path):
        m = self._push(tmp_path, has_cred=True)
        push = m.call_args_list[-1].args[0]
        assert "origin" in push

    def test_injects_token_without_cred_helper(self, tmp_path):
        m = self._push(
            tmp_path,
            token="t",
            remote_url="https://github.com/x/y.git",
        )
        push = m.call_args_list[-1].args[0]
        assert any("t" in str(a) for a in push)

    def test_correct_branch_in_push(self, tmp_path):
        m = self._push(
            tmp_path, branch="truenas_camera_server", has_cred=True
        )
        push = m.call_args_list[-1].args[0]
        assert "truenas_camera_server" in push
