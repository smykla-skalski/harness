from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "disable-fsmonitor-dormant.sh"


def make_fake_git_repo(root: Path, fsmonitor_local: str | None, age_days: int) -> Path:
    """Create a `.git`-only fake repo at root with HEAD mtime age_days in the past."""
    git_dir = root / ".git"
    git_dir.mkdir(parents=True)
    (git_dir / "HEAD").write_text("ref: refs/heads/main\n")
    cfg_lines = ["[core]\n"]
    if fsmonitor_local is not None:
        cfg_lines.append(f"\tfsmonitor = {fsmonitor_local}\n")
    cfg_lines += ["\trepositoryformatversion = 0\n"]
    (git_dir / "config").write_text("".join(cfg_lines))
    past = time.time() - age_days * 86400
    os.utime(git_dir / "HEAD", (past, past))
    return git_dir


def run_script(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(SCRIPT_PATH), *args],
        check=False,
        capture_output=True,
        text=True,
    )


class DisableFsmonitorDormantTests(unittest.TestCase):

    def test_dormant_repo_reported_in_dry_run_not_modified(self) -> None:
        with tempfile.TemporaryDirectory() as root_str:
            root = Path(root_str).resolve()
            repo = root / "user" / "stale-repo"
            repo.mkdir(parents=True)
            git_dir = make_fake_git_repo(repo, fsmonitor_local=None, age_days=60)
            completed = run_script("--root", str(root), "--days", "30")
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn(f"dormant   gitdir={git_dir}", completed.stdout)
            self.assertIn("no_signal=0", completed.stdout)
            self.assertIn("dormant=1", completed.stdout)
            self.assertIn("Dry-run", completed.stdout)
            # config must not have been modified by dry-run
            self.assertNotIn(
                "fsmonitor = false",
                (git_dir / "config").read_text(),
                "dry-run must not edit config",
            )

    def test_apply_sets_local_fsmonitor_false(self) -> None:
        with tempfile.TemporaryDirectory() as root_str:
            root = Path(root_str).resolve()
            repo = root / "user" / "stale-repo"
            repo.mkdir(parents=True)
            git_dir = make_fake_git_repo(repo, fsmonitor_local=None, age_days=60)
            completed = run_script("--root", str(root), "--days", "30", "--apply")
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("set false:", completed.stdout)
            self.assertIn("applied=1", completed.stdout)
            self.assertIn(
                "fsmonitor = false",
                (git_dir / "config").read_text(),
                "--apply must write fsmonitor=false into config",
            )

    def test_recent_repo_is_not_reported(self) -> None:
        with tempfile.TemporaryDirectory() as root_str:
            root = Path(root_str).resolve()
            repo = root / "user" / "fresh-repo"
            repo.mkdir(parents=True)
            git_dir = make_fake_git_repo(repo, fsmonitor_local=None, age_days=3)
            completed = run_script("--root", str(root), "--days", "30")
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("active=1", completed.stdout)
            self.assertIn("dormant=0", completed.stdout)
            self.assertNotIn(f"gitdir={git_dir}", completed.stdout)

    def test_repo_with_local_false_is_already_disabled(self) -> None:
        with tempfile.TemporaryDirectory() as root_str:
            root = Path(root_str).resolve()
            repo = root / "user" / "already-off"
            repo.mkdir(parents=True)
            git_dir = make_fake_git_repo(repo, fsmonitor_local="false", age_days=200)
            completed = run_script("--root", str(root), "--days", "30")
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("already_disabled=1", completed.stdout)
            self.assertIn("dormant=0", completed.stdout)

    def test_exclude_pattern_skips_match(self) -> None:
        with tempfile.TemporaryDirectory() as root_str:
            root = Path(root_str).resolve()
            (root / "kong/kong-mesh").mkdir(parents=True)
            (root / "user/random").mkdir(parents=True)
            protected_git = make_fake_git_repo(root / "kong/kong-mesh", None, 200)
            candidate_git = make_fake_git_repo(root / "user/random", None, 200)
            completed = run_script(
                "--root", str(root),
                "--days", "30",
                "--exclude", "/kong/kong-mesh/",
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("excluded=1", completed.stdout)
            self.assertIn(f"gitdir={candidate_git}", completed.stdout)
            self.assertNotIn(f"gitdir={protected_git}", completed.stdout)

    def test_days_threshold_is_honored(self) -> None:
        with tempfile.TemporaryDirectory() as root_str:
            root = Path(root_str).resolve()
            (root / "user/borderline").mkdir(parents=True)
            git_dir = make_fake_git_repo(root / "user/borderline", None, 20)
            # With --days 7 the 20-day-old repo is dormant
            completed = run_script("--root", str(root), "--days", "7")
            self.assertIn("dormant=1", completed.stdout)
            # With --days 60 the same repo is active
            completed = run_script("--root", str(root), "--days", "60")
            self.assertIn("active=1", completed.stdout)
            self.assertIn("dormant=0", completed.stdout)

    def test_mixed_repos_counts(self) -> None:
        with tempfile.TemporaryDirectory() as root_str:
            root = Path(root_str).resolve()
            # 2 dormant + 1 recent + 1 already-disabled + 1 excluded
            for name in ("a/dormant1", "a/dormant2", "a/fresh", "a/off", "skip/me"):
                (root / name).mkdir(parents=True)
            make_fake_git_repo(root / "a/dormant1", None, 90)
            make_fake_git_repo(root / "a/dormant2", None, 90)
            make_fake_git_repo(root / "a/fresh", None, 1)
            make_fake_git_repo(root / "a/off", "false", 90)
            make_fake_git_repo(root / "skip/me", None, 90)
            completed = run_script(
                "--root", str(root),
                "--days", "30",
                "--exclude", "/skip/",
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("active=1", completed.stdout)
            self.assertIn("already_disabled=1", completed.stdout)
            self.assertIn("excluded=1", completed.stdout)
            self.assertIn("dormant=2", completed.stdout)

    def test_no_dormant_exits_clean(self) -> None:
        with tempfile.TemporaryDirectory() as root_str:
            root = Path(root_str).resolve()
            (root / "user/fresh").mkdir(parents=True)
            make_fake_git_repo(root / "user/fresh", None, 1)
            completed = run_script("--root", str(root), "--days", "30")
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("No dormant repos", completed.stdout)


if __name__ == "__main__":
    unittest.main()
