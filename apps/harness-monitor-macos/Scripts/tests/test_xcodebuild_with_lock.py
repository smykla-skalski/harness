from __future__ import annotations

import gzip
import json
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
COMMON_REPO_ROOT = Path(
    subprocess.check_output(
        [
            "git",
            "-C",
            str(CHECKOUT_ROOT),
            "rev-parse",
            "--path-format=absolute",
            "--git-common-dir",
        ],
        text=True,
    ).strip()
).parent
SCRIPT_PATH = APP_ROOT / "Scripts" / "xcodebuild-with-lock.sh"
RTK_SHELL_PATH = APP_ROOT / "Scripts" / "lib" / "rtk-shell.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class XcodebuildWithLockTests(unittest.TestCase):
    def wait_for_path(self, path: Path, *, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if path.exists():
                return
            time.sleep(0.05)
        self.fail(f"timed out waiting for {path}")

    def run_script(
        self,
        *args: str,
        extra_env: dict[str, str] | None = None,
        preexisting_lock_pid: int | None = None,
        preexisting_empty_lock: bool = False,
        cwd: Path | None = None,
        inject_derived_data_path: bool = True,
        include_tuist: bool = True,
        include_xcbeautify: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], str]:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            fake_bin = temp_root / "bin"
            fake_bin.mkdir()
            derived_data_path = temp_root / "derived"
            tool_log = temp_root / "tool.log"

            if preexisting_lock_pid is not None:
                lock_owner_dir = derived_data_path / ".xcodebuild.lock" / "owner"
                lock_owner_dir.mkdir(parents=True, exist_ok=True)
                now_epoch = int(time.time())
                (lock_owner_dir / "heartbeat").write_text(f"{now_epoch}\n")
                (lock_owner_dir / "lease.env").write_text(
                    "\n".join(
                        [
                            "LOCK_PROTOCOL_VERSION=1",
                            f"LOCK_RESOURCE=xcodebuild:{derived_data_path}",
                            "LOCK_ROLE=owner",
                            f"LOCK_OWNER_ID=test-owner-{preexisting_lock_pid}",
                            f"LOCK_AGENT_ID=pid:{preexisting_lock_pid}@test-host",
                            f"LOCK_PID={preexisting_lock_pid}",
                            "LOCK_HOSTNAME=test-host",
                            f"LOCK_REPO_ROOT={temp_root}",
                            "LOCK_COMMAND=/bin/sleep 10",
                            f"LOCK_ACQUIRED_AT_EPOCH={now_epoch}",
                            "LOCK_HEARTBEAT_EVERY_SEC=30",
                            "LOCK_LEASE_TIMEOUT_SEC=90",
                            f"LOCK_LAST_HEARTBEAT_EPOCH={now_epoch}",
                            f"LOCK_NEXT_HEARTBEAT_DUE_EPOCH={now_epoch + 30}",
                            "LOCK_STATE=holding",
                            "",
                        ]
                    )
                )
            elif preexisting_empty_lock:
                (derived_data_path / ".xcodebuild.lock").mkdir(parents=True)

            write_executable(
                fake_bin / "rtk",
                f"""#!/bin/bash
set -euo pipefail
printf 'RTK=%s\\n' "$*" >> "{tool_log}"
""",
            )
            write_executable(
                fake_bin / "xcodebuild",
                f"""#!/bin/bash
set -euo pipefail
printf 'XCODEBUILD=%s\\n' "$*" >> "{tool_log}"
if [[ "${{FAKE_XCODEBUILD_FAIL_WITH_DIAGNOSTICS:-}}" == "1" ]]; then
  count="${{FAKE_XCODEBUILD_DIAGNOSTIC_COUNT:-1}}"
  for ((i = 1; i <= count; i += 1)); do
    printf '/tmp/FakeSource.swift:%s:3: error: synthetic failure %s\\n' "$i" "$i"
    printf 'let failure_%s = boom\\n' "$i"
    printf '  ^~~~\\n'
  done
  exit 65
fi
if [[ "${{FAKE_XCODEBUILD_EMIT_NOISE:-}}" == "1" ]]; then
  printf '%s\\n' \\
    "Loading and constructing the graph" \\
    "note: Local cache found for key: llvmcas://abc (in target 'HarnessMonitorKitTests')" \\
    "note: Using CAS output object: llvmcas://def (in target 'HarnessMonitorKitTests')" \\
    "note: Replay cache hit (in target 'HarnessMonitorKitTests')" \\
    "Test run started." \\
    "Suite \\"Important suite\\" started" \\
    "    ✔ \\"important test\\" (0.001 seconds)" \\
    "Test Execute Succeeded"
fi
""",
            )
            if include_xcbeautify:
                write_executable(
                    fake_bin / "xcbeautify",
                    f"""#!/bin/bash
set -euo pipefail
printf 'XCBEAUTIFY=%s\\n' "$*" >> "{tool_log}"
if [[ "${{FAKE_XCBEAUTIFY_HIDE_DIAGNOSTICS:-}}" == "1" ]]; then
  cat >/dev/null
  printf '%s\\n' "** BUILD FAILED **"
else
  cat
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
            env.update(
                {
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "BASH_ENV": "/dev/null",
                    "HARNESS_SKIP_STALE_CHECK": "1",
                    "RTK_BIN": str(fake_bin / "rtk"),
                    "XCODEBUILD_BIN": str(fake_bin / "xcodebuild"),
                    "TMPDIR": str(temp_root),
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
            return completed, log

    def test_termination_cleans_up_lock_and_child_xcodebuild(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            fake_bin = temp_root / "bin"
            fake_bin.mkdir()
            derived_data_path = temp_root / "derived"
            tool_log = temp_root / "tool.log"
            child_pid_path = temp_root / "child.pid"

            write_executable(
                fake_bin / "rtk",
                f"""#!/bin/bash
set -euo pipefail
printf 'RTK=%s\\n' "$*" >> "{tool_log}"
""",
            )
            write_executable(
                fake_bin / "xcodebuild",
                f"""#!/bin/bash
set -euo pipefail
printf '%s\\n' "$$" > "{child_pid_path}"
trap 'exit 0' TERM INT HUP
while true; do
  sleep 1
done
""",
            )
            write_executable(
                fake_bin / "tuist",
                f"""#!/bin/bash
set -euo pipefail
if [[ "${{1:-}}" != "xcodebuild" ]]; then
  echo "unexpected tuist subcommand: $*" >&2
  exit 1
fi
shift
"{fake_bin / "xcodebuild"}" "$@"
""",
            )

            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "BASH_ENV": "/dev/null",
                    "HARNESS_SKIP_STALE_CHECK": "1",
                    "RTK_BIN": str(fake_bin / "rtk"),
                    "XCODEBUILD_BIN": str(fake_bin / "xcodebuild"),
                    "TMPDIR": str(temp_root),
                    "HARNESS_MONITOR_DISABLE_XCBEAUTIFY": "1",
                }
            )

            command = [
                "bash",
                str(SCRIPT_PATH),
                "-derivedDataPath",
                str(derived_data_path),
                "-scheme",
                "HarnessMonitor",
                "build",
            ]
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
            )

            lock_owner_file = derived_data_path / ".xcodebuild.lock" / "owner" / "lease.env"
            self.wait_for_path(lock_owner_file)
            self.assertTrue(lock_owner_file.is_file(), "wrapper must publish shared lease owner metadata")
            self.wait_for_path(child_pid_path)

            child_pid = int(child_pid_path.read_text().strip())
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=10)

            self.assertEqual(process.returncode, 143, stdout + stderr)
            self.assertFalse(lock_owner_file.exists(), "wrapper must release shared lease owner metadata on termination")
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)

    def test_records_xcodebuild_child_as_mutator_when_tuist_stays_alive(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            fake_bin = temp_root / "bin"
            fake_bin.mkdir()
            derived_data_path = temp_root / "derived"
            child_pid_path = temp_root / "child.pid"
            tuist_pid_path = temp_root / "tuist.pid"

            write_executable(
                fake_bin / "xcodebuild",
                f"""#!/bin/bash
set -euo pipefail
printf '%s\\n' "$$" > "{child_pid_path}"
trap 'exit 0' TERM INT HUP
while true; do
  sleep 1
done
""",
            )
            write_executable(
                fake_bin / "tuist",
                f"""#!/bin/bash
set -euo pipefail
printf '%s\\n' "$$" > "{tuist_pid_path}"
if [[ "${{1:-}}" != "xcodebuild" ]]; then
  echo "unexpected tuist subcommand: $*" >&2
  exit 1
fi
shift
"{fake_bin / "xcodebuild"}" "$@" &
child_pid="$!"
wait "$child_pid"
""",
            )

            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "BASH_ENV": "/dev/null",
                    "HARNESS_SKIP_STALE_CHECK": "1",
                    "XCODEBUILD_BIN": str(fake_bin / "xcodebuild"),
                    "TMPDIR": str(temp_root),
                    "HARNESS_MONITOR_DISABLE_XCBEAUTIFY": "1",
                }
            )

            process = subprocess.Popen(
                [
                    "bash",
                    str(SCRIPT_PATH),
                    "-derivedDataPath",
                    str(derived_data_path),
                    "-scheme",
                    "HarnessMonitor",
                    "build",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
            )

            runtime_file = derived_data_path / ".xcodebuild.lock" / "owner" / "runtime.env"
            self.wait_for_path(runtime_file)
            self.wait_for_path(child_pid_path)
            self.wait_for_path(tuist_pid_path)

            child_pid = child_pid_path.read_text().strip()
            tuist_pid = tuist_pid_path.read_text().strip()
            runtime_text = runtime_file.read_text()

            self.assertIn(f"LOCK_MUTATOR_PID={child_pid}", runtime_text)
            self.assertNotIn(f"LOCK_MUTATOR_PID={tuist_pid}", runtime_text)

            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=10)

    def test_reports_lock_owner_while_waiting_for_shared_derived_data(self) -> None:
        sleeper = subprocess.Popen(["/bin/sleep", "10"])
        try:
            completed, log = self.run_script(
                "-scheme",
                "HarnessMonitor",
                "build",
                extra_env={
                    "XCODEBUILD_LOCK_LEASE_TIMEOUT_SECONDS": "1",
                    "XCODEBUILD_LOCK_WAIT_TIMEOUT_SECONDS": "1",
                    "XCODEBUILD_LOCK_POLL_SECONDS": "1",
                },
                preexisting_lock_pid=sleeper.pid,
            )
        finally:
            sleeper.terminate()
            sleeper.wait(timeout=5)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("Waiting for xcodebuild:", completed.stderr)
        self.assertIn("lease owner:", completed.stderr)
        self.assertIn(f"pid={sleeper.pid}", completed.stderr)
        self.assertIn("command=/bin/sleep 10", completed.stderr)
        self.assertIn("Timed out waiting for xcodebuild:", completed.stderr)
        self.assertEqual(log, "")

    def test_recovers_empty_lock_directory_without_waiting_for_timeout(self) -> None:
        completed, log = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "build",
            extra_env={
                "XCODEBUILD_LOCK_LEASE_TIMEOUT_SECONDS": "1",
                "XCODEBUILD_LOCK_POLL_SECONDS": "1",
            },
            preexisting_empty_lock=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("XCODEBUILD=-derivedDataPath", log)

    def test_surfaces_raw_compiler_diagnostics_when_xcbeautify_hides_them(self) -> None:
        completed, _ = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "build",
            extra_env={
                "FAKE_XCODEBUILD_FAIL_WITH_DIAGNOSTICS": "1",
                "FAKE_XCBEAUTIFY_HIDE_DIAGNOSTICS": "1",
            },
            include_xcbeautify=True,
        )

        self.assertNotEqual(completed.returncode, 0)
        combined_output = completed.stdout + completed.stderr
        self.assertIn(
            "swift-raw-diagnostics: extracted compiler diagnostics from raw xcodebuild output",
            combined_output,
        )
        self.assertIn(
            "/tmp/FakeSource.swift:1:3: error: synthetic failure 1",
            combined_output,
        )
        self.assertNotIn("swift-compile-context:", combined_output)

    def test_caps_raw_compiler_diagnostics_to_avoid_huge_failure_dumps(self) -> None:
        completed, _ = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "build",
            extra_env={
                "FAKE_XCODEBUILD_FAIL_WITH_DIAGNOSTICS": "1",
                "FAKE_XCODEBUILD_DIAGNOSTIC_COUNT": "20",
                "FAKE_XCBEAUTIFY_HIDE_DIAGNOSTICS": "1",
            },
            include_xcbeautify=True,
        )

        self.assertNotEqual(completed.returncode, 0)
        combined_output = completed.stdout + completed.stderr
        self.assertIn(
            "/tmp/FakeSource.swift:12:3: error: synthetic failure 12",
            combined_output,
        )
        self.assertNotIn(
            "/tmp/FakeSource.swift:13:3: error: synthetic failure 13",
            combined_output,
        )

    def test_raw_log_capture_also_works_when_xcbeautify_is_disabled(self) -> None:
        completed, _ = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "build",
            extra_env={
                "FAKE_XCODEBUILD_FAIL_WITH_DIAGNOSTICS": "1",
                "HARNESS_MONITOR_DISABLE_XCBEAUTIFY": "1",
            },
        )

        self.assertNotEqual(completed.returncode, 0)
        combined_output = completed.stdout + completed.stderr
        self.assertIn(
            "/tmp/FakeSource.swift:1:3: error: synthetic failure 1",
            combined_output,
        )

    def test_uses_tuist_xcodebuild_for_normal_build_invocations(self) -> None:
        completed, log = self.run_script("-scheme", "HarnessMonitor", "build")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn(f"TUIST_PWD={APP_ROOT}", log)
        self.assertIn("TUIST=xcodebuild", log)
        self.assertIn("XCODEBUILD=-derivedDataPath", log)
        self.assertIn("-scheme HarnessMonitor build", log)
        self.assertNotIn("RTK=", log)

    def test_injects_default_derived_data_path_when_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            fake_bin = temp_root / "bin"
            fake_bin.mkdir()
            derived_data_path = temp_root / "canonical-derived"
            tool_log = temp_root / "tool.log"

            write_executable(
                fake_bin / "xcodebuild",
                f"""#!/bin/bash
set -euo pipefail
printf 'XCODEBUILD=%s\\n' "$*" >> "{tool_log}"
""",
            )
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
            env.update(
                {
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "BASH_ENV": "/dev/null",
                    "XCODEBUILD_BIN": str(fake_bin / "xcodebuild"),
                    "XCODEBUILD_DERIVED_DATA_PATH": str(derived_data_path),
                    "TMPDIR": str(temp_root),
                }
            )

            completed = subprocess.run(
                [
                    "bash",
                    str(SCRIPT_PATH),
                    "-scheme",
                    "HarnessMonitor",
                    "build",
                ],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            log = tool_log.read_text() if tool_log.exists() else ""
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn(f"TUIST_PWD={APP_ROOT}", log)
            self.assertIn(f"XCODEBUILD=-derivedDataPath {derived_data_path}", log)
            self.assertIn("-scheme HarnessMonitor build", log)

    def test_normalizes_relative_env_derived_data_alias_when_flag_missing(self) -> None:
        completed, log = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "build",
            extra_env={"XCODEBUILD_DERIVED_DATA_PATH": "xcode-derived"},
            cwd=CHECKOUT_ROOT,
            inject_derived_data_path=False,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("TUIST=xcodebuild", log)
        self.assertIn(
            f"XCODEBUILD=-derivedDataPath {COMMON_REPO_ROOT / 'xcode-derived'}",
            log,
        )

    def test_rejects_legacy_tuist_opt_out_env_var(self) -> None:
        completed, log = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "build",
            extra_env={"HARNESS_MONITOR_USE_TUIST_TEST": "0"},
        )

        self.assertEqual(log, "")
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn(
            "HARNESS_MONITOR_USE_TUIST_TEST is no longer supported",
            completed.stderr,
        )
        self.assertIn(
            "all Harness Monitor xcodebuild lanes already use Tuist",
            completed.stderr,
        )

    def test_runner_uses_absolute_xcodebuild_by_default(self) -> None:
        rtk_shell = RTK_SHELL_PATH.read_text()

        self.assertIn("XCODEBUILD_BIN:-/usr/bin/xcodebuild", rtk_shell)
        self.assertIn('"$xcodebuild_bin" "$@"', rtk_shell)
        self.assertNotIn("\n  xcodebuild \"$@\"", rtk_shell)

    def test_runner_marks_derived_data_root_non_indexable(self) -> None:
        wrapper_source = SCRIPT_PATH.read_text()

        self.assertIn('source "$SCRIPT_DIR/lib/non-indexable-roots.sh"', wrapper_source)
        self.assertIn('ensure_non_indexable_directory "$derive_data_path"', wrapper_source)

    def test_can_disable_xcbeautify_for_unfiltered_test_output(self) -> None:
        completed, log = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "test-without-building",
            extra_env={"HARNESS_MONITOR_DISABLE_XCBEAUTIFY": "1"},
            include_xcbeautify=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("TUIST=xcodebuild", log)
        self.assertIn("XCODEBUILD=-derivedDataPath", log)
        self.assertIn("test-without-building", log)
        self.assertNotIn("XCBEAUTIFY=", log)

    def test_filters_cache_noise_but_keeps_test_output(self) -> None:
        completed, _ = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "test-without-building",
            extra_env={"FAKE_XCODEBUILD_EMIT_NOISE": "1"},
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertNotIn("Loading and constructing the graph", completed.stdout)
        self.assertNotIn("note: Local cache found", completed.stdout)
        self.assertNotIn("note: Using CAS output", completed.stdout)
        self.assertNotIn("note: Replay cache hit", completed.stdout)
        self.assertIn("Test run started.", completed.stdout)
        self.assertIn('Suite "Important suite" started', completed.stdout)
        self.assertIn('✔ "important test"', completed.stdout)
        self.assertIn("Test Execute Succeeded", completed.stdout)

    def test_skips_rtk_for_json_output(self) -> None:
        completed, log = self.run_script("-list", "-json")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("TUIST=xcodebuild", log)
        self.assertIn("XCODEBUILD=-derivedDataPath", log)
        self.assertIn("-list -json", log)

    def test_skips_rtk_for_show_build_settings(self) -> None:
        completed, log = self.run_script("-showBuildSettings", "-scheme", "HarnessMonitor")

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("TUIST=xcodebuild", log)
        self.assertIn("XCODEBUILD=-derivedDataPath", log)
        self.assertIn("-showBuildSettings -scheme HarnessMonitor", log)

    def test_test_actions_do_not_require_mapfile_or_inject_retries_by_default(self) -> None:
        completed, log = self.run_script(
            "-scheme",
            "HarnessMonitorAgentsE2E",
            "test-without-building",
            "-only-testing:HarnessMonitorAgentsE2ETests/SwarmFullFlowTests/testSwarmFullFlow",
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("TUIST=xcodebuild", log)
        self.assertIn("XCODEBUILD=-derivedDataPath", log)
        self.assertIn("-scheme HarnessMonitorAgentsE2E", log)
        self.assertIn("test-without-building", log)
        self.assertNotIn("-retry-tests-on-failure", log)
        self.assertNotIn("-test-iterations", log)
        self.assertNotIn("mapfile", completed.stderr)

    def test_wrapper_defaults_to_fast_feedback_settings(self) -> None:
        script = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertIn(
            'TEST_RETRY_ITERATIONS="${HARNESS_MONITOR_TEST_RETRY_ITERATIONS:-0}"',
            script,
            "xcodebuild wrapper should disable automatic test retries by default",
        )
        self.assertIn(
            'LEASE_LOCK_WAITER_TIMEOUT_SECONDS="${XCODEBUILD_LOCK_WAIT_TIMEOUT_SECONDS:-15}"',
            script,
            "xcodebuild wrapper should fail fast on shared lock contention by default",
        )

    def test_ui_test_actions_do_not_inject_retry_flags(self) -> None:
        completed, log = self.run_script(
            "-scheme",
            "HarnessMonitor",
            "test-without-building",
            "-only-testing:HarnessMonitorUITests/HarnessMonitorSheetUITests/testNewSessionSheetUsesStackedEditableFields",
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("TUIST=xcodebuild", log)
        self.assertIn("XCODEBUILD=-derivedDataPath", log)
        self.assertIn("HarnessMonitorUITests/HarnessMonitorSheetUITests", log)
        self.assertNotIn("-retry-tests-on-failure", log)
        self.assertNotIn("-test-iterations", log)

    def test_test_actions_resolve_repo_relative_paths_before_tuist_xcodebuild(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            fake_bin = temp_root / "bin"
            fake_bin.mkdir()
            tool_log = temp_root / "tool.log"

            write_executable(
                fake_bin / "rtk",
                f"""#!/bin/bash
set -euo pipefail
printf 'RTK=%s\\n' "$*" > "{tool_log}"
""",
            )
            write_executable(
                fake_bin / "tuist",
                f"""#!/bin/bash
set -euo pipefail
printf 'PWD=%s\\nARGS=%s\\n' "$PWD" "$*" > "{tool_log}"
""",
            )

            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "BASH_ENV": "/dev/null",
                    "RTK_BIN": str(fake_bin / "rtk"),
                    "TMPDIR": str(temp_root),
                }
            )

            completed = subprocess.run(
                [
                    "bash",
                    str(SCRIPT_PATH),
                    "-derivedDataPath",
                    "xcode-derived",
                    "-workspace",
                    "apps/harness-monitor-macos/HarnessMonitor.xcworkspace",
                    "-scheme",
                    "HarnessMonitor",
                    "test-without-building",
                ],
                check=False,
                capture_output=True,
                text=True,
                cwd=CHECKOUT_ROOT,
                env=env,
            )

            log = tool_log.read_text() if tool_log.exists() else ""
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn(f"PWD={APP_ROOT}", log)
            self.assertIn(f"-derivedDataPath {COMMON_REPO_ROOT / 'xcode-derived'}", log)
            self.assertIn(
                f"-workspace {APP_ROOT / 'HarnessMonitor.xcworkspace'}",
                log,
            )

    def test_normalizes_equals_form_path_flags_from_space_bearing_paths(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            fake_bin = temp_root / "bin"
            fake_bin.mkdir()
            tool_log = temp_root / "tool.json"
            caller_root = temp_root / "caller root"
            caller_root.mkdir()
            resolved_caller_root = caller_root.resolve()

            write_executable(
                fake_bin / "tuist",
                f"""#!/bin/bash
set -euo pipefail
/usr/bin/python3 - "{tool_log}" "$PWD" "$@" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
pwd = sys.argv[2]
argv = sys.argv[3:]
with path.open("w", encoding="utf-8") as handle:
    json.dump({{"pwd": pwd, "argv": argv}}, handle)
PY
""",
            )

            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "BASH_ENV": "/dev/null",
                    "TMPDIR": str(temp_root),
                }
            )

            completed = subprocess.run(
                [
                    "bash",
                    str(SCRIPT_PATH),
                    "-derivedDataPath=xcode-derived",
                    "-workspace=apps/harness-monitor-macos/HarnessMonitor.xcworkspace",
                    "-resultBundlePath=tmp/result bundle.xcresult",
                    "-scheme",
                    "HarnessMonitor",
                    "build",
                ],
                check=False,
                capture_output=True,
                text=True,
                cwd=caller_root,
                env=env,
            )

            payload = json.loads(tool_log.read_text(encoding="utf-8"))
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(payload["pwd"], str(APP_ROOT))
            self.assertEqual(
                payload["argv"],
                [
                    "xcodebuild",
                    f"-derivedDataPath={COMMON_REPO_ROOT / 'xcode-derived'}",
                    f"-workspace={resolved_caller_root / 'apps' / 'harness-monitor-macos' / 'HarnessMonitor.xcworkspace'}",
                    f"-resultBundlePath={resolved_caller_root / 'tmp' / 'result bundle.xcresult'}",
                    "-scheme",
                    "HarnessMonitor",
                    "build",
                ],
            )

    def test_missing_tuist_reports_required_tool_and_normalized_paths(self) -> None:
        completed, _ = self.run_script(
            "-derivedDataPath",
            "tmp/harness-monitor-missing-tuist-derived",
            "-workspace",
            "apps/harness-monitor-macos/HarnessMonitor.xcworkspace",
            "-resultBundlePath",
            "tmp/harness-monitor.xcresult",
            "-scheme",
            "HarnessMonitor",
            "build",
            cwd=CHECKOUT_ROOT,
            inject_derived_data_path=False,
            include_tuist=False,
        )

        combined_output = completed.stdout + completed.stderr
        self.assertEqual(completed.returncode, 127)
        self.assertIn(
            "tuist is required for all Harness Monitor xcodebuild wrapper lanes",
            combined_output,
        )
        self.assertIn(
            "path-normalization: -derivedDataPath tmp/harness-monitor-missing-tuist-derived -> "
            f"{CHECKOUT_ROOT / 'tmp/harness-monitor-missing-tuist-derived'}",
            completed.stderr,
        )
        self.assertIn(
            "path-normalization: -workspace apps/harness-monitor-macos/"
            "HarnessMonitor.xcworkspace -> "
            f"{APP_ROOT / 'HarnessMonitor.xcworkspace'}",
            completed.stderr,
        )
        self.assertIn(
            "path-normalization: -resultBundlePath tmp/harness-monitor.xcresult -> "
            f"{CHECKOUT_ROOT / 'tmp/harness-monitor.xcresult'}",
            completed.stderr,
        )
        self.assertNotIn("swift-compile-context:", completed.stderr)

    def test_failure_diagnostics_only_echo_path_arguments(self) -> None:
        completed, _ = self.run_script(
            "-derivedDataPath",
            "tmp/harness-monitor-failure-diagnostics-derived",
            "-resultBundlePath",
            "tmp/result bundle.xcresult",
            "CUSTOM_SIGNING_TOKEN=top-secret",
            "-scheme",
            "HarnessMonitor",
            "build",
            cwd=CHECKOUT_ROOT,
            inject_derived_data_path=False,
            include_tuist=False,
        )

        self.assertEqual(completed.returncode, 127)
        self.assertIn("xcodebuild-wrapper: original path args:", completed.stderr)
        self.assertIn("xcodebuild-wrapper: normalized path args:", completed.stderr)
        self.assertIn(
            "path-normalization: -derivedDataPath tmp/harness-monitor-failure-diagnostics-derived -> "
            f"{CHECKOUT_ROOT / 'tmp/harness-monitor-failure-diagnostics-derived'}",
            completed.stderr,
        )
        self.assertIn(
            "path-normalization: -resultBundlePath tmp/result bundle.xcresult -> "
            f"{CHECKOUT_ROOT / 'tmp/result bundle.xcresult'}",
            completed.stderr,
        )
        self.assertNotIn("CUSTOM_SIGNING_TOKEN=top-secret", completed.stderr)

    def test_failure_footer_persists_full_report_and_prints_searchable_path_last(self) -> None:
        with tempfile.TemporaryDirectory() as report_dir:
            completed, _ = self.run_script(
                "-scheme",
                "HarnessMonitor",
                "build",
                extra_env={
                    "FAKE_XCODEBUILD_FAIL_WITH_DIAGNOSTICS": "1",
                    "FAKE_XCBEAUTIFY_HIDE_DIAGNOSTICS": "1",
                    "HARNESS_MONITOR_FAILURE_REPORT_DIR": report_dir,
                },
                include_xcbeautify=True,
            )

            self.assertNotEqual(completed.returncode, 0)
            stderr_lines = [line for line in completed.stderr.splitlines() if line.strip()]
            footer = stderr_lines[-1]
            self.assertIn("failure", footer)
            self.assertIn("fail", footer)
            self.assertIn("error", footer)
            self.assertIn("full-report", footer)
            self.assertIn("path=", footer)

            report_path = Path(footer.split("path=", 1)[1].split(" ", 1)[0])
            console_log = Path(footer.split("console_log=", 1)[1].split(" ", 1)[0])
            raw_log = Path(footer.split("raw_log=", 1)[1].split(" ", 1)[0])

            self.assertTrue(report_path.exists(), report_path)
            self.assertTrue(console_log.exists(), console_log)
            self.assertTrue(raw_log.exists(), raw_log)

            report_body = report_path.read_text(encoding="utf-8")
            self.assertIn("Harness Monitor xcodebuild failure report", report_body)
            self.assertIn("===== filtered-console-output =====", report_body)
            self.assertIn("===== raw-xcodebuild-output =====", report_body)
            self.assertIn("/tmp/FakeSource.swift:1:3: error: synthetic failure 1", report_body)

    def test_succeeds_when_literal_mktemp_template_path_already_exists(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            fake_bin = temp_root / "bin"
            fake_bin.mkdir()
            derived_data_path = temp_root / "derived"
            tool_log = temp_root / "tool.log"
            literal_template = temp_root / "harness-xcodebuild.XXXXXX.log"
            literal_template.write_text("")

            write_executable(
                fake_bin / "rtk",
                f"""#!/bin/bash
set -euo pipefail
printf 'RTK=%s\\n' "$*" > "{tool_log}"
""",
            )
            write_executable(
                fake_bin / "xcodebuild",
                f"""#!/bin/bash
set -euo pipefail
printf 'XCODEBUILD=%s\\n' "$*" > "{tool_log}"
""",
            )
            write_executable(
                fake_bin / "tuist",
                f"""#!/bin/bash
set -euo pipefail
if [[ "${{1:-}}" != "xcodebuild" ]]; then
  echo "unexpected tuist subcommand: $*" >&2
  exit 1
fi
shift
"{fake_bin / "xcodebuild"}" "$@"
""",
            )

            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "BASH_ENV": "/dev/null",
                    "RTK_BIN": str(fake_bin / "rtk"),
                    "XCODEBUILD_BIN": str(fake_bin / "xcodebuild"),
                    "TMPDIR": str(temp_root),
                }
            )

            completed = subprocess.run(
                [
                    "bash",
                    str(SCRIPT_PATH),
                    "-derivedDataPath",
                    str(derived_data_path),
                    "-scheme",
                    "HarnessMonitor",
                    "build",
                ],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertNotIn("mktemp:", completed.stderr)

    def test_emits_swift_compile_context_when_failure_lacks_file_diagnostics(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            fake_bin = temp_root / "bin"
            fake_bin.mkdir()
            derived_data_path = temp_root / "derived"
            logs_root = derived_data_path / "Logs" / "Build"
            swift_file_list = (
                derived_data_path
                / "Build"
                / "Intermediates.noindex"
                / "HarnessMonitor.build"
                / "Debug"
                / "HarnessMonitorKit.build"
                / "Objects-normal"
                / "arm64"
                / "HarnessMonitorKit.SwiftFileList"
            )
            diagnostics_file = (
                swift_file_list.parent
                / "BrokenWarning.dia"
            )

            logs_root.mkdir(parents=True)
            swift_file_list.parent.mkdir(parents=True, exist_ok=True)
            swift_file_list.write_text(
                "/Users/x/Sources/RulesPane.swift\n/Users/x/Sources/SidebarView.swift\n"
            )
            diagnostics_file.write_text(
                "DIAG\n"
                "/Users/x/Tests/BrokenWarningTests.swift\n"
                "no-usage\n"
                "result of call to function returning 'HarnessMonitorAPIError' is unused\n"
            )

            empty_log = logs_root / "Z-empty.xcactivitylog"
            empty_log.write_bytes(b"")

            activity_log = logs_root / "A-build.xcactivitylog"
            with gzip.open(activity_log, "wt", encoding="utf-8") as handle:
                handle.write(
                    "builtin-Swift-Compilation -- "
                    "/Applications/Xcode.app/Contents/Developer/usr/bin/swiftc "
                    f"@{swift_file_list} -DDEBUG\n"
                )
            os.utime(activity_log, (1, 1))
            os.utime(empty_log, (2, 2))

            write_executable(
                fake_bin / "rtk",
                """#!/bin/bash
set -euo pipefail
""",
            )
            write_executable(
                fake_bin / "xcodebuild",
                """#!/bin/bash
set -euo pipefail
echo "error: emit-module command failed with exit code 1" >&2
echo "** BUILD FAILED **" >&2
exit 65
""",
            )
            write_executable(
                fake_bin / "tuist",
                f"""#!/bin/bash
set -euo pipefail
if [[ "${{1:-}}" != "xcodebuild" ]]; then
  echo "unexpected tuist subcommand: $*" >&2
  exit 1
fi
shift
"{fake_bin / "xcodebuild"}" "$@"
""",
            )

            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{fake_bin}:/usr/bin:/bin",
                    "BASH_ENV": "/dev/null",
                    "RTK_BIN": str(fake_bin / "rtk"),
                    "XCODEBUILD_BIN": str(fake_bin / "xcodebuild"),
                    "TMPDIR": str(temp_root),
                }
            )

            completed = subprocess.run(
                [
                    "bash",
                    str(SCRIPT_PATH),
                    "-derivedDataPath",
                    str(derived_data_path),
                    "-scheme",
                    "HarnessMonitor",
                    "build",
                ],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )

            self.assertEqual(completed.returncode, 65)
            self.assertIn(
                "swift-compile-context: latest non-empty activity log:",
                completed.stderr,
            )
            self.assertIn(str(activity_log), completed.stderr)
            self.assertIn(
                "swift-compile-context: latest Swift batch file list:",
                completed.stderr,
            )
            self.assertIn(str(swift_file_list), completed.stderr)
            self.assertIn(
                "swift-compile-context: source: /Users/x/Sources/RulesPane.swift",
                completed.stderr,
            )
            self.assertIn(
                "swift-diagnostics: extracted compiler diagnostics from .dia files",
                completed.stderr,
            )
            self.assertIn(str(diagnostics_file), completed.stderr)
            self.assertIn(
                "result of call to function returning 'HarnessMonitorAPIError' is unused",
                completed.stderr,
            )
            self.assertNotIn(str(empty_log), completed.stderr)


if __name__ == "__main__":
    unittest.main()
