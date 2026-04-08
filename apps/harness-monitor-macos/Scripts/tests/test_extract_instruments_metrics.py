from __future__ import annotations

import importlib.util
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "extract-instruments-metrics.py"
FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"


def load_module():
    spec = importlib.util.spec_from_file_location("extract_instruments_metrics", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module from {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MODULE = load_module()


class DiscoverSchemasTests(unittest.TestCase):
    def test_discovers_swiftui_schemas_and_allocation_detail_names(self) -> None:
        toc_root = ET.parse(FIXTURES_DIR / "toc-sample.xml").getroot()

        schemas = MODULE.discover_available_schemas(toc_root)
        allocation_details = MODULE.discover_allocation_details(toc_root)

        self.assertEqual(
            schemas,
            {
                "swiftui-updates",
                "swiftui-update-groups",
                "swiftui-causes",
                "hitches",
                "potential-hangs",
                "time-profile",
            },
        )
        self.assertEqual(allocation_details, {"Statistics"})


class SwiftUICauseParsingTests(unittest.TestCase):
    def test_summarizes_cause_labels_nodes_and_properties(self) -> None:
        metrics = MODULE.parse_swiftui_causes(FIXTURES_DIR / "swiftui-causes-sample.xml")

        self.assertEqual(metrics["summary"]["total_count"], 4)
        self.assertEqual(metrics["summary"]["label_counts"]["Update"], 3)
        self.assertEqual(metrics["summary"]["label_counts"]["Creation"], 1)
        self.assertEqual(metrics["summary"]["source_node_counts"]["@State store"], 3)
        self.assertEqual(metrics["summary"]["destination_node_counts"]["Text Content"], 2)
        self.assertEqual(metrics["summary"]["changed_property_counts"]["self"], 2)
        self.assertEqual(metrics["summary"]["value_type_counts"]["SessionSummary"], 2)
        self.assertEqual(metrics["top_causes"][0]["count"], 2)
        self.assertEqual(metrics["top_causes"][0]["source_node"], "@State store")
        self.assertEqual(metrics["top_causes"][0]["destination_node"], "Text Content")


class SwiftUIUpdateGroupParsingTests(unittest.TestCase):
    def test_summarizes_update_group_durations_and_labels(self) -> None:
        metrics = MODULE.parse_swiftui_update_groups(FIXTURES_DIR / "swiftui-update-groups-sample.xml")

        self.assertEqual(metrics["summary"]["total_count"], 4)
        self.assertEqual(metrics["summary"]["duration_ns_total"], 3_951_000)
        self.assertEqual(metrics["summary"]["duration_ns_max"], 2_250_000)
        self.assertEqual(metrics["summary"]["duration_ms_p95"], 2.25)
        self.assertEqual(metrics["summary"]["label_counts"]["(RootDisplayList DisplayList)"], 2)
        self.assertEqual(metrics["top_groups"][0]["label"], "(RootDisplayList DisplayList)")
        self.assertEqual(metrics["top_groups"][0]["count"], 2)
        self.assertEqual(metrics["top_groups"][0]["duration_ns"], 3_250_000)
        self.assertEqual(metrics["top_groups"][0]["duration_ms"], 3.25)


if __name__ == "__main__":
    unittest.main()
