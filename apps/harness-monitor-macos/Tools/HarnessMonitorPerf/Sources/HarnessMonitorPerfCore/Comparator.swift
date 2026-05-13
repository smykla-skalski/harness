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
        let currentIndex = Dictionary(uniqueKeysWithValues:
            current.captures.map { (CaptureKey(scenario: $0.scenario, template: $0.template), $0) }
        )

        var comparisons: [CaptureComparison] = []
        var missingFromCurrent: [MissingCapture] = []
        var missingFromBaseline: [MissingCapture] = []
        var currentMissingMetrics: [MissingCapture] = []
        var baselineMissingMetrics: [MissingCapture] = []

        let allKeys = Set(currentIndex.keys).union(baselineIndex.keys).sorted {
            ($0.scenario, $0.template) < ($1.scenario, $1.template)
        }

        for key in allKeys {
            switch (currentIndex[key], baselineIndex[key]) {
            case let (.some(currentCapture), .some(baselineCapture)):
                let currentHasMetrics = currentCapture.metrics != nil
                let baselineHasMetrics = baselineCapture.metrics != nil
                if !currentHasMetrics {
                    currentMissingMetrics.append(missingCapture(from: currentCapture))
                }
                if !baselineHasMetrics {
                    baselineMissingMetrics.append(missingCapture(from: baselineCapture))
                }
                guard currentHasMetrics, baselineHasMetrics else {
                    continue
                }
                let entry = try compareCapture(current: currentCapture, baseline: baselineCapture)
                comparisons.append(entry)
            case let (.some(currentCapture), .none):
                missingFromBaseline.append(missingCapture(from: currentCapture))
            case let (.none, .some(baselineCapture)):
                missingFromCurrent.append(missingCapture(from: baselineCapture))
            case (.none, .none):
                continue
            }
        }

        let comparison = Comparison(
            currentLabel: current.label,
            baselineLabel: baseline.label,
            currentCreatedAtUTC: current.createdAtUTC,
            baselineCreatedAtUTC: baseline.createdAtUTC,
            missingFromCurrent: missingFromCurrent,
            missingFromBaseline: missingFromBaseline,
            currentMissingMetrics: currentMissingMetrics,
            baselineMissingMetrics: baselineMissingMetrics,
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
        let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true {
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
        let sharedMetrics = sharedMetricComparisons(current: current, baseline: baseline)
        let metricTiers = current.metricTiers ?? MetricTierCatalog.tiers(
            for: current.scenario,
            template: current.template
        )
        switch current.template {
        case "SwiftUI":
            return swiftUIComparison(
                current: current,
                baseline: baseline,
                sharedMetrics: sharedMetrics,
                metricTiers: metricTiers
            )
        case "Allocations":
            return allocationsComparison(
                current: current,
                baseline: baseline,
                sharedMetrics: sharedMetrics,
                metricTiers: metricTiers
            )
        default:
            throw Failure(message: "Unsupported template \(current.template)")
        }
    }

    private static func swiftUIComparison(
        current: RunManifest.Capture,
        baseline: RunManifest.Capture,
        sharedMetrics: [String: DeltaBlock],
        metricTiers: CaptureMetricTiers
    ) -> CaptureComparison {
        let cm = current.metrics ?? .object([:])
        let bm = baseline.metrics ?? .object([:])
        let cur = cm["swiftui_updates"] ?? .object([:])
        let base = bm["swiftui_updates"] ?? .object([:])
        let currentGroups = cm["swiftui_update_groups"] ?? .object([:])
        let baselineGroups = bm["swiftui_update_groups"] ?? .object([:])

        let metrics: [String: DeltaBlock] = [
            MetricName.totalUpdates: deltaInt(
                cur["total_count"]?.intValue ?? 0,
                base["total_count"]?.intValue ?? 0
            ),
            MetricName.bodyUpdates: deltaInt(
                cur["body_update_count"]?.intValue ?? 0,
                base["body_update_count"]?.intValue ?? 0
            ),
            MetricName.p95UpdateMs: deltaDouble(
                cur["duration_ms_p95"]?.doubleValue ?? 0,
                base["duration_ms_p95"]?.doubleValue ?? 0
            ),
            MetricName.maxUpdateMs: deltaDouble(
                MetricsExtractor.nsToMs(cur["duration_ns_max"]?.intValue ?? 0),
                MetricsExtractor.nsToMs(base["duration_ns_max"]?.intValue ?? 0)
            ),
            MetricName.maxUpdateGroupMs: deltaDouble(
                MetricsExtractor.nsToMs(currentGroups["duration_ns_max"]?.intValue ?? 0),
                MetricsExtractor.nsToMs(baselineGroups["duration_ns_max"]?.intValue ?? 0)
            ),
            MetricName.updateGroupP95Ms: deltaDouble(
                currentGroups["duration_ms_p95"]?.doubleValue ?? 0,
                baselineGroups["duration_ms_p95"]?.doubleValue ?? 0
            ),
            MetricName.hitches: deltaInt(
                cm["hitches"]?["count"]?.intValue ?? 0,
                bm["hitches"]?["count"]?.intValue ?? 0
            ),
            MetricName.potentialHangs: deltaInt(
                cm["potential_hangs"]?["count"]?.intValue ?? 0,
                bm["potential_hangs"]?["count"]?.intValue ?? 0
            ),
        ]

        return CaptureComparison(
            scenario: current.scenario,
            template: current.template,
            metrics: .swiftUI(metrics),
            sharedMetrics: sharedMetrics,
            metricTiers: metricTiers,
            topFrames: TopFramesPair(
                baseline: framesPrefix(bm["top_frames"], limit: 5),
                current: framesPrefix(cm["top_frames"], limit: 5)
            )
        )
    }

    private static func allocationsComparison(
        current: RunManifest.Capture,
        baseline: RunManifest.Capture,
        sharedMetrics: [String: DeltaBlock],
        metricTiers: CaptureMetricTiers
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
            sharedMetrics: sharedMetrics,
            metricTiers: metricTiers,
            topFrames: nil
        )
    }

    private static func sharedMetricComparisons(
        current: RunManifest.Capture,
        baseline: RunManifest.Capture
    ) -> [String: DeltaBlock] {
        guard
            let currentLaunch = current.launchMetrics?.appInitToReadyMilliseconds,
            let baselineLaunch = baseline.launchMetrics?.appInitToReadyMilliseconds
        else {
            return [:]
        }
        return [
            MetricName.launchAppInitToReadyMs: deltaDouble(currentLaunch, baselineLaunch)
        ]
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

        if comparison.comparisons.isEmpty
            && comparison.missingFromCurrent.isEmpty
            && comparison.missingFromBaseline.isEmpty
            && comparison.currentMissingMetrics.isEmpty
            && comparison.baselineMissingMetrics.isEmpty
        {
            lines.append("No overlapping scenario/template captures were found between the two runs.")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        appendMissingSection(
            title: "Missing from current",
            items: comparison.missingFromCurrent,
            to: &lines
        )
        appendMissingSection(
            title: "Missing from baseline",
            items: comparison.missingFromBaseline,
            to: &lines
        )
        appendMissingSection(
            title: "Current captures without metrics",
            items: comparison.currentMissingMetrics,
            to: &lines
        )
        appendMissingSection(
            title: "Baseline captures without metrics",
            items: comparison.baselineMissingMetrics,
            to: &lines
        )

        for item in comparison.comparisons {
            lines.append("## \(item.scenario) (\(item.template))")
            lines.append("")
            switch item.metrics {
            case .swiftUI:
                appendSwiftUISections(item, to: &lines)
                let baselineNames = item.topFrames?.baseline.map(\.name).joined(separator: ", ") ?? ""
                let currentNames = item.topFrames?.current.map(\.name).joined(separator: ", ") ?? ""
                lines.append("")
                lines.append("- Baseline hot frames: \(baselineNames.isEmpty ? "n/a" : baselineNames)")
                lines.append("- Current hot frames: \(currentNames.isEmpty ? "n/a" : currentNames)")
            case .allocations:
                appendAllocationsSections(item, to: &lines)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func appendMissingSection(
        title: String,
        items: [MissingCapture],
        to lines: inout [String]
    ) {
        guard !items.isEmpty else { return }
        lines.append("## \(title)")
        lines.append("")
        for item in items {
            let reasonSuffix = item.reason.map { " - \($0)" } ?? ""
            lines.append("- `\(item.scenario)` (\(item.template))\(reasonSuffix)")
        }
        lines.append("")
    }

    private static func appendSwiftUISections(
        _ item: CaptureComparison,
        to lines: inout [String]
    ) {
        guard case .swiftUI(let metrics) = item.metrics else { return }
        let combined = (item.sharedMetrics ?? [:]).merging(metrics) { current, _ in current }
        let tiers = item.metricTiers ?? MetricTierCatalog.tiers(
            for: item.scenario,
            template: item.template
        )
        appendMetricTable(
            title: "Hard budget metrics",
            metricNames: tiers.hardBudget,
            metrics: combined,
            to: &lines
        )
        appendMetricTable(
            title: "Investigative metrics",
            metricNames: tiers.investigative,
            metrics: combined,
            to: &lines
        )
    }

    private static func appendAllocationsSections(
        _ item: CaptureComparison,
        to lines: inout [String]
    ) {
        guard case .allocations(let byCategory) = item.metrics else { return }
        let tiers = item.metricTiers ?? MetricTierCatalog.tiers(
            for: item.scenario,
            template: item.template
        )
        let hardRows = allocationsHardBudgetRows(
            sharedMetrics: item.sharedMetrics ?? [:],
            byCategory: byCategory,
            hardMetricNames: Set(tiers.hardBudget)
        )
        appendMetricRowsTable(
            title: "Hard budget metrics",
            rows: hardRows,
            to: &lines
        )

        let investigativeLaunchRows: [(String, DeltaBlock)] = {
            guard
                tiers.investigative.contains(MetricName.launchAppInitToReadyMs),
                let launch = item.sharedMetrics?[MetricName.launchAppInitToReadyMs]
            else {
                return []
            }
            return [(MetricName.launchAppInitToReadyMs, launch)]
        }()
        appendMetricRowsTable(
            title: "Investigative metrics",
            rows: investigativeLaunchRows,
            to: &lines
        )

        lines.append("### Investigative allocations")
        lines.append("")
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
        lines.append("")
    }

    private static func appendMetricTable(
        title: String,
        metricNames: [String],
        metrics: [String: DeltaBlock],
        to lines: inout [String]
    ) {
        let rows = metricNames.compactMap { name -> (String, DeltaBlock)? in
            guard let values = metrics[name] else { return nil }
            return (name, values)
        }
        appendMetricRowsTable(title: title, rows: rows, to: &lines)
    }

    private static func appendMetricRowsTable(
        title: String,
        rows: [(String, DeltaBlock)],
        to lines: inout [String]
    ) {
        guard !rows.isEmpty else { return }
        lines.append("### \(title)")
        lines.append("")
        lines.append("| Metric | Baseline | Current | Delta |")
        lines.append("| --- | ---: | ---: | ---: |")
        for (name, values) in rows {
            lines.append(
                "| \(name) | \(values.baseline) | \(values.current) | \(values.delta) |"
            )
        }
        lines.append("")
    }

    private static func allocationsHardBudgetRows(
        sharedMetrics: [String: DeltaBlock],
        byCategory: [String: [String: DeltaBlock]],
        hardMetricNames: Set<String>
    ) -> [(String, DeltaBlock)] {
        var rows: [(String, DeltaBlock)] = []
        if
            hardMetricNames.contains(MetricName.launchAppInitToReadyMs),
            let launch = sharedMetrics[MetricName.launchAppInitToReadyMs]
        {
            rows.append((MetricName.launchAppInitToReadyMs, launch))
        }
        if
            hardMetricNames.contains(MetricName.heapTotalBytes),
            let heap = byCategory["All Heap Allocations"]?["total_bytes"]
        {
            rows.append((MetricName.heapTotalBytes, heap))
        }
        return rows
    }

    private static let allocationsMetricOrder = ["persistent_bytes", "total_bytes", "count_events"]

    public struct Comparison: Codable, Equatable {
        public var currentLabel: String?
        public var baselineLabel: String?
        public var currentCreatedAtUTC: String?
        public var baselineCreatedAtUTC: String?
        public var missingFromCurrent: [MissingCapture]
        public var missingFromBaseline: [MissingCapture]
        public var currentMissingMetrics: [MissingCapture]
        public var baselineMissingMetrics: [MissingCapture]
        public var comparisons: [CaptureComparison]

        enum CodingKeys: String, CodingKey {
            case currentLabel = "current_label"
            case baselineLabel = "baseline_label"
            case currentCreatedAtUTC = "current_created_at_utc"
            case baselineCreatedAtUTC = "baseline_created_at_utc"
            case missingFromCurrent = "missing_from_current"
            case missingFromBaseline = "missing_from_baseline"
            case currentMissingMetrics = "current_missing_metrics"
            case baselineMissingMetrics = "baseline_missing_metrics"
            case comparisons
        }
    }

    public struct MissingCapture: Codable, Equatable {
        public var scenario: String
        public var template: String
        public var reason: String?
    }

    public struct CaptureComparison: Codable, Equatable {
        public var scenario: String
        public var template: String
        public var metrics: MetricsBlock
        public var sharedMetrics: [String: DeltaBlock]?
        public var metricTiers: CaptureMetricTiers?
        public var topFrames: TopFramesPair?

        enum CodingKeys: String, CodingKey {
            case scenario, template, metrics
            case sharedMetrics = "shared_metrics"
            case metricTiers = "metric_tiers"
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
            try container.encodeIfPresent(sharedMetrics, forKey: .sharedMetrics)
            try container.encodeIfPresent(metricTiers, forKey: .metricTiers)
            try container.encodeIfPresent(topFrames, forKey: .topFrames)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scenario = try container.decode(String.self, forKey: .scenario)
            template = try container.decode(String.self, forKey: .template)
            sharedMetrics = try container.decodeIfPresent(
                [String: DeltaBlock].self,
                forKey: .sharedMetrics
            )
            metricTiers = try container.decodeIfPresent(
                CaptureMetricTiers.self,
                forKey: .metricTiers
            )
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
            scenario: String,
            template: String,
            metrics: MetricsBlock,
            sharedMetrics: [String: DeltaBlock]? = nil,
            metricTiers: CaptureMetricTiers? = nil,
            topFrames: TopFramesPair?
        ) {
            self.scenario = scenario
            self.template = template
            self.metrics = metrics
            self.sharedMetrics = sharedMetrics
            self.metricTiers = metricTiers
            self.topFrames = topFrames
        }
    }

    public enum MetricsBlock: Equatable {
        case swiftUI([String: DeltaBlock])
        case allocations([String: [String: DeltaBlock]])
    }

    private static func missingCapture(from capture: RunManifest.Capture) -> MissingCapture {
        MissingCapture(
            scenario: capture.scenario,
            template: capture.template,
            reason: capture.warnings?.joined(separator: "; ")
        )
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
