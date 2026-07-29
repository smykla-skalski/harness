from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "sccache-status.py"


def load_script():
    spec = importlib.util.spec_from_file_location("sccache_status", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


status = load_script()


class SccacheStatusTests(unittest.TestCase):
    def test_stats_query_targets_configured_socket(self) -> None:
        with patch.object(status.subprocess, "run") as run:
            run.return_value.returncode = 0
            run.return_value.stdout = ""
            run.return_value.stderr = ""
            status._stats("/tools/sccache", "/tmp/repo.sock")

        environment = run.call_args.kwargs["env"]
        self.assertEqual(environment["SCCACHE_SERVER_UDS"], "/tmp/repo.sock")

    def test_disabled_cache_still_reports_wrapper_ownership(self) -> None:
        output = io.StringIO()
        with (
            patch.object(
                status,
                "_cargo_environment",
                return_value={
                    "CACHE_MODE": "disabled",
                    "RUSTC_WRAPPER": "",
                    "SCCACHE_BIN": "",
                    "SCCACHE_SERVER_UDS": "",
                },
            ),
            patch.object(
                status,
                "_configured_wrapper",
                return_value="scripts/rustc-cache-wrapper.sh",
            ),
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(status.main(), 0)

        self.assertIn(
            "rustc_wrapper_config=scripts/rustc-cache-wrapper.sh",
            output.getvalue(),
        )
        self.assertIn("rustc_wrapper_env=unset", output.getvalue())
        self.assertIn("sccache_status=disabled", output.getvalue())

    def test_inventory_excludes_sccache_compiler_clients(self) -> None:
        configured = Path("/tmp/harness-sccache/repo.sock")
        owners = {
            41: (str(configured),),
            42: (str(configured),),
            43: ("/tmp/harness-sccache/orphan.sock (deleted)",),
        }
        commands = {
            41: "/tools/sccache",
            42: "/tools/sccache /tools/rustc --crate-name harness",
            43: "/tools/sccache",
        }
        with (
            patch.object(status, "socket_owners_under", return_value=owners),
            patch.object(status, "pids_for_socket", return_value=(41, 42)),
            patch.object(
                status,
                "process_command",
                side_effect=lambda pid: commands[pid],
            ),
        ):
            inventory, live, orphan, paths = status._server_inventory(configured)

        self.assertEqual(inventory, "available")
        self.assertEqual(live, 1)
        self.assertEqual(orphan, 1)
        self.assertEqual(paths, ("/tmp/harness-sccache/orphan.sock",))


if __name__ == "__main__":
    unittest.main()
