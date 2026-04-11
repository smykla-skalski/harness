from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "summarize-instruments-run.py"


def load_module():
    spec = importlib.util.spec_from_file_location("summarize_instruments_run", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module from {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MODULE = load_module()


class RenderRecapTests(unittest.TestCase):
    def test_render_recap_includes_swiftui_deltas_and_top_offenders(self) -> None:
        summary = {
            "label": "wave-1",
            "created_at_utc": "20260411T130342Z",
            "git": {"commit": "cefbf335", "dirty": False},
            "captures": [
                {
                    "scenario": "select-session-cockpit",
                    "template": "SwiftUI",
                    "metrics": {
                        "swiftui_updates": {
                            "total_count": 125164,
                            "body_update_count": 11185,
                            "duration_ms_p95": 0.0137,
                            "duration_ns_max": 14_121_900,
                        },
                        "hitches": {"count": 0},
                        "potential_hangs": {"count": 0},
                        "top_offenders": [
                            {
                                "description": "Action Callback",
                                "view_name": "<unknown>",
                                "duration_ms": 38.0112,
                                "count": 1162,
                            },
                            {
                                "description": "SystemSplitView.update",
                                "view_name": "SystemSplitView",
                                "duration_ms": 11.4342,
                                "count": 18,
                            },
                        ],
                    },
                }
            ],
        }
        comparison = {
            "comparisons": [
                {
                    "scenario": "select-session-cockpit",
                    "template": "SwiftUI",
                    "metrics": {
                        "total_updates": {"delta": 18_258},
                        "body_updates": {"delta": 2_231},
                        "hitches": {"delta": 0},
                        "potential_hangs": {"delta": 0},
                    },
                }
            ]
        }

        recap = MODULE.render_recap(summary, comparison, top_count=2)

        self.assertIn("label=wave-1", recap)
        self.assertIn("commit=cefbf335 dirty=False", recap)
        self.assertIn("select-session-cockpit [SwiftUI]", recap)
        self.assertIn("total_updates=125164", recap)
        self.assertIn("d_total_updates=18258", recap)
        self.assertIn("Action Callback | <unknown> | duration_ms=38.0112 | count=1162", recap)
        self.assertIn(
            "SystemSplitView.update | SystemSplitView | duration_ms=11.4342 | count=18",
            recap,
        )

    def test_render_recap_handles_allocations_without_comparison(self) -> None:
        summary = {
            "label": "memory-wave",
            "created_at_utc": "20260411T140000Z",
            "captures": [
                {
                    "scenario": "settings-background-cycle",
                    "template": "Allocations",
                    "metrics": {
                        "allocations": {
                            "summary_rows": {
                                "All Heap & Anonymous VM": {
                                    "persistent_bytes": 121_086_112,
                                    "total_bytes": 325_327_536,
                                },
                                "All VM Regions": {
                                    "persistent_bytes": 453_525_504,
                                    "total_bytes": 495_435_776,
                                },
                            }
                        }
                    },
                }
            ],
        }

        recap = MODULE.render_recap(summary, None, top_count=5)

        self.assertIn("settings-background-cycle [Allocations]", recap)
        self.assertIn("All Heap & Anonymous VM: persistent_bytes=121086112", recap)
        self.assertIn("All VM Regions: persistent_bytes=453525504", recap)


if __name__ == "__main__":
    unittest.main()
