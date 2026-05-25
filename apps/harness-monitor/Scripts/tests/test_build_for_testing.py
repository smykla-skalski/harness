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
SCRIPT_PATH = APP_ROOT / "Scripts" / "build-for-testing.sh"
QUALITY_GATE_SCRIPT_PATH = APP_ROOT / "Scripts" / "run-quality-gates.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class BuildForTestingScriptTests(unittest.TestCase):
    def test_defaults_to_skipping_daemon_build_and_bundle(self) -> None:
        script = SCRIPT_PATH.read_text(encoding="utf-8")

        self.assertIn(
            'DAEMON_AGENT_BUILD_SKIP="${HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUILD:-1}"',
            script,
        )
        self.assertIn(
            'DAEMON_AGENT_BUNDLE_SKIP="${HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE:-1}"',
            script,
        )
        self.assertIn(
            'export HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUILD="$DAEMON_AGENT_BUILD_SKIP"',
            script,
        )
        self.assertIn(
            'export HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE="$DAEMON_AGENT_BUNDLE_SKIP"',
            script,
        )
        self.assertIn(
            'HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUILD="$DAEMON_AGENT_BUILD_SKIP"',
            script,
        )
        self.assertIn(
            'HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE="$DAEMON_AGENT_BUNDLE_SKIP"',
            script,
        )

    def test_quality_gate_explicitly_reenables_daemon_validation(self) -> None:
        script = QUALITY_GATE_SCRIPT_PATH.read_text(encoding="utf-8")

        self.assertIn("HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUILD=0", script)
        self.assertIn("HARNESS_MONITOR_SKIP_DAEMON_AGENT_BUNDLE=0", script)

    def wait_for_path(self, path: Path, *, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if path.exists():
                return
            time.sleep(0.05)
        self.fail(f"timed out waiting for {path}")

    def _spawn_signalled_during_generate(
        self,
        temp_root: Path,
        *,
        protect: str,
        marker_path: Path,
        release_path: Path,
        build_ran_path: Path,
    ) -> subprocess.Popen[str]:
        fake_bin = temp_root / "bin"
        fake_bin.mkdir()
        derived_data_path = temp_root / "derived"
        generate_script = temp_root / "generate.sh"

        # Project-generate stub: open the pre-exec window, then block until the
        # test releases it. The test sends SIGTERM while this is still blocked so
        # the signal is pending the moment generate returns -- exactly where an
        # unprotected build-for-testing would abort before the xcodebuild step.
        write_executable(
            generate_script,
            f"""#!/bin/bash
set -euo pipefail
printf 'started\\n' > "{marker_path}"
while [ ! -e "{release_path}" ]; do
  sleep 0.05
done
exit 0
""",
        )
        # Records that the xcodebuild build-for-testing step was reached. A
        # protected run gets here after ignoring the SIGTERM; a torn-down run
        # never does.
        write_executable(
            fake_bin / "xcodebuild",
            f"""#!/bin/bash
set -euo pipefail
for arg in "$@"; do
  if [[ "$arg" == "build-for-testing" ]]; then
    printf 'build-ran\\n' > "{build_ran_path}"
  fi
done
exit 0
""",
        )
        write_executable(
            fake_bin / "tuist",
            f"""#!/bin/bash
set -euo pipefail
if [[ "${{1:-}}" == "xcodebuild" ]]; then
  shift
fi
exec "{fake_bin / "xcodebuild"}" "$@"
""",
        )
        write_executable(fake_bin / "xcbeautify", "#!/bin/bash\nset -euo pipefail\ncat\n")

        env = os.environ.copy()
        env.update(
            {
                "GENERATE_PROJECT_SCRIPT": str(generate_script),
                "XCODEBUILD_DERIVED_DATA_PATH": str(derived_data_path),
                "HARNESS_MONITOR_DISABLE_XCBEAUTIFY": "1",
                "HARNESS_MONITOR_SHARED_COMPILATION_CAS": "0",
                "PATH": f"{fake_bin}:/usr/bin:/bin",
                "BASH_ENV": "/dev/null",
                "XCODEBUILD_BIN": str(fake_bin / "xcodebuild"),
                "TMPDIR": str(temp_root),
                "HARNESS_SKIP_STALE_CHECK": "1",
                "HARNESS_MONITOR_BUILD_PROTECT_INFLIGHT": protect,
                "HARNESS_MONITOR_GLOBAL_SEMAPHORE_DIR": str(temp_root / "semaphore"),
            }
        )

        proc = subprocess.Popen(
            ["bash", str(SCRIPT_PATH)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            start_new_session=True,
        )
        self.wait_for_path(marker_path)
        return proc

    def test_protect_inflight_ignores_sigterm_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            marker = temp_root / "generate-open"
            release = temp_root / "release"
            build_ran = temp_root / "build-ran"
            proc = self._spawn_signalled_during_generate(
                temp_root,
                protect="1",
                marker_path=marker,
                release_path=release,
                build_ran_path=build_ran,
            )
            try:
                proc.send_signal(signal.SIGTERM)
                proc.send_signal(signal.SIGHUP)
                time.sleep(0.3)
                release.write_text("go")
                stdout, stderr = proc.communicate(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                proc.wait(timeout=5)
                raise
            self.assertEqual(proc.returncode, 0, stdout + stderr)
            self.assertTrue(
                build_ran.exists(),
                "protected build-for-testing must reach xcodebuild after a SIGTERM",
            )

    def test_protect_inflight_off_honors_sigterm(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            temp_root = Path(tmp_dir)
            marker = temp_root / "generate-open"
            release = temp_root / "release"
            build_ran = temp_root / "build-ran"
            proc = self._spawn_signalled_during_generate(
                temp_root,
                protect="0",
                marker_path=marker,
                release_path=release,
                build_ran_path=build_ran,
            )
            try:
                proc.send_signal(signal.SIGTERM)
                time.sleep(0.3)
                release.write_text("go")
                stdout, stderr = proc.communicate(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                proc.wait(timeout=5)
                self.fail(
                    "build-for-testing must tear down on SIGTERM when protection is off"
                )
            self.assertEqual(proc.returncode, 143, stdout + stderr)
            self.assertFalse(
                build_ran.exists(),
                "unprotected build-for-testing must abort before xcodebuild",
            )


if __name__ == "__main__":
    unittest.main()
