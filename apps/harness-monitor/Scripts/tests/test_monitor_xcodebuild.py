from __future__ import annotations

import os
import signal
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parents[2]
CHECKOUT_ROOT = APP_ROOT.parents[1]
SCRIPT_PATH = APP_ROOT / "Scripts" / "monitor-xcodebuild.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class MonitorXcodebuildTests(unittest.TestCase):
    def run_script(
        self,
        *args: str,
        extra_env: dict[str, str] | None = None,
        inject_derived_data_path: bool = True,
        include_tuist: bool = True,
        cwd: Path | None = None,
        preexisting_lock_pid: int | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], str, Path]:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            fake_bin = temp_root / "bin"
            fake_bin.mkdir()
            derived_data_path = temp_root / "derived"
            tool_log = temp_root / "tool.log"

            if preexisting_lock_pid is not None:
                lock_dir = derived_data_path / ".harness-monitor-xcodebuild.lock"
                lock_dir.mkdir(parents=True)
                (lock_dir / "owner.env").write_text(
                    f"pid={preexisting_lock_pid}\nstarted_at=2026-01-01T00:00:00Z\n"
                )

            write_executable(
                fake_bin / "xcodebuild",
                f"""#!/bin/bash
set -euo pipefail
printf 'XCODEBUILD=%s\\n' "$*" >> "{tool_log}"
if [[ "${{FAKE_XCODEBUILD_FAIL:-0}}" == "1" ]]; then
  printf '/tmp/Fake.swift:1:1: error: synthetic failure\\n'
  exit 65
fi
""",
            )
            if include_tuist:
                write_executable(
                    fake_bin / "tuist",
                    f"""#!/bin/bash
set -euo pipefail
printf 'TUIST_PWD=%s\\nTUIST=%s\\n' "$PWD" "$*" >> "{tool_log}"
if [[ "${{1:-}}" != "xcodebuild" ]]; then
  echo "unexpected tuist subcommand: $*" >&2
  exit 1
fi
shift
"{fake_bin / "xcodebuild"}" "$@"
""",
                )

            env = os.environ.copy()
            for key in (
                "HARNESS_MONITOR_RUNTIME_PROFILE",
                "HARNESS_MONITOR_BUILD_LANE",
                "XCODEBUILD_DERIVED_DATA_PATH",
            ):
                env.pop(key, None)
            env.update(
                {
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "BASH_ENV": "/dev/null",
                    "HARNESS_SKIP_STALE_CHECK": "1",
                    "XCODEBUILD_BIN": str(fake_bin / "xcodebuild"),
                    "TMPDIR": str(temp_root),
                    "HARNESS_MONITOR_GLOBAL_SEMAPHORE_DIR": str(
                        temp_root / "global-semaphore"
                    ),
                }
            )
            env.update(extra_env or {})

            command = ["bash", str(SCRIPT_PATH)]
            if inject_derived_data_path:
                command.extend(["-derivedDataPath", str(derived_data_path)])
            command.extend(args)
            completed = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                env=env,
                cwd=cwd,
            )
            log = tool_log.read_text() if tool_log.exists() else ""
            return completed, log, derived_data_path

    def test_uses_tuist_xcodebuild_and_releases_lock(self) -> None:
        completed, log, derived_data_path = self.run_script("-scheme", "HarnessMonitor", "build")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(f"TUIST_PWD={APP_ROOT}", log)
        self.assertIn("TUIST=xcodebuild", log)
        self.assertIn(f"XCODEBUILD=-derivedDataPath {derived_data_path}", log)
        self.assertFalse((derived_data_path / ".harness-monitor-xcodebuild.lock").exists())

    def test_named_build_lane_injects_lane_derived_data_path(self) -> None:
        completed, log, _ = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "build",
            inject_derived_data_path=False,
            extra_env={"HARNESS_MONITOR_BUILD_LANE": "Agent 42"},
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("xcode-derived-lanes/agent-42", log)

    def test_debug_lanes_disable_user_script_sandboxing_without_project_warning(self) -> None:
        completed, log, _ = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "-configuration",
            "Debug",
            "build",
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("ENABLE_USER_SCRIPT_SANDBOXING=NO", log)

    def test_release_lanes_keep_user_script_sandboxing_project_default(self) -> None:
        completed, log, _ = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "-configuration",
            "Release",
            "build",
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertNotIn("ENABLE_USER_SCRIPT_SANDBOXING=NO", log)

    def test_explicit_script_sandboxing_setting_is_not_overridden(self) -> None:
        completed, log, _ = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "build",
            "ENABLE_USER_SCRIPT_SANDBOXING=YES",
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertNotIn("ENABLE_USER_SCRIPT_SANDBOXING=NO", log)
        self.assertIn("ENABLE_USER_SCRIPT_SANDBOXING=YES", log)

    def test_legacy_profile_env_is_rejected(self) -> None:
        completed, log, _ = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "build",
            extra_env={"HARNESS_MONITOR_RUNTIME_PROFILE": "old"},
        )

        self.assertNotEqual(completed.returncode, 0)
        self.assertEqual(log, "")
        self.assertIn("HARNESS_MONITOR_RUNTIME_PROFILE is no longer supported", completed.stderr)

    def test_reports_lock_owner_when_lane_is_busy(self) -> None:
        sleeper = subprocess.Popen(["/bin/sleep", "10"])
        try:
            completed, log, _ = self.run_script(
                "-scheme",
                "HarnessMonitor",
                "build",
                extra_env={"XCODEBUILD_LOCK_WAIT_TIMEOUT_SECONDS": "1"},
                preexisting_lock_pid=sleeper.pid,
            )
        finally:
            sleeper.terminate()
            sleeper.wait(timeout=5)

        self.assertEqual(completed.returncode, 73)
        self.assertEqual(log, "")
        self.assertIn("Harness Monitor xcodebuild lane is busy", completed.stderr)
        self.assertIn(f"pid={sleeper.pid}", completed.stderr)

    def _spawn_long_running_wrapper(
        self,
        temp_root: Path,
        marker_path: Path,
        protect: str,
    ) -> tuple[subprocess.Popen[str], Path]:
        fake_bin = temp_root / "bin"
        fake_bin.mkdir()
        derived_data_path = temp_root / "derived"
        derived_data_path.mkdir(parents=True)
        write_executable(
            fake_bin / "xcodebuild",
            f"""#!/bin/bash
printf 'started\\n' > "{marker_path}"
sleep 30
""",
        )
        write_executable(
            fake_bin / "tuist",
            f"""#!/bin/bash
shift
exec "{fake_bin / "xcodebuild"}" "$@"
""",
        )
        env = os.environ.copy()
        for key in (
            "HARNESS_MONITOR_RUNTIME_PROFILE",
            "HARNESS_MONITOR_BUILD_LANE",
            "XCODEBUILD_DERIVED_DATA_PATH",
        ):
            env.pop(key, None)
        env.update(
            {
                "PATH": f"{fake_bin}:/usr/bin:/bin",
                "BASH_ENV": "/dev/null",
                "HARNESS_SKIP_STALE_CHECK": "1",
                "XCODEBUILD_BIN": str(fake_bin / "xcodebuild"),
                "TMPDIR": str(temp_root),
                "HARNESS_MONITOR_BUILD_PROTECT_INFLIGHT": protect,
                "HARNESS_MONITOR_GLOBAL_SEMAPHORE_DIR": str(
                    temp_root / "global-semaphore"
                ),
            }
        )
        proc = subprocess.Popen(
            [
                "bash",
                str(SCRIPT_PATH),
                "-derivedDataPath",
                str(derived_data_path),
                "-scheme",
                "HarnessMonitor",
                "build",
            ],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if marker_path.exists():
                return proc, derived_data_path
            if proc.poll() is not None:
                self.fail(
                    f"wrapper exited before marker appeared, rc={proc.returncode}"
                )
            time.sleep(0.05)
        proc.kill()
        proc.wait(timeout=5)
        self.fail("fake xcodebuild never wrote start marker")

    def test_protect_inflight_ignores_sigterm_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            marker = temp_root / "started"
            proc, _ = self._spawn_long_running_wrapper(temp_root, marker, "1")
            try:
                proc.send_signal(signal.SIGTERM)
                proc.send_signal(signal.SIGHUP)
                time.sleep(0.5)
                self.assertIsNone(
                    proc.poll(),
                    "wrapper must survive SIGTERM and SIGHUP when protection is on",
                )
            finally:
                proc.kill()
                proc.wait(timeout=5)

    def test_protect_inflight_off_honors_sigterm(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            marker = temp_root / "started"
            proc, _ = self._spawn_long_running_wrapper(temp_root, marker, "0")
            try:
                proc.send_signal(signal.SIGTERM)
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
                    self.fail(
                        "wrapper should exit on SIGTERM when protection is disabled"
                    )
                self.assertEqual(proc.returncode, 143)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=5)

    def test_failure_persists_report(self) -> None:
        with tempfile.TemporaryDirectory() as report_dir:
            completed, _, _ = self.run_script(
                "-scheme",
                "HarnessMonitor",
                "build",
                extra_env={
                    "FAKE_XCODEBUILD_FAIL": "1",
                    "HARNESS_MONITOR_FAILURE_REPORT_DIR": report_dir,
                },
            )

            self.assertEqual(completed.returncode, 65)
            combined_output = completed.stdout + completed.stderr
            self.assertIn("xcodebuild-wrapper failure report:", combined_output)
            report_path = combined_output.strip().split(
                "xcodebuild-wrapper failure report: ", 1
            )[1].splitlines()[0]
            self.assertTrue(Path(report_path).exists())
            self.assertIn("synthetic failure", Path(report_path).read_text())

    def test_injects_shared_compilation_cache_path_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as fake_home:
            completed, log, _ = self.run_script(
                "-scheme",
                "HarnessMonitor",
                "build",
                extra_env={"HOME": fake_home},
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            expected = (
                f"COMPILATION_CACHE_CAS_PATH={fake_home}"
                "/Library/Developer/Xcode/DerivedData/CompilationCache.noindex/builtin"
            )
            self.assertIn(expected, log)
            self.assertTrue(
                (
                    Path(fake_home)
                    / "Library/Developer/Xcode/DerivedData/CompilationCache.noindex/builtin"
                ).is_dir(),
                "wrapper should create the shared CAS directory if missing",
            )

    def test_shared_compilation_cache_path_opt_out(self) -> None:
        with tempfile.TemporaryDirectory() as fake_home:
            completed, log, _ = self.run_script(
                "-scheme",
                "HarnessMonitor",
                "build",
                extra_env={
                    "HOME": fake_home,
                    "HARNESS_MONITOR_SHARED_COMPILATION_CAS": "0",
                },
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertNotIn("COMPILATION_CACHE_CAS_PATH=", log)

    def test_explicit_compilation_cache_path_is_not_overridden(self) -> None:
        with tempfile.TemporaryDirectory() as fake_home:
            completed, log, _ = self.run_script(
                "-scheme",
                "HarnessMonitor",
                "build",
                "COMPILATION_CACHE_CAS_PATH=/tmp/explicit-cas",
                extra_env={"HOME": fake_home},
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("COMPILATION_CACHE_CAS_PATH=/tmp/explicit-cas", log)
            self.assertNotIn(
                f"COMPILATION_CACHE_CAS_PATH={fake_home}",
                log,
                "wrapper must not stamp the shared path on top of an explicit override",
            )

    def test_global_semaphore_slot_released_on_clean_exit(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            semaphore_dir = Path(tmp_dir) / "sema"
            completed, log, _ = self.run_script(
                "-scheme",
                "HarnessMonitor",
                "build",
                extra_env={"HARNESS_MONITOR_GLOBAL_SEMAPHORE_DIR": str(semaphore_dir)},
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("XCODEBUILD=", log)
            self.assertTrue(
                semaphore_dir.exists(),
                "semaphore dir should be created on first acquire",
            )
            leftover_slots = [
                child for child in semaphore_dir.iterdir() if child.is_dir()
            ]
            self.assertEqual(
                leftover_slots,
                [],
                "semaphore slot must be released after a clean build",
            )

    def _plant_live_slot(
        self,
        semaphore_dir: Path,
        slot_name: str,
        pid: int,
        heartbeat_age_seconds: int = 0,
    ) -> Path:
        slot = semaphore_dir / slot_name
        slot.mkdir(parents=True)
        (slot / "owner.env").write_text(
            f"pid={pid}\n"
            "started_at=2026-01-01T00:00:00Z\n"
            "derived_data_path=/tmp/other-lane\n"
        )
        heartbeat = slot / "heartbeat"
        heartbeat.touch()
        if heartbeat_age_seconds > 0:
            now = time.time()
            old = now - heartbeat_age_seconds
            os.utime(heartbeat, (old, old))
        return slot

    def test_global_semaphore_blocks_when_fresh_holder_is_alive(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            semaphore_dir = Path(tmp_dir) / "sema"
            sleeper = subprocess.Popen(["/bin/sleep", "10"])
            try:
                self._plant_live_slot(semaphore_dir, "slot-1", sleeper.pid)
                completed, log, _ = self.run_script(
                    "-scheme",
                    "HarnessMonitor",
                    "build",
                    extra_env={
                        "HARNESS_MONITOR_GLOBAL_SEMAPHORE_DIR": str(semaphore_dir),
                        "XCODEBUILD_LOCK_WAIT_TIMEOUT_SECONDS": "1",
                    },
                )
            finally:
                sleeper.terminate()
                sleeper.wait(timeout=5)

            self.assertEqual(completed.returncode, 73)
            self.assertEqual(log, "")
            self.assertIn("xcodebuild concurrency slots are busy", completed.stderr)
            self.assertIn("heartbeat=", completed.stderr)
            self.assertIn(
                "CANNOT be raised by env var",
                completed.stderr,
                "error must explain bypass is locked off",
            )

    def test_global_semaphore_reaps_slot_with_stale_heartbeat(self) -> None:
        # Holder process is alive but its heartbeat hasn't been refreshed in
        # over the staleness window -- reaper treats it as orphan.
        with tempfile.TemporaryDirectory() as tmp_dir:
            semaphore_dir = Path(tmp_dir) / "sema"
            sleeper = subprocess.Popen(["/bin/sleep", "10"])
            try:
                self._plant_live_slot(
                    semaphore_dir, "slot-1", sleeper.pid, heartbeat_age_seconds=600
                )
                completed, log, _ = self.run_script(
                    "-scheme",
                    "HarnessMonitor",
                    "build",
                    extra_env={"HARNESS_MONITOR_GLOBAL_SEMAPHORE_DIR": str(semaphore_dir)},
                )
            finally:
                sleeper.terminate()
                sleeper.wait(timeout=5)

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("XCODEBUILD=", log)

    def test_global_semaphore_reaps_dead_pid_owner(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            semaphore_dir = Path(tmp_dir) / "sema"
            slot_dir = semaphore_dir / "slot-1"
            slot_dir.mkdir(parents=True)
            (slot_dir / "owner.env").write_text(
                "pid=2147483646\n"
                "started_at=2026-01-01T00:00:00Z\n"
                "derived_data_path=/tmp/orphan\n"
            )
            (slot_dir / "heartbeat").touch()
            completed, log, _ = self.run_script(
                "-scheme",
                "HarnessMonitor",
                "build",
                extra_env={"HARNESS_MONITOR_GLOBAL_SEMAPHORE_DIR": str(semaphore_dir)},
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("XCODEBUILD=", log)

    def test_global_semaphore_heartbeat_file_is_written_on_acquire(self) -> None:
        # Use the long-running wrapper helper to keep the slot held while we
        # inspect it.
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            marker = temp_root / "started"
            semaphore_dir = temp_root / "sema"
            proc, _ = self._spawn_long_running_wrapper(temp_root, marker, "0")
            try:
                # The helper wires its own temp semaphore at temp_root/global-semaphore
                semaphore_dir = temp_root / "global-semaphore"
                deadline = time.monotonic() + 5
                slot_path: Path | None = None
                while time.monotonic() < deadline:
                    if semaphore_dir.exists():
                        slots = [p for p in semaphore_dir.iterdir() if p.is_dir()]
                        if slots:
                            slot_path = slots[0]
                            break
                    time.sleep(0.05)
                self.assertIsNotNone(
                    slot_path, "slot directory never appeared under semaphore"
                )
                heartbeat = slot_path / "heartbeat"
                deadline2 = time.monotonic() + 5
                while time.monotonic() < deadline2 and not heartbeat.exists():
                    time.sleep(0.05)
                self.assertTrue(
                    heartbeat.exists(),
                    "heartbeat file must be created when slot is acquired",
                )
            finally:
                proc.send_signal(signal.SIGINT)
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)

    def test_legacy_concurrency_env_is_rejected_with_warning(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            semaphore_dir = Path(tmp_dir) / "sema"
            completed, log, _ = self.run_script(
                "-scheme",
                "HarnessMonitor",
                "build",
                extra_env={
                    "HARNESS_MONITOR_GLOBAL_SEMAPHORE_DIR": str(semaphore_dir),
                    "HARNESS_MONITOR_BUILD_GLOBAL_CONCURRENCY": "8",
                },
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("XCODEBUILD=", log)
            self.assertIn(
                "HARNESS_MONITOR_BUILD_GLOBAL_CONCURRENCY",
                completed.stderr,
                "rejection warning must surface to stderr",
            )
            self.assertIn("is ignored", completed.stderr)

    def _run_and_capture_env(
        self,
        env_var: str,
        *args: str,
        extra_env: dict[str, str] | None = None,
        inject_derived_data_path: bool = True,
    ) -> tuple[subprocess.CompletedProcess[str], str | None]:
        """Run the wrapper with a fake xcodebuild that echoes the named env var
        into the tool log, then return the value the wrapper exported (or None
        if unset)."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            fake_bin = temp_root / "bin"
            fake_bin.mkdir()
            derived_data_path = temp_root / "derived"
            tool_log = temp_root / "tool.log"

            write_executable(
                fake_bin / "xcodebuild",
                f"""#!/bin/bash
printf '{env_var}=%s\\n' "${{{env_var}:-__UNSET__}}" >> "{tool_log}"
""",
            )
            write_executable(
                fake_bin / "tuist",
                f"""#!/bin/bash
shift
exec "{fake_bin / "xcodebuild"}" "$@"
""",
            )

            env = os.environ.copy()
            for key in (
                "HARNESS_MONITOR_RUNTIME_PROFILE",
                "HARNESS_MONITOR_BUILD_LANE",
                "XCODEBUILD_DERIVED_DATA_PATH",
                env_var,
            ):
                env.pop(key, None)
            env.update(
                {
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "BASH_ENV": "/dev/null",
                    "HARNESS_SKIP_STALE_CHECK": "1",
                    "XCODEBUILD_BIN": str(fake_bin / "xcodebuild"),
                    "TMPDIR": str(temp_root),
                    "HARNESS_MONITOR_GLOBAL_SEMAPHORE_DIR": str(
                        temp_root / "global-semaphore"
                    ),
                }
            )
            env.update(extra_env or {})

            command = ["bash", str(SCRIPT_PATH)]
            if inject_derived_data_path:
                command.extend(["-derivedDataPath", str(derived_data_path)])
            command.extend(args)
            completed = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            log = tool_log.read_text() if tool_log.exists() else ""
            value: str | None = None
            for line in log.splitlines():
                if line.startswith(f"{env_var}="):
                    raw = line.split("=", 1)[1]
                    value = None if raw == "__UNSET__" else raw
                    break
            return completed, value

    def test_named_lane_redirects_daemon_cargo_target_dir(self) -> None:
        completed, value = self._run_and_capture_env(
            "HARNESS_MONITOR_DAEMON_CARGO_TARGET_DIR",
            "-scheme",
            "HarnessMonitor",
            "build",
            inject_derived_data_path=False,
            extra_env={"HARNESS_MONITOR_BUILD_LANE": "Agent 42"},
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIsNotNone(value, "named lane must export the override env")
        assert value is not None  # narrowing for mypy
        self.assertIn("xcode-derived-lanes/agent-42/cargo-target", value)

    def test_default_lane_does_not_redirect_daemon_cargo_target_dir(self) -> None:
        # No HARNESS_MONITOR_BUILD_LANE; derived data resolves to xcode-derived/
        # (not xcode-derived-lanes/<name>/), so the override env must stay unset
        # so the daemon cargo cache stays at .cache/harness-monitor-xcode-daemon.
        completed, value = self._run_and_capture_env(
            "HARNESS_MONITOR_DAEMON_CARGO_TARGET_DIR",
            "-scheme",
            "HarnessMonitor",
            "build",
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIsNone(
            value, "default lane must not redirect the daemon cargo target"
        )

    def test_explicit_daemon_cargo_target_dir_is_not_overridden(self) -> None:
        completed, value = self._run_and_capture_env(
            "HARNESS_MONITOR_DAEMON_CARGO_TARGET_DIR",
            "-scheme",
            "HarnessMonitor",
            "build",
            inject_derived_data_path=False,
            extra_env={
                "HARNESS_MONITOR_BUILD_LANE": "agent-foo",
                "HARNESS_MONITOR_DAEMON_CARGO_TARGET_DIR": "/tmp/explicit",
            },
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(value, "/tmp/explicit")

    def test_existing_cargo_target_dir_blocks_lane_redirect(self) -> None:
        # If the caller explicitly set CARGO_TARGET_DIR, respect that and do
        # not stomp on it with the lane-specific override.
        completed, value = self._run_and_capture_env(
            "HARNESS_MONITOR_DAEMON_CARGO_TARGET_DIR",
            "-scheme",
            "HarnessMonitor",
            "build",
            inject_derived_data_path=False,
            extra_env={
                "HARNESS_MONITOR_BUILD_LANE": "agent-foo",
                "CARGO_TARGET_DIR": "/tmp/cargo-target",
            },
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIsNone(value)

    def test_per_lane_daemon_cache_opt_out(self) -> None:
        completed, value = self._run_and_capture_env(
            "HARNESS_MONITOR_DAEMON_CARGO_TARGET_DIR",
            "-scheme",
            "HarnessMonitor",
            "build",
            inject_derived_data_path=False,
            extra_env={
                "HARNESS_MONITOR_BUILD_LANE": "agent-foo",
                "HARNESS_MONITOR_PER_LANE_DAEMON_CACHE": "0",
            },
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIsNone(value, "opt-out must keep the override unset")

    def test_test_override_can_raise_cap_to_two(self) -> None:
        # Two pre-existing live holders block any wrapper when cap is 1 but
        # only one when cap is 2.
        with tempfile.TemporaryDirectory() as tmp_dir:
            semaphore_dir = Path(tmp_dir) / "sema"
            sleeper = subprocess.Popen(["/bin/sleep", "10"])
            try:
                self._plant_live_slot(semaphore_dir, "slot-1", sleeper.pid)
                completed, log, _ = self.run_script(
                    "-scheme",
                    "HarnessMonitor",
                    "build",
                    extra_env={
                        "HARNESS_MONITOR_GLOBAL_SEMAPHORE_DIR": str(semaphore_dir),
                        "_HARNESS_TEST_GLOBAL_CONCURRENCY_OVERRIDE": "2",
                    },
                )
            finally:
                sleeper.terminate()
                sleeper.wait(timeout=5)

            # With cap raised to 2 via the test-only override, the wrapper
            # finds slot-2 free and proceeds.
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("XCODEBUILD=", log)


if __name__ == "__main__":
    unittest.main()
