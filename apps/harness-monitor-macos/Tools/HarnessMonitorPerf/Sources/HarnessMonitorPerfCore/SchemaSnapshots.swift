import Foundation

typealias RawSchema = [String: Any]

public enum SchemaSnapshots {
    static let schemaDraft = "https://json-schema.org/draft/2020-12/schema"
    static let schemaBaseID =
        "https://github.com/smykla-skalski/harness/apps/harness-monitor-macos/Tools/HarnessMonitorPerf/Schemas/"

    public static func write(to outputDir: URL) throws {
        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )
        for (filename, schema) in schemas {
            try renderedData(for: schema).write(
                to: outputDir.appendingPathComponent(filename),
                options: .atomic
            )
        }
    }

    public static func renderedSchemas() throws -> [String: String] {
        try schemas.reduce(into: [String: String]()) { result, entry in
            result[entry.filename] = String(
                decoding: try renderedData(for: entry.schema),
                as: UTF8.self
            )
        }
    }

    private static var schemas: [(filename: String, schema: RawSchema)] {
        [
            ("manifest.schema.json", manifestSchema()),
            ("summary.schema.json", summarySchema()),
            ("comparison.schema.json", comparisonSchema()),
        ]
    }

    private static func renderedData(for schema: RawSchema) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(JSONValue.from(schema))
        data.append(0x0A)
        return data
    }

    private static func manifestSchema() -> RawSchema {
        document(
            fileName: "manifest.schema.json",
            title: "Harness Monitor audit manifest",
            required: [
                "label",
                "run_id",
                "created_at_utc",
                "git",
                "system",
                "targets",
                "build_provenance",
                "templates",
                "default_environment",
                "launch_arguments",
                "selected_scenarios",
                "captures",
            ],
            properties: [
                "label": scalar("string"),
                "run_id": scalar("string"),
                "created_at_utc": scalar("string"),
                "git": object(
                    required: ["commit", "dirty", "workspace_fingerprint", "build_started_at_utc"],
                    properties: [
                        "commit": scalar("string"),
                        "dirty": scalar("boolean"),
                        "workspace_fingerprint": scalar("string"),
                        "build_started_at_utc": scalar("string"),
                    ]
                ),
                "system": object(
                    required: [
                        "xcode_version",
                        "xctrace_version",
                        "macos_version",
                        "macos_build",
                        "arch",
                    ],
                    properties: [
                        "xcode_version": scalar("string"),
                        "xctrace_version": scalar("string"),
                        "macos_version": scalar("string"),
                        "macos_build": scalar("string"),
                        "arch": scalar("string"),
                    ]
                ),
                "targets": object(
                    required: [
                        "project",
                        "shipping_scheme",
                        "host_scheme",
                        "shipping_app_path",
                        "host_app_path",
                        "host_bundle_id",
                        "staged_host_app_path",
                        "staged_host_binary_path",
                        "staged_host_bundle_id",
                    ],
                    properties: [
                        "project": scalar("string"),
                        "shipping_scheme": scalar("string"),
                        "host_scheme": scalar("string"),
                        "shipping_app_path": scalar("string"),
                        "host_app_path": scalar("string"),
                        "host_bundle_id": scalar("string"),
                        "staged_host_app_path": scalar("string"),
                        "staged_host_binary_path": scalar("string"),
                        "staged_host_bundle_id": scalar("string"),
                    ]
                ),
                "build_provenance": object(
                    required: ["audit_daemon_bundle", "host", "shipping"],
                    properties: [
                        "audit_daemon_bundle": object(
                            required: ["requested_skip", "mode", "cargo_target_dir"],
                            properties: [
                                "requested_skip": scalar("boolean"),
                                "mode": scalar("string"),
                                "cargo_target_dir": scalar("string"),
                            ]
                        ),
                        "host": object(
                            required: [
                                "embedded_commit",
                                "embedded_dirty",
                                "embedded_workspace_fingerprint",
                                "embedded_started_at_utc",
                                "binary_sha256",
                                "bundle_sha256",
                                "binary_mtime_utc",
                            ],
                            properties: [
                                "embedded_commit": scalar("string"),
                                "embedded_dirty": scalar("string"),
                                "embedded_workspace_fingerprint": scalar("string"),
                                "embedded_started_at_utc": scalar("string"),
                                "binary_sha256": scalar("string"),
                                "bundle_sha256": scalar("string"),
                                "binary_mtime_utc": scalar("string"),
                            ]
                        ),
                        "shipping": object(
                            required: [
                                "built",
                                "embedded_commit",
                                "embedded_dirty",
                                "embedded_workspace_fingerprint",
                                "embedded_started_at_utc",
                                "binary_sha256",
                                "bundle_sha256",
                                "binary_mtime_utc",
                            ],
                            properties: [
                                "built": scalar("boolean"),
                                "embedded_commit": scalar("string"),
                                "embedded_dirty": scalar("string"),
                                "embedded_workspace_fingerprint": scalar("string"),
                                "embedded_started_at_utc": scalar("string"),
                                "binary_sha256": scalar("string"),
                                "bundle_sha256": scalar("string"),
                                "binary_mtime_utc": scalar("string"),
                            ]
                        ),
                    ]
                ),
                "templates": object(
                    required: ["swiftui", "allocations"],
                    properties: [
                        "swiftui": array(items: scalar("string")),
                        "allocations": array(items: scalar("string")),
                    ]
                ),
                "default_environment": object(
                    additionalProperties: scalar("string")
                ),
                "launch_arguments": array(items: scalar("string")),
                "selected_scenarios": array(items: scalar("string")),
                "captures": array(
                    items: object(
                        required: [
                            "scenario",
                            "template",
                            "duration_seconds",
                            "trace_relpath",
                            "exit_status",
                            "end_reason",
                            "preview_scenario",
                            "launched_process_path",
                            "environment",
                            "launch_arguments",
                            "daemon_data_home_probe",
                            "metric_tiers",
                        ],
                        properties: [
                            "scenario": scalar("string"),
                            "template": scalar("string"),
                            "duration_seconds": scalar("integer"),
                            "trace_relpath": scalar("string"),
                            "app_trace_relpath": scalar("string", nullable: true),
                            "exit_status": scalar("integer"),
                            "end_reason": scalar("string"),
                            "preview_scenario": scalar("string"),
                            "launched_process_path": scalar("string"),
                            "environment": object(
                                additionalProperties: scalar("string")
                            ),
                            "launch_arguments": array(items: scalar("string")),
                            "daemon_data_home_probe": daemonDataHomeProbeSchema(),
                            "launch_metrics": launchMetricsSchema(),
                            "metric_tiers": metricTiersSchema(),
                        ]
                    )
                ),
            ]
        )
    }

    private static func summarySchema() -> RawSchema {
        document(
            fileName: "summary.schema.json",
            title: "Harness Monitor audit summary",
            required: ["captures"],
            properties: [
                "label": scalar("string", nullable: true),
                "created_at_utc": scalar("string", nullable: true),
                "git": [:],
                "system": [:],
                "targets": [:],
                "selected_scenarios": array(items: scalar("string"), nullable: true),
                "warnings": array(items: scalar("string"), nullable: true),
                "captures": array(
                    items: object(
                        required: ["scenario", "template"],
                        properties: [
                            "scenario": scalar("string"),
                            "template": scalar("string"),
                            "duration_seconds": scalar("number", nullable: true),
                            "trace_relpath": scalar("string", nullable: true),
                            "app_trace_relpath": scalar("string", nullable: true),
                            "exit_status": scalar("integer", nullable: true),
                            "end_reason": scalar("string", nullable: true),
                            "warnings": array(items: scalar("string"), nullable: true),
                            "launch_metrics": launchMetricsSchema(nullable: true),
                            "metric_tiers": metricTiersSchema(nullable: true),
                            "app_trace": summaryAppTraceSchema(nullable: true),
                            "findings": array(items: ref("#/$defs/finding"), nullable: true),
                            "metrics": [
                                "description":
                                    "Free-form extracted metrics payload keyed by template-specific extractor output.",
                            ],
                        ],
                        additionalProperties: true
                    )
                ),
            ],
            additionalProperties: true,
            defs: [
                "componentCount": componentCountSchema(),
                "finding": findingSchema(),
                "stepTiming": stepTimingSchema(),
            ]
        )
    }

    private static func comparisonSchema() -> RawSchema {
        document(
            fileName: "comparison.schema.json",
            title: "Harness Monitor audit comparison",
            required: [
                "missing_from_current",
                "missing_from_baseline",
                "current_missing_metrics",
                "baseline_missing_metrics",
                "comparisons",
            ],
            properties: [
                "current_label": scalar("string", nullable: true),
                "baseline_label": scalar("string", nullable: true),
                "current_created_at_utc": scalar("string", nullable: true),
                "baseline_created_at_utc": scalar("string", nullable: true),
                "missing_from_current": array(items: ref("#/$defs/missingCapture")),
                "missing_from_baseline": array(items: ref("#/$defs/missingCapture")),
                "current_missing_metrics": array(items: ref("#/$defs/missingCapture")),
                "baseline_missing_metrics": array(items: ref("#/$defs/missingCapture")),
                "comparisons": array(
                    items: object(
                        required: ["scenario", "template", "metrics"],
                        properties: [
                            "scenario": scalar("string"),
                            "template": scalar("string"),
                            "metrics": [
                                "description":
                                    "SwiftUI comparisons encode a flat metric->delta block map; allocations encode category->metric->delta block.",
                                "type": "object",
                            ],
                            "shared_metrics": object(
                                additionalProperties: ref("#/$defs/deltaBlock")
                            ),
                            "metric_tiers": metricTiersSchema(),
                            "baseline_findings": array(items: ref("#/$defs/finding")),
                            "current_findings": array(items: ref("#/$defs/finding")),
                            "new_findings": array(items: ref("#/$defs/finding")),
                            "resolved_findings": array(items: ref("#/$defs/finding")),
                            "app_trace": ref("#/$defs/appTraceComparison"),
                            "top_frames": object(
                                required: ["baseline", "current"],
                                properties: [
                                    "baseline": array(items: ref("#/$defs/frame")),
                                    "current": array(items: ref("#/$defs/frame")),
                                ]
                            ),
                        ]
                    )
                ),
            ],
            defs: [
                "missingCapture": missingCaptureSchema(),
                "deltaBlock": deltaBlockSchema(),
                "componentCount": componentCountSchema(),
                "appTraceSummary": comparisonAppTraceSummarySchema(),
                "appTraceComparison": appTraceComparisonSchema(),
                "frame": frameSchema(),
                "finding": findingSchema(),
            ]
        )
    }

}
