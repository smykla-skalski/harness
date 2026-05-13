import Foundation

public enum FieldTelemetryReportWriter {
    public struct Inputs: Codable, Equatable {
        public var label: String?
        public var metricKit: MetricKit?
        public var organizer: Organizer?
        public var appStoreConnectPerformanceAPI: AppStoreConnectPerformanceAPI?

        enum CodingKeys: String, CodingKey {
            case label
            case metricKit = "metric_kit"
            case organizer
            case appStoreConnectPerformanceAPI = "app_store_connect_performance_api"
        }
    }

    public struct MetricKit: Codable, Equatable {
        public var launchAppInitToReadyMilliseconds: Double?
        public var animationHitchTimeRatio: Double?
        public var hangCount: Int?
        public var peakMemoryMegabytes: Double?

        enum CodingKeys: String, CodingKey {
            case launchAppInitToReadyMilliseconds = "launch_app_init_to_ready_ms"
            case animationHitchTimeRatio = "animation_hitch_time_ratio"
            case hangCount = "hang_count"
            case peakMemoryMegabytes = "peak_memory_megabytes"
        }
    }

    public struct Organizer: Codable, Equatable {
        public var launchAppInitToReadyMilliseconds: Double?
        public var hitchRate: Double?
        public var hangRate: Double?
        public var memoryPeakMegabytes: Double?
        public var releaseComparisonNotes: [String]?

        enum CodingKeys: String, CodingKey {
            case launchAppInitToReadyMilliseconds = "launch_app_init_to_ready_ms"
            case hitchRate = "hitch_rate"
            case hangRate = "hang_rate"
            case memoryPeakMegabytes = "memory_peak_megabytes"
            case releaseComparisonNotes = "release_comparison_notes"
        }
    }

    public struct AppStoreConnectPerformanceAPI: Codable, Equatable {
        public var releaseComparisonNotes: [String]?

        enum CodingKeys: String, CodingKey {
            case releaseComparisonNotes = "release_comparison_notes"
        }
    }

    public struct Report: Codable, Equatable {
        public var label: String?
        public var signals: [Signal]
    }

    public struct Signal: Codable, Equatable {
        public var name: String
        public var observations: [Observation]
    }

    public struct Observation: Codable, Equatable {
        public var source: String
        public var metric: String
        public var value: Double?
        public var unit: String?
        public var note: String?
    }

    public static func build(inputs: Inputs) -> Report {
        var signals: [Signal] = []

        appendSignal(
            named: "launch_app_init_to_ready_ms",
            metricKit: inputs.metricKit?.launchAppInitToReadyMilliseconds.map {
                Observation(
                    source: "metric_kit",
                    metric: "launch_app_init_to_ready_ms",
                    value: $0,
                    unit: "ms",
                    note: nil
                )
            },
            organizer: inputs.organizer?.launchAppInitToReadyMilliseconds.map {
                Observation(
                    source: "organizer",
                    metric: "launch_app_init_to_ready_ms",
                    value: $0,
                    unit: "ms",
                    note: nil
                )
            },
            into: &signals
        )

        appendSignal(
            named: "hitches",
            metricKit: inputs.metricKit?.animationHitchTimeRatio.map {
                Observation(
                    source: "metric_kit",
                    metric: "animation_hitch_time_ratio",
                    value: $0,
                    unit: "ratio",
                    note: nil
                )
            },
            organizer: inputs.organizer?.hitchRate.map {
                Observation(
                    source: "organizer",
                    metric: "hitch_rate",
                    value: $0,
                    unit: "rate",
                    note: nil
                )
            },
            into: &signals
        )

        appendSignal(
            named: "potential_hangs",
            metricKit: inputs.metricKit?.hangCount.map {
                Observation(
                    source: "metric_kit",
                    metric: "hang_count",
                    value: Double($0),
                    unit: "count",
                    note: nil
                )
            },
            organizer: inputs.organizer?.hangRate.map {
                Observation(
                    source: "organizer",
                    metric: "hang_rate",
                    value: $0,
                    unit: "rate",
                    note: nil
                )
            },
            into: &signals
        )

        appendSignal(
            named: "allocation_growth",
            metricKit: inputs.metricKit?.peakMemoryMegabytes.map {
                Observation(
                    source: "metric_kit",
                    metric: "peak_memory_megabytes",
                    value: $0,
                    unit: "MB",
                    note: "maps field memory diagnostics back to local allocation growth review"
                )
            },
            organizer: inputs.organizer?.memoryPeakMegabytes.map {
                Observation(
                    source: "organizer",
                    metric: "memory_peak_megabytes",
                    value: $0,
                    unit: "MB",
                    note: "maps Organizer memory footprint trends back to local allocation growth review"
                )
            },
            into: &signals
        )

        let scenarioNotes =
            (inputs.organizer?.releaseComparisonNotes ?? []).map {
                Observation(
                    source: "organizer",
                    metric: "release_comparison_notes",
                    value: nil,
                    unit: nil,
                    note: $0
                )
            }
            + (inputs.appStoreConnectPerformanceAPI?.releaseComparisonNotes ?? []).map {
                Observation(
                    source: "app_store_connect_performance_api",
                    metric: "release_comparison_notes",
                    value: nil,
                    unit: nil,
                    note: $0
                )
            }
        if !scenarioNotes.isEmpty {
            signals.append(
                Signal(
                    name: "scenario_specific_regressions",
                    observations: scenarioNotes
                )
            )
        }

        return Report(label: inputs.label, signals: signals)
    }

    public static func write(report: Report, to outputDir: URL) throws {
        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(report)
        try jsonData.write(
            to: outputDir.appendingPathComponent("field-telemetry.json"),
            options: .atomic
        )

        let markdown = renderMarkdown(report: report)
        try Data(markdown.utf8).write(
            to: outputDir.appendingPathComponent("field-telemetry.md"),
            options: .atomic
        )
    }

    public static func renderMarkdown(report: Report) -> String {
        var lines = [
            "# Field Telemetry Report: \(report.label ?? "(unlabeled)")",
            "",
            "| Local signal | Source | Metric | Value | Detail |",
            "| --- | --- | --- | ---: | --- |",
        ]

        for signal in report.signals {
            for observation in signal.observations {
                let value = observation.value.map(formatValue) ?? "n/a"
                lines.append(
                    "| \(signal.name) | \(observation.source) | \(observation.metric) | \(value) | \(observation.note ?? "") |"
                )
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func appendSignal(
        named name: String,
        metricKit: Observation?,
        organizer: Observation?,
        into signals: inout [Signal]
    ) {
        let observations = [metricKit, organizer].compactMap { $0 }
        guard !observations.isEmpty else { return }
        signals.append(Signal(name: name, observations: observations))
    }

    private static func formatValue(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(value)
    }
}
