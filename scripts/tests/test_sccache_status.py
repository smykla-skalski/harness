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
            run.return_value.stdout = """\
Compile requests                   101
Cache hits                           1
Cache misses                       100

Non-cacheable reasons:
incremental                         40
multiple input files                20
"""
            run.return_value.stderr = ""
            values, reasons, outcome = status._stats(
                "/tools/sccache",
                "/tmp/repo.sock",
            )

        environment = run.call_args.kwargs["env"]
        self.assertEqual(environment["SCCACHE_SERVER_UDS"], "/tmp/repo.sock")
        self.assertEqual(outcome, "ok")
        self.assertEqual(values["Compile requests"], "101")
        self.assertEqual(
            reasons,
            {"incremental": 40, "multiple input files": 20},
        )

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

    def test_inventory_distinguishes_other_live_orphan_and_client(self) -> None:
        configured = Path("/tmp/harness-sccache/repo.sock")
        owners = {
            41: (str(configured),),
            42: (str(configured),),
            43: ("/tmp/harness-sccache/other.sock",),
            44: ("/tmp/harness-sccache/orphan.sock (deleted)",),
        }
        commands = {
            41: "/tools/sccache",
            42: "/tools/sccache /tools/rustc --crate-name harness",
            43: "/other/sccache",
            44: "/tools/sccache",
        }
        peers = {
            str(configured): ("live", 41),
            "/tmp/harness-sccache/other.sock": ("live", 43),
            "/tmp/harness-sccache/orphan.sock": ("absent", None),
        }
        with (
            patch.object(status, "socket_owners_under", return_value=owners),
            patch.object(status, "peer_pid", side_effect=lambda path: peers[str(path)]),
            patch.object(
                status,
                "process_command",
                side_effect=lambda pid: commands[pid],
            ),
        ):
            inventory = status._server_inventory(configured)

        self.assertEqual(inventory.availability, "available")
        self.assertEqual(inventory.configured, 1)
        self.assertEqual(inventory.other_live, 1)
        self.assertEqual(inventory.orphan, 1)
        self.assertEqual(inventory.unknown, 0)
        self.assertEqual(
            inventory.other_live_paths,
            ("/tmp/harness-sccache/other.sock",),
        )
        self.assertEqual(
            inventory.orphan_paths,
            ("/tmp/harness-sccache/orphan.sock",),
        )

    def test_overall_status_preserves_server_failures_and_measurement_gaps(self) -> None:
        self.assertEqual(status._overall_status("leaking", "low"), "leaking")
        self.assertEqual(status._overall_status("unavailable", "low"), "unavailable")
        self.assertEqual(status._overall_status("healthy", "unavailable"), "degraded")
        self.assertEqual(status._overall_status("healthy", "low"), "degraded")
        self.assertEqual(status._overall_status("healthy", "normal"), "healthy")

    def test_low_reuse_degrades_effectiveness_not_server_health(self) -> None:
        output = io.StringIO()
        inventory = status.ServerInventory(
            availability="available",
            configured=1,
            other_live=0,
            orphan=0,
            unknown=0,
            other_live_paths=(),
            orphan_paths=(),
        )
        with (
            patch.object(
                status,
                "_cargo_environment",
                return_value={
                    "CACHE_MODE": "sccache",
                    "RUSTC_WRAPPER": "",
                    "SCCACHE_BIN": "/tools/sccache",
                    "SCCACHE_SERVER_UDS": "/tmp/repo.sock",
                },
            ),
            patch.object(status, "_configured_wrapper", return_value="wrapper"),
            patch.object(status, "_socket_accepts", return_value=True),
            patch.object(
                status,
                "_stats",
                return_value=(
                    {
                        "Compile requests": "101",
                        "Cache hits": "1",
                        "Cache misses": "100",
                        "Non-cacheable calls": "80",
                    },
                    {"incremental": 40, "multiple input files": 40},
                    "ok",
                ),
            ),
            patch.object(status, "_server_inventory", return_value=inventory),
            patch.object(status, "_cache_paths", return_value=()),
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(status.main(), 0)

        self.assertIn("sccache_status=degraded", output.getvalue())
        self.assertIn("sccache_server_status=healthy", output.getvalue())
        self.assertIn("cache_effectiveness=low", output.getvalue())
        self.assertIn("historical_cache_reuse=low", output.getvalue())
        self.assertIn("non_cacheable_rate=79.21%", output.getvalue())
        self.assertIn(
            "dominant_non_cacheable_reason=incremental:40",
            output.getvalue(),
        )
        self.assertIn(
            "non_cacheable_reasons=incremental:40,multiple input files:40",
            output.getvalue(),
        )


if __name__ == "__main__":
    unittest.main()
