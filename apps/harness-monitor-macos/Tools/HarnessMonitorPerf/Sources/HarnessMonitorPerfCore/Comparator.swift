import Foundation

/// Diffs two `summary.json` files and writes both `comparison.json` and `comparison.md`.
/// Mirrors compare-instruments-runs.py keys-for-keys so existing dashboards keep working.
public enum Comparator {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public struct Inputs {
        public var current: URL
        public var baseline: URL
        public var outputDir: URL
        public init(current: URL, baseline: URL, outputDir: URL) {
            self.current = current
            self.baseline = baseline
            self.outputDir = outputDir
        }
    }

    @discardableResult
    public static func compare(_ inputs: Inputs) throws -> Comparison {
        let current = try loadSummary(inputs.current)
        let baseline = try loadSummary(inputs.baseline)
        try FileManager.default.createDirectory(
            at: inputs.outputDir, withIntermediateDirectories: true
        )

        let baselineIndex = Dictionary(uniqueKeysWithValues:
            baseline.captures.map { (CaptureKey(scenario: $0.scenario, template: $0.template), $0) }
        )

        var comparisons: [CaptureComparison] = []
        for capture in current.captures {
            let key = CaptureKey(scenario: capture.scenario, template: capture.template)
            guard let baselineCapture = baselineIndex[key] else { continue }
            let entry = try compareCapture(current: capture, baseline: baselineCapture)
            comparisons.append(entry)
        }

        let comparison = Comparison(
            currentLabel: current.label,
            baselineLabel: baseline.label,
            currentCreatedAtUTC: current.createdAtUTC,
            baselineCreatedAtUTC: baseline.createdAtUTC,
            comparisons: comparisons
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(comparison)
        try json.write(to: inputs.outputDir.appendingPathComponent("comparison.json"), options: .atomic)

        let markdown = renderMarkdown(comparison)
        try Data(markdown.utf8).write(
            to: inputs.outputDir.appendingPathComponent("comparison.md"), options: .atomic
        )
        return comparison
    }

    public static func loadSummary(_ url: URL) throws -> RunManifest {
        var resolved = url
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir)
        if isDir.boolValue {
            resolved = resolved.appendingPathComponent("summary.json")
        }
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw Failure(message: "summary.json not found at \(resolved.path)")
        }
        let data = try Data(contentsOf: resolved)
        return try JSONDecoder().decode(RunManifest.self, from: data)
    }

    private static func compareCapture(
        current: RunManifest.Capture, baseline: RunManifest.Capture
    ) throws -> CaptureComparison {
        switch current.template {
        case "SwiftUI":
            return swiftUIComparison(current: current, baseline: baseline)
        case "Allocations":
            return allocationsComparison(current: current, baseline: baseline)
        default:
            throw Failure(message: "Unsupported template \(current.template)")
        }
    }

    private static func swiftUIComparison(
        current: RunManifest.Capture, baseline: RunManifest.Capture
    ) -> CaptureComparison {
        let cm = current.metrics ?? .object([:])
        let bm = baseline.metrics ?? .object([:])
        let cur = cm["swiftui_updates"] ?? .object([:])
        let base = bm["swiftui_updates"] ?? .object([:])

        let metrics: [String: DeltaBlock] = [
            "total_updates": deltaInt(cur["total_count"]?.intValue ?? 0,
                                      base["total_count"]?.intValue ?? 0),
            "body_updates": deltaInt(cur["body_update_count"]?.intValue ?? 0,
                                     base["body_update_count"]?.intValue ?? 0),
            "p95_update_ms": deltaDouble(cur["duration_ms_p95"]?.doubleValue ?? 0,
                                         base["duration_ms_p95"]?.doubleValue ?? 0),
            "max_update_ms": deltaDouble(
                MetricsExtractor.nsToMs(cur["duration_ns_max"]?.intValue ?? 0),
                MetricsExtractor.nsToMs(base["duration_ns_max"]?.intValue ?? 0)
            ),
            "hitches": deltaInt(cm["hitches"]?["count"]?.intValue ?? 0,
                                bm["hitches"]?["count"]?.intValue ?? 0),
            "potential_hangs": deltaInt(cm["potential_hangs"]?["count"]?.intValue ?? 0,
                                        bm["potential_hangs"]?["count"]?.intValue ?? 0),
        ]

        return CaptureComparison(
            scenario: current.scenario,
            template: current.template,
            metrics: .swiftUI(metrics),
            topFrames: TopFramesPair(
                baseline: framesPrefix(bm["top_frames"], limit: 5),
                current: framesPrefix(cm["top_frames"], limit: 5)
            )
        )
    }

    private static func allocationsComparison(
        current: RunManifest.Capture, baseline: RunManifest.Capture
    ) -> CaptureComparison {
        let cm = current.metrics ?? .object([:])
        let bm = baseline.metrics ?? .object([:])
        let curRows = cm["allocations"]?["summary_rows"] ?? .object([:])
        let baseRows = bm["allocations"]?["summary_rows"] ?? .object([:])
        var byCategory: [String: [String: DeltaBlock]] = [:]
        for category in MetricsExtractor.allocationsSummaryCategories {
            let curRow = curRows[category] ?? .object([:])
            let baseRow = baseRows[category] ?? .object([:])
            byCategory[category] = [
                "persistent_bytes": deltaInt(curRow["persistent_bytes"]?.intValue ?? 0,
                                             baseRow["persistent_bytes"]?.intValue ?? 0),
                "total_bytes": deltaInt(curRow["total_bytes"]?.intValue ?? 0,
                                        baseRow["total_bytes"]?.intValue ?? 0),
                "count_events": deltaInt(curRow["count_events"]?.intValue ?? 0,
                                         baseRow["count_events"]?.intValue ?? 0),
            ]
        }
        return CaptureComparison(
            scenario: current.scenario,
            template: current.template,
            metrics: .allocations(byCategory),
            topFrames: nil
        )
    }

    static func framesPrefix(_ value: JSONValue?, limit: Int) -> [Frame] {
        guard case .array(let array) = value else { return [] }
        return array.prefix(limit).map { entry -> Frame in
            let name = entry["name"]?.stringValue ?? ""
            let samples = entry["samples"]?.intValue ?? 0
            return Frame(name: name, samples: samples)
        }
    }

    static func deltaInt(_ current: Int, _ baseline: Int) -> DeltaBlock {
        DeltaBlock(baseline: .int(baseline), current: .int(current), delta: .int(current - baseline))
    }

    static func deltaDouble(_ current: Double, _ baseline: Double) -> DeltaBlock {
        let raw = current - baseline
        let rounded = (raw * 10_000).rounded() / 10_000
        return DeltaBlock(baseline: .double(baseline), current: .double(current), delta: .double(rounded))
    }

    public static func renderMarkdown(_ comparison: Comparison) -> String {
        var lines: [String] = []
        lines.append(
            "# Instruments Comparison: \(comparison.baselineLabel ?? "(none)") -> \(comparison.currentLabel ?? "(none)")"
        )
        lines.append("")
        lines.append("- Baseline: `\(comparison.baselineCreatedAtUTC ?? "")`")
        lines.append("- Current: `\(comparison.currentCreatedAtUTC ?? "")`")
        lines.append("")

        if comparison.comparisons.isEmpty {
            lines.append("No overlapping scenario/template captures were found between the two runs.")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        for item in comparison.comparisons {
            lines.append("## \(item.scenario) (\(item.template))")
            lines.append("")
            switch item.metrics {
            case .swiftUI(let metrics):
                lines.append("| Metric | Baseline | Current | Delta |")
                lines.append("| --- | ---: | ---: | ---: |")
                for name in swiftUIMetricOrder where metrics[name] != nil {
                    let values = metrics[name]!
                    lines.append(
                        "| \(name) | \(values.baseline) | \(values.current) | \(values.delta) |"
                    )
                }
                let baselineNames = item.topFrames?.baseline.map(\.name).joined(separator: ", ") ?? ""
                let currentNames = item.topFrames?.current.map(\.name).joined(separator: ", ") ?? ""
                lines.append("")
                lines.append("- Baseline hot frames: \(baselineNames.isEmpty ? "n/a" : baselineNames)")
                lines.append("- Current hot frames: \(currentNames.isEmpty ? "n/a" : currentNames)")
            case .allocations(let byCategory):
                lines.append("| Category | Metric | Baseline | Current | Delta |")
                lines.append("| --- | --- | ---: | ---: | ---: |")
                for category in MetricsExtractor.allocationsSummaryCategories {
                    guard let metrics = byCategory[category] else { continue }
                    for metricName in allocationsMetricOrder where metrics[metricName] != nil {
                        let values = metrics[metricName]!
                        lines.append(
                            "| \(category) | \(metricName) | \(values.baseline) | \(values.current) | \(values.delta) |"
                        )
                    }
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static let swiftUIMetricOrder = [
        "total_updates", "body_updates", "p95_update_ms", "max_update_ms", "hitches", "potential_hangs",
    ]
    private static let allocationsMetricOrder = ["persistent_bytes", "total_bytes", "count_events"]

    public struct Comparison: Codable, Equatable {
        public var currentLabel: String?
        public var baselineLabel: String?
        public var currentCreatedAtUTC: String?
        public var baselineCreatedAtUTC: String?
        public var comparisons: [CaptureComparison]

        enum CodingKeys: String, CodingKey {
            case currentLabel = "current_label"
            case baselineLabel = "baseline_label"
            case currentCreatedAtUTC = "current_created_at_utc"
            case baselineCreatedAtUTC = "baseline_created_at_utc"
            case comparisons
        }
    }

    public struct CaptureComparison: Codable, Equatable {
        public var scenario: String
        public var template: String
        public var metrics: MetricsBlock
        public var topFrames: TopFramesPair?

        enum CodingKeys: String, CodingKey {
            case scenario, template, metrics
            case topFrames = "top_frames"
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(scenario, forKey: .scenario)
            try container.encode(template, forKey: .template)
            switch metrics {
            case .swiftUI(let map): try container.encode(map, forKey: .metrics)
            case .allocations(let map): try container.encode(map, forKey: .metrics)
            }
            try container.encodeIfPresent(topFrames, forKey: .topFrames)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scenario = try container.decode(String.self, forKey: .scenario)
            template = try container.decode(String.self, forKey: .template)
            topFrames = try container.decodeIfPresent(TopFramesPair.self, forKey: .topFrames)
            if template == "Allocations" {
                metrics = .allocations(
                    try container.decode([String: [String: DeltaBlock]].self, forKey: .metrics)
                )
            } else {
                metrics = .swiftUI(try container.decode([String: DeltaBlock].self, forKey: .metrics))
            }
        }

        public init(
            scenario: String, template: String, metrics: MetricsBlock, topFrames: TopFramesPair?
        ) {
            self.scenario = scenario
            self.template = template
            self.metrics = metrics
            self.topFrames = topFrames
        }
    }

    public enum MetricsBlock: Equatable {
        case swiftUI([String: DeltaBlock])
        case allocations([String: [String: DeltaBlock]])
    }

    public struct DeltaBlock: Codable, Equatable {
        public var baseline: Number
        public var current: Number
        public var delta: Number
    }

    public enum Number: Codable, Equatable, CustomStringConvertible {
        case int(Int)
        case double(Double)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let i = try? container.decode(Int.self) { self = .int(i); return }
            if let d = try? container.decode(Double.self) { self = .double(d); return }
            throw DecodingError.typeMismatch(Number.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected number"))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .int(let v): try container.encode(v)
            case .double(let v): try container.encode(v)
            }
        }

        public var description: String {
            switch self {
            case .int(let v): return String(v)
            case .double(let v):
                if v == v.rounded() { return String(Int64(v)) }
                return String(v)
            }
        }
    }

    public struct TopFramesPair: Codable, Equatable {
        public var baseline: [Frame]
        public var current: [Frame]
    }

    public struct Frame: Codable, Equatable {
        public var name: String
        public var samples: Int
    }

    private struct CaptureKey: Hashable {
        var scenario: String
        var template: String
    }
}
