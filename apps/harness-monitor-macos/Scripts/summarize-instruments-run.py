#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Print a compact recap for a Harness Monitor Instruments audit run."
    )
    parser.add_argument("--run-dir", required=True, help="Run directory created by run-instruments-audit.sh")
    parser.add_argument(
        "--top-count",
        type=int,
        default=5,
        help="Maximum number of top offenders to print for each scenario. Default: 5",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    run_dir = Path(args.run_dir).resolve()
    summary = load_json(run_dir / "summary.json")
    comparison = load_optional_json(run_dir / "comparison.json")
    print(render_recap(summary, comparison, top_count=max(args.top_count, 0)))
    return 0


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def load_optional_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    return load_json(path)


def comparison_index(comparison: dict[str, Any] | None) -> dict[tuple[str, str], dict[str, Any]]:
    if comparison is None:
        return {}
    return {
        (item["scenario"], item["template"]): item
        for item in comparison.get("comparisons", [])
    }


def render_recap(
    summary: dict[str, Any],
    comparison: dict[str, Any] | None,
    *,
    top_count: int,
) -> str:
    lines = [
        "Run recap:",
        f"- label={summary.get('label', 'unknown')}",
        f"- run_id={summary.get('created_at_utc', 'unknown')}",
    ]

    git = summary.get("git") or {}
    commit = git.get("commit")
    dirty = git.get("dirty")
    if commit is not None:
        lines.append(f"- commit={commit} dirty={dirty}")

    deltas = comparison_index(comparison)

    for capture in summary.get("captures", []):
        scenario = capture.get("scenario", "unknown")
        template = capture.get("template", "unknown")
        lines.extend(render_capture(capture, deltas.get((scenario, template)), top_count=top_count))

    return "\n".join(lines)


def render_capture(
    capture: dict[str, Any],
    comparison: dict[str, Any] | None,
    *,
    top_count: int,
) -> list[str]:
    template = capture.get("template", "unknown")
    if template == "SwiftUI":
        return render_swiftui_capture(capture, comparison, top_count=top_count)
    if template == "Allocations":
        return render_allocations_capture(capture)
    return [f"- {capture.get('scenario', 'unknown')} [{template}] unsupported capture summary"]


def render_swiftui_capture(
    capture: dict[str, Any],
    comparison: dict[str, Any] | None,
    *,
    top_count: int,
) -> list[str]:
    metrics = capture.get("metrics") or {}
    swiftui = metrics.get("swiftui_updates") or {}
    hitches = (metrics.get("hitches") or {}).get("count", 0)
    hangs = (metrics.get("potential_hangs") or {}).get("count", 0)
    max_ms = ns_to_ms(swiftui.get("duration_ns_max", 0))
    line = (
        f"- {capture.get('scenario', 'unknown')} [SwiftUI]: "
        f"total_updates={swiftui.get('total_count', 0)} "
        f"body_updates={swiftui.get('body_update_count', 0)} "
        f"p95_ms={format_float(swiftui.get('duration_ms_p95', 0.0))} "
        f"max_ms={format_float(max_ms)} "
        f"hitches={hitches} "
        f"potential_hangs={hangs}"
    )

    if comparison is not None:
        delta_metrics = comparison.get("metrics") or {}
        line += (
            f" d_total_updates={delta_value(delta_metrics.get('total_updates'))} "
            f"d_body_updates={delta_value(delta_metrics.get('body_updates'))} "
            f"d_hitches={delta_value(delta_metrics.get('hitches'))} "
            f"d_potential_hangs={delta_value(delta_metrics.get('potential_hangs'))}"
        )

    lines = [line]
    offenders = metrics.get("top_offenders") or []
    for index, offender in enumerate(offenders[:top_count], start=1):
        description = offender.get("description", "<unknown>")
        view_name = offender.get("view_name", "<unknown>")
        duration_ms = format_float(offender.get("duration_ms", 0.0))
        count = offender.get("count", 0)
        lines.append(
            f"  {index}. {description} | {view_name} | duration_ms={duration_ms} | count={count}"
        )
    return lines


def render_allocations_capture(capture: dict[str, Any]) -> list[str]:
    metrics = capture.get("metrics") or {}
    rows = ((metrics.get("allocations") or {}).get("summary_rows")) or {}
    selected_categories = ["All Heap & Anonymous VM", "All VM Regions"]
    parts = []
    for category in selected_categories:
        row = rows.get(category) or {}
        if not row:
            continue
        parts.append(
            f"{category}: persistent_bytes={row.get('persistent_bytes', 0)} total_bytes={row.get('total_bytes', 0)}"
        )

    if not parts:
        parts.append("no allocation summary rows")
    return [f"- {capture.get('scenario', 'unknown')} [Allocations]: " + " ; ".join(parts)]


def delta_value(block: dict[str, Any] | None) -> str:
    if not block:
        return "n/a"
    value = block.get("delta", "n/a")
    if isinstance(value, float):
        return format_float(value)
    return str(value)


def ns_to_ms(value: int | float) -> float:
    return float(value) / 1_000_000


def format_float(value: int | float) -> str:
    return f"{float(value):.4f}"


if __name__ == "__main__":
    raise SystemExit(main())
