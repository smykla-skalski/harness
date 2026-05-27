from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


SCRIPTS_ROOT = Path(__file__).resolve().parents[1]
SWIFT_TOOL_ENV_SOURCE = SCRIPTS_ROOT / "lib" / "swift-tool-env.sh"
FRESHNESS_SOURCE = SCRIPTS_ROOT / "lib" / "swift-package-freshness.sh"


def write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class SwiftPackageFreshnessTests(unittest.TestCase):
    def _state_path(self, package_dir: Path, binary_name: str) -> Path:
        return package_dir / ".build" / "release" / f".{binary_name}.freshness-state"

    def _run_ensure_binary(
        self,
        package_dir: Path,
        binary_name: str,
        env: dict[str, str],
    ) -> subprocess.CompletedProcess[str]:
        command = (
            f"source {SWIFT_TOOL_ENV_SOURCE}; "
            f"source {FRESHNESS_SOURCE}; "
            f'ensure_swift_package_release_binary_fresh "{package_dir}" "{binary_name}"'
        )
        return subprocess.run(
            ["bash", "-c", command],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    def _base_env(self, fake_swift_bin_dir: Path, log_path: Path) -> dict[str, str]:
        env = os.environ.copy()
        env["PATH"] = f"{fake_swift_bin_dir}:{env.get('PATH', '')}"
        env["SWIFT_LOG_PATH"] = str(log_path)
        env["SWIFT_BINARY_NAME"] = "fake-tool"
        env.setdefault("TMPDIR", "/tmp")
        return env

    def _make_fake_swift(self, bin_dir: Path) -> None:
        write_executable(
            bin_dir / "swift",
            "#!/bin/bash\n"
            "set -euo pipefail\n"
            "printf '%s\\n' \"$*\" >> \"$SWIFT_LOG_PATH\"\n"
            "pkg=''\n"
            "while (($# > 0)); do\n"
            "  case \"$1\" in\n"
            "    --package-path)\n"
            "      pkg=\"$2\"\n"
            "      shift 2\n"
            "      ;;\n"
            "    *)\n"
            "      shift\n"
            "      ;;\n"
            "  esac\n"
            "done\n"
            "mkdir -p \"$pkg/.build/release\"\n"
            "touch \"$pkg/.build/release/$SWIFT_BINARY_NAME\"\n"
            "chmod +x \"$pkg/.build/release/$SWIFT_BINARY_NAME\"\n",
        )

    def test_builds_when_binary_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir = root / "pkg"
            binary_path = package_dir / ".build" / "release" / "fake-tool"
            source_file = package_dir / "Sources" / "Main.swift"
            log_path = root / "swift.log"
            fake_bin_dir = root / "bin"
            fake_bin_dir.mkdir()
            self._make_fake_swift(fake_bin_dir)

            source_file.parent.mkdir(parents=True)
            source_file.write_text("// source\n")
            (package_dir / "Package.swift").write_text("// package\n")

            completed = self._run_ensure_binary(
                package_dir=package_dir,
                binary_name="fake-tool",
                env=self._base_env(fake_bin_dir, log_path),
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(completed.stdout.strip(), str(binary_path))
            self.assertTrue(binary_path.exists())
            self.assertIn("build -c release --package-path", log_path.read_text())
            self.assertTrue(
                self._state_path(package_dir, "fake-tool").exists(),
                "freshness state file should be written after build",
            )

    def test_builds_when_binary_is_stale(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir = root / "pkg"
            binary_path = package_dir / ".build" / "release" / "fake-tool"
            source_file = package_dir / "Sources" / "Main.swift"
            package_swift = package_dir / "Package.swift"
            log_path = root / "swift.log"
            fake_bin_dir = root / "bin"
            fake_bin_dir.mkdir()
            self._make_fake_swift(fake_bin_dir)

            source_file.parent.mkdir(parents=True)
            source_file.write_text("// source\n")
            package_swift.write_text("// package\n")
            binary_path.parent.mkdir(parents=True)
            binary_path.write_text("")
            binary_path.chmod(binary_path.stat().st_mode | stat.S_IXUSR)

            stale_epoch = int(time.time()) - 20
            fresh_epoch = stale_epoch + 10
            os.utime(binary_path, (stale_epoch, stale_epoch))
            os.utime(source_file, (fresh_epoch, fresh_epoch))
            os.utime(package_swift, (stale_epoch, stale_epoch))

            completed = self._run_ensure_binary(
                package_dir=package_dir,
                binary_name="fake-tool",
                env=self._base_env(fake_bin_dir, log_path),
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(completed.stdout.strip(), str(binary_path))
            self.assertIn("build -c release --package-path", log_path.read_text())

    def test_skips_build_when_binary_is_fresh(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir = root / "pkg"
            binary_path = package_dir / ".build" / "release" / "fake-tool"
            source_file = package_dir / "Sources" / "Main.swift"
            package_swift = package_dir / "Package.swift"
            log_path = root / "swift.log"
            fake_bin_dir = root / "bin"
            fake_bin_dir.mkdir()
            self._make_fake_swift(fake_bin_dir)

            source_file.parent.mkdir(parents=True)
            source_file.write_text("// source\n")
            package_swift.write_text("// package\n")
            binary_path.parent.mkdir(parents=True)
            binary_path.write_text("")
            binary_path.chmod(binary_path.stat().st_mode | stat.S_IXUSR)

            stale_epoch = int(time.time()) - 20
            fresh_epoch = stale_epoch + 10
            os.utime(source_file, (stale_epoch, stale_epoch))
            os.utime(package_swift, (stale_epoch, stale_epoch))
            os.utime(binary_path, (fresh_epoch, fresh_epoch))
            state_path = self._state_path(package_dir, "fake-tool")
            state_path.parent.mkdir(parents=True, exist_ok=True)
            state_path.write_text(
                "66f3eb5db58f7de7f9c8d6456f95f8f7f8f83ec8dd81a4ce7f7f75d3508a4d08\n"
            )

            # Prime state with real current fingerprint from the helper.
            prime = subprocess.run(
                [
                    "bash",
                    "-c",
                    (
                        f"source {SWIFT_TOOL_ENV_SOURCE}; "
                        f"source {FRESHNESS_SOURCE}; "
                        f'swift_package_source_fingerprint "{package_dir}"'
                    ),
                ],
                check=True,
                capture_output=True,
                text=True,
                env=self._base_env(fake_bin_dir, log_path),
            )
            state_path.write_text(prime.stdout.strip() + "\n")

            completed = self._run_ensure_binary(
                package_dir=package_dir,
                binary_name="fake-tool",
                env=self._base_env(fake_bin_dir, log_path),
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(completed.stdout.strip(), str(binary_path))
            self.assertFalse(log_path.exists(), "swift build should not run for a fresh binary")

    def test_rebuilds_when_tracked_file_is_deleted(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir = root / "pkg"
            binary_path = package_dir / ".build" / "release" / "fake-tool"
            source_file = package_dir / "Sources" / "Main.swift"
            log_path = root / "swift.log"
            fake_bin_dir = root / "bin"
            fake_bin_dir.mkdir()
            self._make_fake_swift(fake_bin_dir)

            source_file.parent.mkdir(parents=True)
            source_file.write_text("// source\n")
            (package_dir / "Package.swift").write_text("// package\n")
            binary_path.parent.mkdir(parents=True)
            binary_path.write_text("")
            binary_path.chmod(binary_path.stat().st_mode | stat.S_IXUSR)

            # Prime a matching state from current source set.
            prime = subprocess.run(
                [
                    "bash",
                    "-c",
                    (
                        f"source {SWIFT_TOOL_ENV_SOURCE}; "
                        f"source {FRESHNESS_SOURCE}; "
                        f'swift_package_source_fingerprint "{package_dir}"'
                    ),
                ],
                check=True,
                capture_output=True,
                text=True,
                env=self._base_env(fake_bin_dir, log_path),
            )
            self._state_path(package_dir, "fake-tool").write_text(
                prime.stdout.strip() + "\n"
            )

            source_file.unlink()

            completed = self._run_ensure_binary(
                package_dir=package_dir,
                binary_name="fake-tool",
                env=self._base_env(fake_bin_dir, log_path),
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn(
                "build -c release --package-path",
                log_path.read_text(),
                "deletion should invalidate freshness state and trigger rebuild",
            )

    def test_rebuilds_when_new_tracked_file_is_added(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            package_dir = root / "pkg"
            binary_path = package_dir / ".build" / "release" / "fake-tool"
            source_file = package_dir / "Sources" / "Main.swift"
            added_file = package_dir / "Sources" / "Extra.swift"
            log_path = root / "swift.log"
            fake_bin_dir = root / "bin"
            fake_bin_dir.mkdir()
            self._make_fake_swift(fake_bin_dir)

            source_file.parent.mkdir(parents=True)
            source_file.write_text("// source\n")
            (package_dir / "Package.swift").write_text("// package\n")
            binary_path.parent.mkdir(parents=True)
            binary_path.write_text("")
            binary_path.chmod(binary_path.stat().st_mode | stat.S_IXUSR)

            prime = subprocess.run(
                [
                    "bash",
                    "-c",
                    (
                        f"source {SWIFT_TOOL_ENV_SOURCE}; "
                        f"source {FRESHNESS_SOURCE}; "
                        f'swift_package_source_fingerprint "{package_dir}"'
                    ),
                ],
                check=True,
                capture_output=True,
                text=True,
                env=self._base_env(fake_bin_dir, log_path),
            )
            self._state_path(package_dir, "fake-tool").write_text(
                prime.stdout.strip() + "\n"
            )

            added_file.write_text("// extra\n")

            completed = self._run_ensure_binary(
                package_dir=package_dir,
                binary_name="fake-tool",
                env=self._base_env(fake_bin_dir, log_path),
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn(
                "build -c release --package-path",
                log_path.read_text(),
                "new tracked file should invalidate freshness state and trigger rebuild",
            )


if __name__ == "__main__":
    unittest.main()
