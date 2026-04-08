#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


ALLOCATION_SUMMARY_CATEGORIES = [
    "All Heap & Anonymous VM",
    "All Heap Allocations",
    "All Anonymous VM",
    "All VM Regions",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Compare two Harness Monitor Instruments audit runs.")
    parser.add_argument("--current", required=True, help="Current run directory or summary.json")
    parser.add_argument("--baseline", required=True, help="Baseline run directory or summary.json")
    parser.add_argument("--output-dir", required=True, help="Directory to write comparison.json and comparison.md")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    current = load_summary(Path(args.current))
    baseline = load_summary(Path(args.baseline))
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    comparisons = []
    baseline_index = {capture_key(item): item for item in baseline.get("captures", [])}
    for current_capture in current.get("captures", []):
        key = capture_key(current_capture)
        baseline_capture = baseline_index.get(key)
        if baseline_capture is None:
            continue
        comparisons.append(compare_capture(current_capture, baseline_capture))

    comparison = {
        "current_label": current.get("label"),
        "baseline_label": baseline.get("label"),
        "current_created_at_utc": current.get("created_at_utc"),
        "baseline_created_at_utc": baseline.get("created_at_utc"),
        "comparisons": comparisons,
    }
    (output_dir / "comparison.json").write_text(
        json.dumps(comparison, indent=2, sort_keys=True),
        encoding="utf-8",
    )
    (output_dir / "comparison.md").write_text(render_markdown(comparison), encoding="utf-8")
    return 0


def load_summary(path: Path) -> dict[str, Any]:
    resolved = path.resolve()
    if resolved.is_dir():
        resolved = resolved / "summary.json"
    return json.loads(resolved.read_text(encoding="utf-8"))


def capture_key(capture: dict[str, Any]) -> tuple[str, str]:
    return capture["scenario"], capture["template"]


def compare_capture(current: dict[str, Any], baseline: dict[str, Any]) -> dict[str, Any]:
    if current["template"] == "SwiftUI":
        return compare_swiftui_capture(current, baseline)
    if current["template"] == "Allocations":
        return compare_allocations_capture(current, baseline)
    raise ValueError(f"Unsupported template {current['template']}")


def compare_swiftui_capture(current: dict[str, Any], baseline: dict[str, Any]) -> dict[str, Any]:
    current_metrics = current["metrics"]
    baseline_metrics = baseline["metrics"]
    current_swiftui = current_metrics.get("swiftui_updates", {})
    baseline_swiftui = baseline_metrics.get("swiftui_updates", {})

    return {
        "scenario": current["scenario"],
        "template": current["template"],
        "metrics": {
            "total_updates": delta_block(
                current_swiftui.get("total_count", 0),
                baseline_swiftui.get("total_count", 0),
            ),
            "body_updates": delta_block(
                current_swiftui.get("body_update_count", 0),
                baseline_swiftui.get("body_update_count", 0),
            ),
            "p95_update_ms": delta_block(
                current_swiftui.get("duration_ms_p95", 0.0),
                baseline_swiftui.get("duration_ms_p95", 0.0),
            ),
            "max_update_ms": delta_block(
                ns_to_ms(current_swiftui.get("duration_ns_max", 0)),
                ns_to_ms(baseline_swiftui.get("duration_ns_max", 0)),
            ),
            "hitches": delta_block(
                current_metrics.get("hitches", {}).get("count", 0),
                baseline_metrics.get("hitches", {}).get("count", 0),
            ),
            "potential_hangs": delta_block(
                current_metrics.get("potential_hangs", {}).get("count", 0),
                baseline_metrics.get("potential_hangs", {}).get("count", 0),
            ),
        },
        "top_frames": {
            "baseline": baseline_metrics.get("top_frames", [])[:5],
            "current": current_metrics.get("top_frames", [])[:5],
        },
    }


def compare_allocations_capture(current: dict[str, Any], baseline: dict[str, Any]) -> dict[str, Any]:
    current_rows = current["metrics"].get("allocations", {}).get("summary_rows", {})
    baseline_rows = baseline["metrics"].get("allocations", {}).get("summary_rows", {})
    comparisons = {}
    for category in ALLOCATION_SUMMARY_CATEGORIES:
        current_row = current_rows.get(category, {})
        baseline_row = baseline_rows.get(category, {})
        comparisons[category] = {
            "persistent_bytes": delta_block(
                current_row.get("persistent_bytes", 0),
                baseline_row.get("persistent_bytes", 0),
            ),
            "total_bytes": delta_block(
                current_row.get("total_bytes", 0),
                baseline_row.get("total_bytes", 0),
            ),
            "count_events": delta_block(
                current_row.get("count_events", 0),
                baseline_row.get("count_events", 0),
            ),
        }

    return {
        "scenario": current["scenario"],
        "template": current["template"],
        "metrics": comparisons,
    }


def delta_block(current: int | float, baseline: int | float) -> dict[str, int | float]:
    if isinstance(current, float) or isinstance(baseline, float):
        delta = round(current - baseline, 4)
    else:
        delta = current - baseline
    return {"baseline": baseline, "current": current, "delta": delta}


def ns_to_ms(value: int) -> float:
    return round(value / 1_000_000, 4)


def render_markdown(comparison: dict[str, Any]) -> str:
    lines = [
        f"# Instruments Comparison: {comparison['baseline_label']} -> {comparison['current_label']}",
        "",
        f"- Baseline: `{comparison['baseline_created_at_utc']}`",
        f"- Current: `{comparison['current_created_at_utc']}`",
        "",
    ]

    for item in comparison.get("comparisons", []):
        lines.append(f"## {item['scenario']} ({item['template']})")
        lines.append("")
        if item["template"] == "SwiftUI":
            lines.append("| Metric | Baseline | Current | Delta |")
            lines.append("| --- | ---: | ---: | ---: |")
            for metric_name, values in item["metrics"].items():
                lines.append(
                    f"| {metric_name} | {values['baseline']} | {values['current']} | {values['delta']} |"
                )
            baseline_frames = ", ".join(frame["name"] for frame in item.get("top_frames", {}).get("baseline", [])) or "n/a"
            current_frames = ", ".join(frame["name"] for frame in item.get("top_frames", {}).get("current", [])) or "n/a"
            lines.append("")
            lines.append(f"- Baseline hot frames: {baseline_frames}")
            lines.append(f"- Current hot frames: {current_frames}")
        else:
            lines.append("| Category | Metric | Baseline | Current | Delta |")
            lines.append("| --- | --- | ---: | ---: | ---: |")
            for category, metrics in item["metrics"].items():
                for metric_name, values in metrics.items():
                    lines.append(
                        f"| {category} | {metric_name} | {values['baseline']} | {values['current']} | {values['delta']} |"
                    )
        lines.append("")

    if not comparison.get("comparisons"):
        lines.append("No overlapping scenario/template captures were found between the two runs.")
        lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    raise SystemExit(main())
