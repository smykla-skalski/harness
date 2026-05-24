from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "clean-stale-fsmonitor.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class CleanStaleFsmonitorTests(unittest.TestCase):
    """Test the clean-stale-fsmonitor.sh script with a fake lsof.

    The script shells out to `/usr/sbin/lsof` to discover each daemon's
    gitdir. We inject a fake lsof on PATH that returns canned output
    keyed by PID, plus a fake pgrep that returns a fixed pid list.
    """

    def run_script(
        self,
        *args: str,
        fake_lsof_outputs: dict[str, str],
        fake_pgrep_pids: list[str],
        fake_ps_etimes: dict[str, int] | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], str]:
        """Run the script with fake lsof/pgrep/ps. Returns (completed, kill_log_contents).

        ``fake_ps_etimes`` maps pid -> elapsed seconds. Used by duplicate-
        detection tests to assert that the newest daemon (lowest etimes) is
        the one kept; redundant duplicates with higher etimes get killed.
        Unmapped pids return an empty string (script falls back to a large
        sentinel so they sort last).
        """
        fake_ps_etimes = fake_ps_etimes or {}
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_root = Path(tmp_dir)
            fake_bin = tmp_root / "bin"
            fake_bin.mkdir()
            spool = tmp_root / "spool"
            spool.mkdir()

            # Write canned lsof outputs to disk, keyed by pid
            for pid, output in fake_lsof_outputs.items():
                (spool / f"lsof-{pid}.txt").write_text(output)

            # Write canned ps etimes to disk, keyed by pid
            for pid, etimes in fake_ps_etimes.items():
                (spool / f"ps-etimes-{pid}.txt").write_text(f"{etimes}\n")

            kill_log = tmp_root / "kill.log"
            kill_log.touch()

            # Fake lsof: parse `-p PID` and print the canned file
            write_executable(
                fake_bin / "lsof",
                f"""#!/bin/bash
pid=""
while (($#)); do
  case "$1" in
    -p) pid="$2"; shift 2 ;;
    *) shift ;;
  esac
done
file="{spool}/lsof-$pid.txt"
if [ -f "$file" ]; then
  cat "$file"
fi
""",
            )

            # Fake pgrep: ignore args, just print the pids
            pgrep_pids = "\\n".join(fake_pgrep_pids)
            write_executable(
                fake_bin / "pgrep",
                f"""#!/bin/bash
printf '{pgrep_pids}\\n'
""",
            )

            # Fake ps: parse `-p PID` and print the canned etimes file. We
            # accept `-o etimes=` to mimic the real ps but only ever return
            # the etimes line.
            write_executable(
                fake_bin / "ps",
                f"""#!/bin/bash
pid=""
while (($#)); do
  case "$1" in
    -p) pid="$2"; shift 2 ;;
    -o) shift 2 ;;
    *) shift ;;
  esac
done
file="{spool}/ps-etimes-$pid.txt"
if [ -f "$file" ]; then
  cat "$file"
fi
""",
            )

            # Fake kill: log invocations, succeed unless the pid is in $FAKE_DEAD_PIDS
            write_executable(
                fake_bin / "kill",
                f"""#!/bin/bash
signal="TERM"
pids=()
while (($#)); do
  case "$1" in
    -*) signal="${{1#-}}"; shift ;;
    *) pids+=("$1"); shift ;;
  esac
done
for pid in "${{pids[@]}}"; do
  if [ "$pid" = "DEAD" ]; then
    printf 'fail: %s sig=%s\\n' "$pid" "$signal" >> "{kill_log}"
    exit 1
  fi
  printf 'kill: %s sig=%s\\n' "$pid" "$signal" >> "{kill_log}"
done
""",
            )

            # Copy script and rewrite absolute paths to use PATH lookup
            script_text = SCRIPT_PATH.read_text()
            patched_script = tmp_root / "clean.sh"
            patched_script.write_text(
                script_text
                .replace("/usr/sbin/lsof", "lsof")
                .replace("/usr/bin/pgrep", "pgrep")
                .replace("/bin/ps", "ps")
                .replace("kill -", "kill -")
            )
            patched_script.chmod(patched_script.stat().st_mode | stat.S_IXUSR)

            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}:{env.get('PATH', '/usr/bin:/bin')}"
            completed = subprocess.run(
                ["bash", str(patched_script), *args],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            kill_log_contents = kill_log.read_text() if kill_log.exists() else ""
            return completed, kill_log_contents

    def _linked_worktree_lsof(self, repo_dir: Path, worktree_name: str) -> str:
        gitdir = repo_dir / ".git" / "worktrees" / worktree_name
        return f"""\
COMMAND PID    USER FD   TYPE DEVICE SIZE/OFF NODE NAME
git     X      u    cwd  DIR  1,19   5376     1    {os.path.expanduser("~")}
git     X      u    16r  DIR  1,19   384      2    {gitdir}
git     X      u    17r  DIR  1,19   1344     3    {repo_dir}/.git/worktrees
git     X      u    18r  DIR  1,19   768      4    {repo_dir}/.git
git     X      u    31u  unix 0x123  0t0           fsmonitor--daemon.ipc
"""

    def _main_worktree_lsof_absolute_ipc(self, repo_dir: Path) -> str:
        return f"""\
COMMAND PID    USER FD   TYPE DEVICE SIZE/OFF NODE NAME
git     X      u    cwd  DIR  1,19   5376     1    {os.path.expanduser("~")}
git     X      u    4r   DIR  1,19   1312     2    {repo_dir}
git     X      u    11r  DIR  1,19   5376     3    {os.path.expanduser("~")}
git     X      u    16u  unix 0x123  0t0           {repo_dir}/.git/fsmonitor--daemon.ipc
"""

    def _main_worktree_lsof_bare_ipc(self, repo_dir: Path) -> str:
        return f"""\
COMMAND PID    USER FD   TYPE DEVICE SIZE/OFF NODE NAME
git     X      u    cwd  DIR  1,19   5376     1    {os.path.expanduser("~")}
git     X      u    4r   DIR  1,19   1312     2    {repo_dir}
git     X      u    5r   DIR  1,19   1408     3    {repo_dir.parent}
git     X      u    11r  DIR  1,19   5376     4    {os.path.expanduser("~")}
git     X      u    13r  DIR  1,19   192      5    /Users
git     X      u    14r  DIR  1,19   704      6    /System/Volumes/Data
git     X      u    16u  unix 0x123  0t0           fsmonitor--daemon.ipc
"""

    def test_live_linked_worktree_is_reported_and_not_killed(self) -> None:
        with tempfile.TemporaryDirectory() as repo_str:
            repo_dir = Path(repo_str)
            (repo_dir / ".git" / "worktrees" / "active").mkdir(parents=True)
            completed, kill_log = self.run_script(
                "--apply",
                fake_lsof_outputs={"100": self._linked_worktree_lsof(repo_dir, "active")},
                fake_pgrep_pids=["100"],
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn(f"pid=100", completed.stdout)
            self.assertIn("live=1 orphan=0", completed.stdout)
            self.assertEqual(
                kill_log,
                "",
                "live daemons must not be killed even with --apply",
            )

    def test_orphan_linked_worktree_is_detected_and_attempted_killed(self) -> None:
        # Tests behavior up to the point of attempting `kill` -- we don't try
        # to intercept the builtin kill, but the script's "killed: ..." or
        # "failed: ..." marker proves the apply path executed for this PID.
        with tempfile.TemporaryDirectory() as repo_str:
            repo_dir = Path(repo_str)
            # NOTE: gitdir directory does NOT exist - that's the orphan signal.
            completed, _ = self.run_script(
                "--apply",
                fake_lsof_outputs={"200": self._linked_worktree_lsof(repo_dir, "gone")},
                fake_pgrep_pids=["200"],
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("ORPHAN", completed.stdout)
            self.assertIn("live=0 orphan=1", completed.stdout)
            self.assertIn("Sending SIGTERM to 1 orphan", completed.stdout)
            # PID 200 doesn't actually exist, so the kill (builtin) fails --
            # but the failure marker proves we attempted it under --apply.
            self.assertRegex(completed.stdout, r"(killed|failed):.*pid=200")

    def test_dry_run_does_not_kill(self) -> None:
        with tempfile.TemporaryDirectory() as repo_str:
            repo_dir = Path(repo_str)
            completed, kill_log = self.run_script(
                fake_lsof_outputs={"300": self._linked_worktree_lsof(repo_dir, "gone")},
                fake_pgrep_pids=["300"],
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("ORPHAN", completed.stdout)
            self.assertIn("Dry-run", completed.stdout)
            self.assertEqual(
                kill_log,
                "",
                "dry-run must never send a signal",
            )

    def test_main_worktree_with_absolute_ipc_is_detected_live(self) -> None:
        with tempfile.TemporaryDirectory() as repo_str:
            repo_dir = Path(repo_str)
            (repo_dir / ".git").mkdir()
            completed, _ = self.run_script(
                fake_lsof_outputs={"400": self._main_worktree_lsof_absolute_ipc(repo_dir)},
                fake_pgrep_pids=["400"],
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("live=1", completed.stdout)
            self.assertIn(f"pid=400", completed.stdout)
            self.assertIn(f"gitdir={repo_dir}/.git", completed.stdout)

    def test_main_worktree_with_bare_ipc_falls_back_to_worktree_root(self) -> None:
        # When lsof reports the ipc socket as just `fsmonitor--daemon.ipc`
        # (no absolute path), the deepest non-system DIR fd is the worktree;
        # gitdir = `<worktree>/.git`.
        with tempfile.TemporaryDirectory() as parent_str:
            parent_dir = Path(parent_str)
            repo_dir = parent_dir / "my-repo"
            repo_dir.mkdir()
            (repo_dir / ".git").mkdir()
            completed, _ = self.run_script(
                fake_lsof_outputs={"500": self._main_worktree_lsof_bare_ipc(repo_dir)},
                fake_pgrep_pids=["500"],
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("live=1", completed.stdout)
            self.assertIn(f"gitdir={repo_dir}/.git", completed.stdout)

    def test_orphans_only_suppresses_live_lines(self) -> None:
        with tempfile.TemporaryDirectory() as repo_str:
            repo_dir = Path(repo_str)
            (repo_dir / ".git" / "worktrees" / "active").mkdir(parents=True)
            completed, _ = self.run_script(
                "--orphans-only",
                fake_lsof_outputs={
                    "600": self._linked_worktree_lsof(repo_dir, "active"),
                    "601": self._linked_worktree_lsof(repo_dir, "gone"),
                },
                fake_pgrep_pids=["600", "601"],
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertNotIn("pid=600", completed.stdout)
            self.assertIn("pid=601", completed.stdout)
            self.assertIn("live=1 orphan=1", completed.stdout)

    def test_custom_signal_is_propagated_in_message(self) -> None:
        with tempfile.TemporaryDirectory() as repo_str:
            repo_dir = Path(repo_str)
            completed, _ = self.run_script(
                "--apply",
                "--signal",
                "KILL",
                fake_lsof_outputs={"700": self._linked_worktree_lsof(repo_dir, "gone")},
                fake_pgrep_pids=["700"],
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("Sending SIGKILL to 1 orphan", completed.stdout)

    def test_duplicate_daemons_marked_redundant_in_dry_run(self) -> None:
        # Two daemons for the same gitdir: pid 800 newer (etimes=10),
        # pid 801 older (etimes=900). 800 stays live, 801 becomes redundant.
        with tempfile.TemporaryDirectory() as repo_str:
            repo_dir = Path(repo_str)
            (repo_dir / ".git" / "worktrees" / "active").mkdir(parents=True)
            completed, kill_log = self.run_script(
                fake_lsof_outputs={
                    "800": self._linked_worktree_lsof(repo_dir, "active"),
                    "801": self._linked_worktree_lsof(repo_dir, "active"),
                },
                fake_pgrep_pids=["800", "801"],
                fake_ps_etimes={"800": 10, "801": 900},
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("REDUNDANT pid=801", completed.stdout)
            self.assertIn("keeping newer pid=800", completed.stdout)
            self.assertNotIn("REDUNDANT pid=800", completed.stdout)
            self.assertIn("live=1 orphan=0 redundant=1", completed.stdout)
            self.assertEqual(kill_log, "", "dry-run must not kill anything")

    def test_apply_kills_redundant_duplicates(self) -> None:
        with tempfile.TemporaryDirectory() as repo_str:
            repo_dir = Path(repo_str)
            (repo_dir / ".git" / "worktrees" / "active").mkdir(parents=True)
            completed, _ = self.run_script(
                "--apply",
                fake_lsof_outputs={
                    "900": self._linked_worktree_lsof(repo_dir, "active"),
                    "901": self._linked_worktree_lsof(repo_dir, "active"),
                },
                fake_pgrep_pids=["900", "901"],
                fake_ps_etimes={"900": 5, "901": 5000},
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("REDUNDANT pid=901", completed.stdout)
            self.assertIn("Sending SIGTERM to 0 orphan(s) and 1 redundant duplicate(s)",
                          completed.stdout)
            self.assertRegex(completed.stdout, r"(killed|failed):.*pid=901")
            self.assertNotIn("killed: pid=900", completed.stdout)
            self.assertNotIn("failed: pid=900", completed.stdout)

    def test_triple_duplicate_keeps_only_newest(self) -> None:
        # Three daemons for one gitdir. The lowest-etimes one is kept; the
        # other two become redundant.
        with tempfile.TemporaryDirectory() as repo_str:
            repo_dir = Path(repo_str)
            (repo_dir / ".git" / "worktrees" / "active").mkdir(parents=True)
            completed, _ = self.run_script(
                fake_lsof_outputs={
                    "1000": self._linked_worktree_lsof(repo_dir, "active"),
                    "1001": self._linked_worktree_lsof(repo_dir, "active"),
                    "1002": self._linked_worktree_lsof(repo_dir, "active"),
                },
                fake_pgrep_pids=["1000", "1001", "1002"],
                fake_ps_etimes={"1000": 800, "1001": 100, "1002": 500},
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("REDUNDANT pid=1000", completed.stdout)
            self.assertIn("REDUNDANT pid=1002", completed.stdout)
            self.assertIn("keeping newer pid=1001", completed.stdout)
            self.assertIn("live=1 orphan=0 redundant=2", completed.stdout)

    def test_redundant_and_orphan_classified_independently(self) -> None:
        # PID 1100/1101 share an active gitdir (1100 newer -> live, 1101
        # redundant). PID 1102 has a deleted gitdir (orphan). Live/orphan/
        # redundant counts should all be 1.
        with tempfile.TemporaryDirectory() as repo_str:
            repo_dir = Path(repo_str)
            (repo_dir / ".git" / "worktrees" / "active").mkdir(parents=True)
            completed, _ = self.run_script(
                fake_lsof_outputs={
                    "1100": self._linked_worktree_lsof(repo_dir, "active"),
                    "1101": self._linked_worktree_lsof(repo_dir, "active"),
                    "1102": self._linked_worktree_lsof(repo_dir, "gone"),
                },
                fake_pgrep_pids=["1100", "1101", "1102"],
                fake_ps_etimes={"1100": 50, "1101": 5000, "1102": 12345},
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("live=1 orphan=1 redundant=1", completed.stdout)

    def test_no_duplicates_no_redundant_classification(self) -> None:
        # Sanity: when every daemon has a unique gitdir, no daemon is
        # redundant even with fake_ps_etimes populated.
        with tempfile.TemporaryDirectory() as repo_str:
            repo_dir = Path(repo_str)
            (repo_dir / ".git" / "worktrees" / "active").mkdir(parents=True)
            (repo_dir / ".git" / "worktrees" / "other").mkdir(parents=True)
            completed, _ = self.run_script(
                fake_lsof_outputs={
                    "1200": self._linked_worktree_lsof(repo_dir, "active"),
                    "1201": self._linked_worktree_lsof(repo_dir, "other"),
                },
                fake_pgrep_pids=["1200", "1201"],
                fake_ps_etimes={"1200": 10, "1201": 20},
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("live=2 orphan=0 redundant=0", completed.stdout)
            self.assertNotIn("REDUNDANT", completed.stdout)


if __name__ == "__main__":
    unittest.main()
