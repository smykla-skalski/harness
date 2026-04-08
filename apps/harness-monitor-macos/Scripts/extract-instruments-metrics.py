#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


SWIFTUI_SCHEMA_XPATHS = {
    "swiftui-updates": '/trace-toc/run[@number="1"]/data/table[@schema="swiftui-updates"]',
    "swiftui-update-groups": '/trace-toc/run[@number="1"]/data/table[@schema="swiftui-update-groups"]',
    "swiftui-causes": '/trace-toc/run[@number="1"]/data/table[@schema="swiftui-causes"]',
    "hitches": '/trace-toc/run[@number="1"]/data/table[@schema="hitches"]',
    "potential-hangs": '/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs"]',
    "time-profile": '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]',
}
ALLOCATIONS_XPATH = (
    '/trace-toc/run[@number="1"]/tracks/track[@name="Allocations"]/details/detail[@name="Statistics"]'
)
ALLOCATION_SUMMARY_CATEGORIES = [
    "All Heap & Anonymous VM",
    "All Heap Allocations",
    "All Anonymous VM",
    "All VM Regions",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export and normalize Instruments traces for the Harness Monitor audit harness."
    )
    parser.add_argument("--run-dir", required=True, help="Run directory created by run-instruments-audit.sh")
    parser.add_argument(
        "--xctrace",
        default="xcrun xctrace",
        help="xctrace launcher command. Default: 'xcrun xctrace'",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    run_dir = Path(args.run_dir).resolve()
    manifest_path = run_dir / "manifest.json"
    if not manifest_path.exists():
        raise SystemExit(f"manifest.json not found under {run_dir}")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    captures = manifest.get("captures", [])
    exports_root = run_dir / "exports"
    metrics_root = run_dir / "metrics"
    exports_root.mkdir(parents=True, exist_ok=True)
    metrics_root.mkdir(parents=True, exist_ok=True)

    xctrace_cmd = args.xctrace.split()
    summary_captures: list[dict[str, Any]] = []
    top_offenders_by_scenario: dict[str, dict[str, Any]] = {}

    for capture in captures:
        trace_path = run_dir / capture["trace_relpath"]
        capture_export_dir = exports_root / capture["template"].lower().replace(" ", "-") / capture["scenario"]
        capture_export_dir.mkdir(parents=True, exist_ok=True)
        metrics = export_and_parse_capture(
            xctrace_cmd=xctrace_cmd,
            trace_path=trace_path,
            capture=capture,
            export_dir=capture_export_dir,
        )

        scenario_root = metrics_root / capture["scenario"]
        scenario_root.mkdir(parents=True, exist_ok=True)
        template_slug = capture["template"].lower().replace(" ", "-")
        (scenario_root / f"{template_slug}.json").write_text(
            json.dumps(metrics, indent=2, sort_keys=True),
            encoding="utf-8",
        )

        scenario_offenders = top_offenders_by_scenario.setdefault(capture["scenario"], {})
        scenario_offenders[capture["template"]] = metrics.get("top_offenders", [])

        capture_summary = {
            "scenario": capture["scenario"],
            "template": capture["template"],
            "duration_seconds": capture["duration_seconds"],
            "trace_relpath": capture["trace_relpath"],
            "exit_status": capture["exit_status"],
            "end_reason": capture["end_reason"],
            "metrics": metrics,
        }
        summary_captures.append(capture_summary)

    for scenario, offenders in top_offenders_by_scenario.items():
        (metrics_root / scenario / "top-offenders.json").write_text(
            json.dumps(offenders, indent=2, sort_keys=True),
            encoding="utf-8",
        )

    summary = {
        "label": manifest.get("label"),
        "created_at_utc": manifest.get("created_at_utc"),
        "git": manifest.get("git"),
        "system": manifest.get("system"),
        "targets": manifest.get("targets"),
        "selected_scenarios": manifest.get("selected_scenarios"),
        "captures": summary_captures,
    }
    (run_dir / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    write_summary_csv(run_dir / "summary.csv", summary_captures)
    return 0


def export_and_parse_capture(
    *,
    xctrace_cmd: list[str],
    trace_path: Path,
    capture: dict[str, Any],
    export_dir: Path,
) -> dict[str, Any]:
    toc_path = export_dir / "toc.xml"
    export_xml(xctrace_cmd, trace_path, ["--toc"], toc_path)
    toc_root = ET.parse(toc_path).getroot()
    available_schemas = discover_available_schemas(toc_root)
    available_alloc_details = discover_allocation_details(toc_root)

    if capture["template"] == "SwiftUI":
        metrics = parse_swiftui_capture(
            xctrace_cmd=xctrace_cmd,
            trace_path=trace_path,
            export_dir=export_dir,
            available_schemas=available_schemas,
        )
    elif capture["template"] == "Allocations":
        metrics = parse_allocations_capture(
            xctrace_cmd=xctrace_cmd,
            trace_path=trace_path,
            export_dir=export_dir,
            available_alloc_details=available_alloc_details,
        )
    else:
        raise ValueError(f"Unsupported template {capture['template']}")

    metrics["available_schemas"] = sorted(filter(None, available_schemas))
    return metrics


def parse_swiftui_capture(
    *,
    xctrace_cmd: list[str],
    trace_path: Path,
    export_dir: Path,
    available_schemas: set[str | None],
) -> dict[str, Any]:
    exports: dict[str, Path] = {}
    for schema_name, xpath in SWIFTUI_SCHEMA_XPATHS.items():
        if schema_name not in available_schemas:
            continue
        output_path = export_dir / f"{schema_name}.xml"
        export_xml(xctrace_cmd, trace_path, ["--xpath", xpath], output_path)
        exports[schema_name] = output_path

    updates_metrics = parse_swiftui_updates(exports.get("swiftui-updates"))
    update_groups_metrics = parse_swiftui_update_groups(exports.get("swiftui-update-groups"))
    causes_metrics = parse_swiftui_causes(exports.get("swiftui-causes"))
    hitches_metrics = parse_event_table(exports.get("hitches"))
    hangs_metrics = parse_event_table(exports.get("potential-hangs"))
    time_profile_metrics = parse_time_profile(exports.get("time-profile"), trace_path)

    return {
        "swiftui_updates": updates_metrics["summary"],
        "swiftui_update_groups": update_groups_metrics["summary"],
        "swiftui_causes": causes_metrics["summary"],
        "hitches": hitches_metrics,
        "potential_hangs": hangs_metrics,
        "time_profile": time_profile_metrics["summary"],
        "top_offenders": updates_metrics["top_offenders"],
        "top_update_groups": update_groups_metrics["top_groups"],
        "top_causes": causes_metrics["top_causes"],
        "top_frames": time_profile_metrics["top_frames"],
    }


def parse_allocations_capture(
    *,
    xctrace_cmd: list[str],
    trace_path: Path,
    export_dir: Path,
    available_alloc_details: set[str | None],
) -> dict[str, Any]:
    rows: dict[str, dict[str, int]] = {}
    top_offenders: list[dict[str, Any]] = []

    if "Statistics" in available_alloc_details:
        statistics_path = export_dir / "allocations-statistics.xml"
        export_xml(
            xctrace_cmd,
            trace_path,
            ["--xpath", ALLOCATIONS_XPATH],
            statistics_path,
        )
        rows, top_offenders = parse_allocations_statistics(statistics_path)

    summary_rows = {
        category: rows.get(category, {})
        for category in ALLOCATION_SUMMARY_CATEGORIES
    }

    return {
        "allocations": {
            "summary_rows": summary_rows,
            "category_count": len(rows),
        },
        "top_offenders": top_offenders,
    }


def parse_swiftui_update_groups(path: Path | None) -> dict[str, Any]:
    if path is None or not path.exists():
        return {
            "summary": empty_update_groups_summary(),
            "top_groups": [],
        }

    node, id_map, schema_columns = load_query_node(path)
    durations_ns: list[int] = []
    label_counts: Counter[str] = Counter()
    label_totals: dict[str, dict[str, int]] = defaultdict(lambda: {"count": 0, "duration_ns": 0})

    for row in iter_rows(node):
        record = row_to_record(row, id_map, schema_columns)
        label = normalize_text(record.get("label"))
        duration_ns = parse_int(record.get("duration")) or 0
        durations_ns.append(duration_ns)
        label_counts[label] += 1
        label_totals[label]["count"] += 1
        label_totals[label]["duration_ns"] += duration_ns

    top_groups = [
        {
            "label": label,
            "count": values["count"],
            "duration_ns": values["duration_ns"],
            "duration_ms": ns_to_ms(values["duration_ns"]),
        }
        for label, values in sorted(
            label_totals.items(),
            key=lambda item: (item[1]["duration_ns"], item[1]["count"]),
            reverse=True,
        )[:12]
    ]

    return {
        "summary": {
            "total_count": sum(label_counts.values()),
            "duration_ns_total": sum(durations_ns),
            "duration_ns_max": max(durations_ns, default=0),
            "duration_ms_p95": ns_to_ms(percentile(durations_ns, 95)),
            "label_counts": dict(label_counts.most_common(12)),
        },
        "top_groups": top_groups,
    }


def parse_swiftui_causes(path: Path | None) -> dict[str, Any]:
    if path is None or not path.exists():
        return {
            "summary": empty_swiftui_causes_summary(),
            "top_causes": [],
        }

    node, id_map, schema_columns = load_query_node(path)
    label_counts: Counter[str] = Counter()
    source_counts: Counter[str] = Counter()
    destination_counts: Counter[str] = Counter()
    value_type_counts: Counter[str] = Counter()
    property_counts: Counter[str] = Counter()
    cause_counts: Counter[tuple[str, str, str]] = Counter()

    for row in iter_rows(node):
        record = row_to_record(row, id_map, schema_columns)
        label = normalize_text(record.get("label"))
        source = normalize_text(record.get("source-node"))
        destination = normalize_text(record.get("destination-node"))
        value_type = normalize_text(record.get("value-type"))
        changed_properties = normalize_text(record.get("changed-properties"))

        label_counts[label] += 1
        source_counts[source] += 1
        destination_counts[destination] += 1
        if value_type != "<unknown>":
            value_type_counts[value_type] += 1
        if changed_properties != "<unknown>":
            property_counts[changed_properties] += 1
        cause_counts[(source, destination, label)] += 1

    top_causes = [
        {
            "source_node": source,
            "destination_node": destination,
            "label": label,
            "count": count,
        }
        for (source, destination, label), count in cause_counts.most_common(15)
    ]

    return {
        "summary": {
            "total_count": sum(label_counts.values()),
            "label_counts": dict(label_counts.most_common(12)),
            "source_node_counts": dict(source_counts.most_common(12)),
            "destination_node_counts": dict(destination_counts.most_common(12)),
            "value_type_counts": dict(value_type_counts.most_common(12)),
            "changed_property_counts": dict(property_counts.most_common(12)),
        },
        "top_causes": top_causes,
    }


def export_xml(xctrace_cmd: list[str], trace_path: Path, extra_args: list[str], output_path: Path) -> None:
    temp_root = output_path.parent / ".tmp"
    temp_root.mkdir(parents=True, exist_ok=True)
    command = [*xctrace_cmd, "export", "--input", str(trace_path), *extra_args]
    env = dict(os.environ)
    env["TMPDIR"] = f"{temp_root}{os.sep}"
    result = subprocess.run(command, capture_output=True, env=env)
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"xctrace export failed for {trace_path}: {stderr}")
    output_path.write_bytes(result.stdout)


def parse_swiftui_updates(path: Path | None) -> dict[str, Any]:
    if path is None or not path.exists():
        return {
            "summary": empty_swiftui_summary(),
            "top_offenders": [],
        }

    node, id_map, schema_columns = load_query_node(path)
    rows = list(iter_rows(node))
    update_type_counts: Counter[str] = Counter()
    severity_counts: Counter[str] = Counter()
    category_counts: Counter[str] = Counter()
    durations_ns: list[int] = []
    offender_totals: dict[tuple[str, str, str], dict[str, Any]] = defaultdict(
        lambda: {"count": 0, "duration_ns": 0, "allocations": 0}
    )
    total_allocations = 0
    body_update_count = 0

    for row in rows:
        record = row_to_record(row, id_map, schema_columns)
        duration_ns = parse_int(record.get("duration"))
        allocations = parse_int(record.get("allocations"))
        update_type = normalize_text(record.get("update-type"))
        severity = normalize_text(record.get("severity"))
        category = normalize_text(record.get("category"))
        description = normalize_text(record.get("description"))
        module = normalize_text(record.get("module"))
        view_name = normalize_text(record.get("view-name"))

        if duration_ns is not None:
            durations_ns.append(duration_ns)
        total_allocations += allocations or 0
        update_type_counts[update_type] += 1
        severity_counts[severity] += 1
        category_counts[category] += 1

        if "body" in update_type.lower() or "body" in description.lower():
            body_update_count += 1

        offender_key = (description, module, view_name)
        offender = offender_totals[offender_key]
        offender["count"] += 1
        offender["duration_ns"] += duration_ns or 0
        offender["allocations"] += allocations or 0

    top_offenders = [
        {
            "description": description,
            "module": module,
            "view_name": view_name,
            "count": values["count"],
            "duration_ns": values["duration_ns"],
            "duration_ms": ns_to_ms(values["duration_ns"]),
            "allocations": values["allocations"],
        }
        for (description, module, view_name), values in sorted(
            offender_totals.items(),
            key=lambda item: (item[1]["duration_ns"], item[1]["count"]),
            reverse=True,
        )[:15]
    ]

    summary = {
        "total_count": len(rows),
        "body_update_count": body_update_count,
        "duration_ns_total": sum(durations_ns),
        "duration_ns_max": max(durations_ns, default=0),
        "duration_ms_p95": ns_to_ms(percentile(durations_ns, 95)),
        "allocations_total": total_allocations,
        "update_type_counts": dict(update_type_counts),
        "severity_counts": dict(severity_counts),
        "category_counts": dict(category_counts),
    }
    return {"summary": summary, "top_offenders": top_offenders}


def parse_event_table(path: Path | None) -> dict[str, Any]:
    if path is None or not path.exists():
        return {"count": 0, "duration_ns_total": 0, "duration_ns_max": 0}

    node, id_map, schema_columns = load_query_node(path)
    durations_ns: list[int] = []
    labels: Counter[str] = Counter()

    for row in iter_rows(node):
        record = row_to_record(row, id_map, schema_columns)
        duration_ns = parse_int(record.get("duration"))
        label = normalize_text(
            record.get("narrative-description")
            or record.get("label")
            or record.get("description")
        )
        if duration_ns is not None:
            durations_ns.append(duration_ns)
        if label:
            labels[label] += 1

    return {
        "count": len(durations_ns) if durations_ns else sum(labels.values()),
        "duration_ns_total": sum(durations_ns),
        "duration_ns_max": max(durations_ns, default=0),
        "top_labels": [dict(label=label, count=count) for label, count in labels.most_common(8)],
    }


def parse_time_profile(path: Path | None, trace_path: Path) -> dict[str, Any]:
    if path is None or not path.exists():
        return {"summary": {"sample_count": 0}, "top_frames": []}

    node, id_map, _ = load_query_node(path)
    app_bundle_tokens = ("Harness Monitor.app", "Harness Monitor UI Testing.app")
    app_owned: Counter[str] = Counter()
    symbolic: Counter[str] = Counter()
    sample_count = 0

    for row in iter_rows(node):
        sample_count += 1
        backtrace = resolve_backtrace(row, id_map)
        if backtrace is None:
            continue

        first_symbolic = None
        first_app_owned = None
        for frame in iter_backtrace_frames(backtrace, id_map):
            name = frame.get("name") or ""
            binary_path = frame.get("binary_path")
            if not is_symbolic_frame(name):
                continue
            first_symbolic = first_symbolic or name
            if binary_path and any(token in binary_path for token in app_bundle_tokens):
                first_app_owned = name
                break

        if first_symbolic:
            symbolic[first_symbolic] += 1
        if first_app_owned:
            app_owned[first_app_owned] += 1

    top_frames = [
        dict(name=name, samples=count)
        for name, count in (app_owned or symbolic).most_common(12)
    ]
    return {
        "summary": {
            "sample_count": sample_count,
            "app_owned_frame_count": sum(app_owned.values()),
            "fallback_symbolic_frame_count": sum(symbolic.values()),
        },
        "top_frames": top_frames,
    }


def parse_allocations_statistics(path: Path) -> tuple[dict[str, dict[str, int]], list[dict[str, Any]]]:
    root = ET.parse(path).getroot()
    rows: dict[str, dict[str, int]] = {}
    for row in root.findall(".//row"):
        category = row.attrib.get("category", "").strip()
        if not category:
            continue
        rows[category] = {
            key.replace("-", "_"): int(value)
            for key, value in row.attrib.items()
            if key != "category" and value.isdigit()
        }

    top_offenders = [
        {
            "category": category,
            "persistent_bytes": values.get("persistent_bytes", 0),
            "total_bytes": values.get("total_bytes", 0),
            "count_events": values.get("count_events", 0),
        }
        for category, values in sorted(
            rows.items(),
            key=lambda item: (
                item[1].get("persistent_bytes", 0),
                item[1].get("total_bytes", 0),
                item[1].get("count_events", 0),
            ),
            reverse=True,
        )[:15]
    ]
    return rows, top_offenders


def discover_available_schemas(toc_root: ET.Element) -> set[str]:
    return {
        table.get("schema", "").strip()
        for table in toc_root.findall(".//table")
        if table.get("schema", "").strip()
    }


def discover_allocation_details(toc_root: ET.Element) -> set[str]:
    return {
        detail.get("name", "").strip()
        for detail in toc_root.findall('.//track[@name="Allocations"]/details/detail')
        if detail.get("name", "").strip()
    }


def load_query_node(path: Path) -> tuple[ET.Element, dict[str, ET.Element], list[str]]:
    root = ET.parse(path).getroot()
    node = root.find(".//node")
    if node is None:
        raise RuntimeError(f"No <node> element found in {path}")
    id_map = {element.attrib["id"]: element for element in node.iter() if "id" in element.attrib}
    schema = node.find("schema")
    schema_columns = []
    if schema is not None:
        schema_columns = [
            column.findtext("mnemonic", default="")
            for column in schema.findall("col")
        ]
    return node, id_map, schema_columns


def iter_rows(node: ET.Element) -> list[ET.Element]:
    return node.findall("row")


def row_to_record(
    row: ET.Element,
    id_map: dict[str, ET.Element],
    schema_columns: list[str],
) -> dict[str, str]:
    record: dict[str, str] = {}
    for index, child in enumerate(list(row)):
        key = schema_columns[index] if index < len(schema_columns) and schema_columns[index] else child.tag
        record[key] = resolved_text(child, id_map)
    return record


def resolve_backtrace(row: ET.Element, id_map: dict[str, ET.Element]) -> ET.Element | None:
    for child in list(row):
        resolved = dereference(child, id_map)
        if resolved is not None and resolved.tag == "backtrace":
            return resolved
    return None


def iter_backtrace_frames(backtrace: ET.Element, id_map: dict[str, ET.Element]) -> list[dict[str, str]]:
    frames: list[dict[str, str]] = []
    for frame in backtrace.findall("frame"):
        resolved = dereference(frame, id_map)
        if resolved is None:
            continue
        binary = resolved.find("binary")
        if binary is not None and "ref" in binary.attrib:
            binary = dereference(binary, id_map)
        frames.append(
            {
                "name": resolved.attrib.get("name", ""),
                "binary_path": "" if binary is None else binary.attrib.get("path", ""),
            }
        )
    return frames


def dereference(element: ET.Element, id_map: dict[str, ET.Element]) -> ET.Element | None:
    if "ref" not in element.attrib:
        return element
    target = id_map.get(element.attrib["ref"])
    if target is None:
        return None
    if "ref" in target.attrib:
        return dereference(target, id_map)
    return target


def resolved_text(element: ET.Element, id_map: dict[str, ET.Element]) -> str:
    resolved = dereference(element, id_map)
    if resolved is None:
        return ""
    text = (resolved.text or "").strip()
    if text:
        return text
    fmt = resolved.attrib.get("fmt", "")
    if fmt:
        return fmt
    if resolved.tag == "backtrace":
        return resolved.attrib.get("fmt", "")
    children = list(resolved)
    if len(children) == 1:
        return resolved_text(children[0], id_map)
    return ""


def empty_swiftui_summary() -> dict[str, Any]:
    return {
        "total_count": 0,
        "body_update_count": 0,
        "duration_ns_total": 0,
        "duration_ns_max": 0,
        "duration_ms_p95": 0.0,
        "allocations_total": 0,
        "update_type_counts": {},
        "severity_counts": {},
        "category_counts": {},
    }


def empty_update_groups_summary() -> dict[str, Any]:
    return {
        "total_count": 0,
        "duration_ns_total": 0,
        "duration_ns_max": 0,
        "duration_ms_p95": 0.0,
        "label_counts": {},
    }


def empty_swiftui_causes_summary() -> dict[str, Any]:
    return {
        "total_count": 0,
        "label_counts": {},
        "source_node_counts": {},
        "destination_node_counts": {},
        "value_type_counts": {},
        "changed_property_counts": {},
    }


def percentile(values: list[int], pct: int) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    rank = max(0, math.ceil((pct / 100) * len(ordered)) - 1)
    return ordered[rank]


def parse_int(raw: str | None) -> int | None:
    if raw is None:
        return None
    cleaned = raw.replace(",", "").strip()
    if not cleaned:
        return None
    try:
        return int(float(cleaned))
    except ValueError:
        return None


def normalize_text(raw: str | None) -> str:
    return (raw or "").strip() or "<unknown>"


def ns_to_ms(value: int) -> float:
    return round(value / 1_000_000, 4)


def is_symbolic_frame(name: str) -> bool:
    if not name or name == "<deduplicated_symbol>":
        return False
    if name.startswith("0x"):
        return False
    return True


def write_summary_csv(path: Path, captures: list[dict[str, Any]]) -> None:
    fieldnames = [
        "scenario",
        "template",
        "duration_seconds",
        "exit_status",
        "end_reason",
        "swiftui_total_updates",
        "swiftui_body_updates",
        "swiftui_p95_ms",
        "swiftui_max_ms",
        "swiftui_update_group_p95_ms",
        "swiftui_top_group_label",
        "swiftui_top_cause_source",
        "hitches",
        "potential_hangs",
        "alloc_all_heap_and_vm_persistent_bytes",
        "alloc_all_heap_and_vm_total_bytes",
        "alloc_all_vm_regions_persistent_bytes",
        "alloc_all_vm_regions_total_bytes",
    ]
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for capture in captures:
            metrics = capture["metrics"]
            swiftui = metrics.get("swiftui_updates", {})
            update_groups = metrics.get("swiftui_update_groups", {})
            causes = metrics.get("swiftui_causes", {})
            allocations = metrics.get("allocations", {}).get("summary_rows", {})
            heap_vm = allocations.get("All Heap & Anonymous VM", {})
            vm_regions = allocations.get("All VM Regions", {})
            top_group_label = next(iter(update_groups.get("label_counts", {})), "")
            top_cause_source = next(iter(causes.get("source_node_counts", {})), "")
            writer.writerow(
                {
                    "scenario": capture["scenario"],
                    "template": capture["template"],
                    "duration_seconds": capture["duration_seconds"],
                    "exit_status": capture["exit_status"],
                    "end_reason": capture["end_reason"],
                    "swiftui_total_updates": swiftui.get("total_count", ""),
                    "swiftui_body_updates": swiftui.get("body_update_count", ""),
                    "swiftui_p95_ms": swiftui.get("duration_ms_p95", ""),
                    "swiftui_max_ms": ns_to_ms(swiftui.get("duration_ns_max", 0))
                    if swiftui
                    else "",
                    "swiftui_update_group_p95_ms": update_groups.get("duration_ms_p95", ""),
                    "swiftui_top_group_label": top_group_label,
                    "swiftui_top_cause_source": top_cause_source,
                    "hitches": metrics.get("hitches", {}).get("count", ""),
                    "potential_hangs": metrics.get("potential_hangs", {}).get("count", ""),
                    "alloc_all_heap_and_vm_persistent_bytes": heap_vm.get("persistent_bytes", ""),
                    "alloc_all_heap_and_vm_total_bytes": heap_vm.get("total_bytes", ""),
                    "alloc_all_vm_regions_persistent_bytes": vm_regions.get("persistent_bytes", ""),
                    "alloc_all_vm_regions_total_bytes": vm_regions.get("total_bytes", ""),
                }
            )


if __name__ == "__main__":
    sys.exit(main())
