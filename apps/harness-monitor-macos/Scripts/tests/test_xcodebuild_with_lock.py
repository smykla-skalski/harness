from __future__ import annotations

import gzip
import json
import os
import stat
import subprocess
import tempfile
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
    def run_script(
        self,
        *args: str,
        extra_env: dict[str, str] | None = None,
        preexisting_lock_pid: int | None = None,
        cwd: Path | None = None,
        inject_derived_data_path: bool = True,
        include_tuist: bool = True,
    ) -> tuple[subprocess.CompletedProcess[str], str]:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            fake_bin = temp_root / "bin"
            fake_bin.mkdir()
            derived_data_path = temp_root / "derived"
            tool_log = temp_root / "tool.log"

            if preexisting_lock_pid is not None:
                lock_dir = derived_data_path / ".xcodebuild.lock"
                lock_dir.mkdir(parents=True)
                (lock_dir / "pid").write_text(f"{preexisting_lock_pid}\n")

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

    def test_reports_lock_owner_while_waiting_for_shared_derived_data(self) -> None:
        sleeper = subprocess.Popen(["/bin/sleep", "10"])
        try:
            completed, log = self.run_script(
                "-scheme",
                "HarnessMonitor",
                "build",
                extra_env={
                    "XCODEBUILD_LOCK_TIMEOUT_SECONDS": "1",
                    "XCODEBUILD_LOCK_POLL_SECONDS": "1",
                },
                preexisting_lock_pid=sleeper.pid,
            )
        finally:
            sleeper.terminate()
            sleeper.wait(timeout=5)

        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("Waiting for xcodebuild lock at", completed.stderr)
        self.assertIn(f"lock owner pid: {sleeper.pid}", completed.stderr)
        self.assertIn("lock owner command:", completed.stderr)
        self.assertIn("Timed out waiting for xcodebuild lock at", completed.stderr)
        self.assertEqual(log, "")

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

    def test_test_actions_do_not_require_mapfile(self) -> None:
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
        self.assertIn("-retry-tests-on-failure -test-iterations 2", log)
        self.assertNotIn("mapfile", completed.stderr)

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
            "xcode-derived",
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
            "path-normalization: -derivedDataPath xcode-derived -> "
            f"{COMMON_REPO_ROOT / 'xcode-derived'}",
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
            "xcode-derived",
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
            "path-normalization: -derivedDataPath xcode-derived -> "
            f"{COMMON_REPO_ROOT / 'xcode-derived'}",
            completed.stderr,
        )
        self.assertIn(
            "path-normalization: -resultBundlePath tmp/result bundle.xcresult -> "
            f"{CHECKOUT_ROOT / 'tmp/result bundle.xcresult'}",
            completed.stderr,
        )
        self.assertNotIn("CUSTOM_SIGNING_TOKEN=top-secret", completed.stderr)

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

            logs_root.mkdir(parents=True)
            swift_file_list.parent.mkdir(parents=True, exist_ok=True)
            swift_file_list.write_text(
                "/Users/x/Sources/RulesPane.swift\n/Users/x/Sources/SidebarView.swift\n"
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
            self.assertNotIn(str(empty_log), completed.stderr)


if __name__ == "__main__":
    unittest.main()
