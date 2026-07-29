from __future__ import annotations

import importlib.util
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
AUDIT_PATH = ROOT / "scripts" / "sccache-cleanup-audit.py"


def load_audit():
    spec = importlib.util.spec_from_file_location("sccache_cleanup_audit", AUDIT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {AUDIT_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SccacheCleanupAuditTests(unittest.TestCase):
    def test_retention_keeps_latest_hundred_complete_events(self) -> None:
        audit = load_audit()
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "audit.jsonl"
            for index in range(105):
                audit._write_bounded(log, f'{{"index":{index}}}')
            lines = log.read_text().splitlines()

        self.assertEqual(len(lines), audit.RETENTION)
        self.assertEqual(lines[0], '{"index":5}')
        self.assertEqual(lines[-1], '{"index":104}')

    def test_event_records_every_destructive_attribution_field(self) -> None:
        audit = load_audit()
        event = audit._event(
            Namespace(
                mode="normal+force",
                cache_path=["/fixture/cache"],
                size_kb=42,
                reason="--force",
                threshold_kb=100,
                server_socket="/fixture/server.sock",
                server_pid=["17"],
                stop_outcome="stopped",
            )
        )

        self.assertEqual(event["mode"], "normal+force")
        self.assertEqual(event["cache_paths"], ["/fixture/cache"])
        self.assertEqual(event["measured_size_kb"], 42)
        self.assertEqual(event["reason"], "--force")
        self.assertEqual(event["threshold_kb"], 100)
        self.assertEqual(event["server_socket"], "/fixture/server.sock")
        self.assertEqual(event["server_identity"], "pid-identified")
        self.assertEqual(event["server_pids"], [17])
        self.assertEqual(event["stop_outcome"], "stopped")
        self.assertIn("timestamp", event)


if __name__ == "__main__":
    unittest.main()
