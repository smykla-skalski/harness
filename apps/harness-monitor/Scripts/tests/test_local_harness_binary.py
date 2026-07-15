from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = APP_ROOT / "Scripts" / "lib" / "local-harness-binary.sh"


def write_executable(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class LocalHarnessBinaryTests(unittest.TestCase):
    def prepare_checkout(self, root: Path) -> tuple[Path, Path]:
        checkout = root / "checkout"
        target = root / "target"
        build_log = root / "build.log"
        write_executable(
            checkout / "scripts" / "cargo-local.sh",
            """#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--print-env" ]]; then
  printf 'CARGO_TARGET_DIR=%s\\n' "$FAKE_TARGET_DIR"
  exit 0
fi

printf '%s\\n' "$*" >>"$FAKE_BUILD_LOG"
binary=""
while (( $# > 0 )); do
  if [[ "$1" == "--bin" ]]; then
    binary="$2"
    break
  fi
  shift
done
if [[ -z "$binary" ]]; then
  printf 'missing --bin in fake cargo invocation\\n' >&2
  exit 64
fi
mkdir -p "$FAKE_TARGET_DIR/debug"
touch "$FAKE_TARGET_DIR/debug/$binary"
chmod +x "$FAKE_TARGET_DIR/debug/$binary"
""",
        )
        return checkout, build_log

    def resolve(
        self,
        checkout: Path,
        target: Path,
        build_log: Path,
        binary_name: str,
        *,
        override: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "FAKE_TARGET_DIR": str(target),
                "FAKE_BUILD_LOG": str(build_log),
                "BASH_ENV": "/dev/null",
            }
        )
        if override is not None:
            env["TEST_BINARY_OVERRIDE"] = str(override)
        return subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; resolve_local_harness_binary "$2" TEST_BINARY_OVERRIDE "$3"',
                "resolver",
                str(HELPER_PATH),
                str(checkout),
                binary_name,
            ],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )

    def test_runtime_builds_place_trusted_adapters_beside_binary(self) -> None:
        for runtime_binary in ("harness-daemon", "harness-bridge"):
            with self.subTest(runtime_binary=runtime_binary), tempfile.TemporaryDirectory() as tmp_dir:
                root = Path(tmp_dir)
                checkout, build_log = self.prepare_checkout(root)
                target = root / "target"

                result = self.resolve(
                    checkout,
                    target,
                    build_log,
                    runtime_binary,
                )

                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.strip(), str(target / "debug" / runtime_binary))
                commands = build_log.read_text(encoding="utf-8").splitlines()
                self.assertEqual(
                    commands,
                    [
                        "build --quiet --manifest-path "
                        f"{checkout}/crates/harness-codex-acp/Cargo.toml "
                        "--bin harness-codex-acp",
                        "build --quiet --manifest-path "
                        f"{checkout}/crates/harness-openrouter-agent/Cargo.toml "
                        "--bin harness-openrouter-agent",
                        f"build --quiet --package {runtime_binary} --bin {runtime_binary}",
                    ],
                )
                for binary in (
                    runtime_binary,
                    "harness-codex-acp",
                    "harness-openrouter-agent",
                ):
                    self.assertTrue(os.access(target / "debug" / binary, os.X_OK))

    def test_explicit_daemon_override_skips_all_builds(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            checkout, build_log = self.prepare_checkout(root)
            override = root / "custom-daemon"
            write_executable(override, "#!/usr/bin/env bash\nexit 0\n")

            result = self.resolve(
                checkout,
                root / "target",
                build_log,
                "harness-daemon",
                override=override,
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.strip(), str(override))
            self.assertFalse(build_log.exists())


if __name__ == "__main__":
    unittest.main()
