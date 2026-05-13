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
        let findingsDiff = findingsDiff(
            current: current.findings ?? [],
            baseline: baseline.findings ?? []
        )

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
            baselineFindings: orderedFindings(baseline.findings),
            currentFindings: orderedFindings(current.findings),
            newFindings: findingsDiff.new,
            resolvedFindings: findingsDiff.resolved,
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
            baselineFindings: baseline.findings,
            currentFindings: current.findings,
            newFindings: nil,
            resolvedFindings: nil,
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

    private static func findingsDiff(
        current: [CaptureFinding],
        baseline: [CaptureFinding]
    ) -> (new: [CaptureFinding], resolved: [CaptureFinding]) {
        let currentByKey = Dictionary(uniqueKeysWithValues: current.map { ($0.key, $0) })
        let baselineByKey = Dictionary(uniqueKeysWithValues: baseline.map { ($0.key, $0) })
        let currentKeys = Set(currentByKey.keys)
        let baselineKeys = Set(baselineByKey.keys)

        let new = currentKeys
            .subtracting(baselineKeys)
            .compactMap { currentByKey[$0] }
        let resolved = baselineKeys
            .subtracting(currentKeys)
            .compactMap { baselineByKey[$0] }
        return (orderedFindings(new), orderedFindings(resolved))
    }

    private static func orderedFindings(
        _ findings: [CaptureFinding]?
    ) -> [CaptureFinding]? {
        guard let findings else { return nil }
        return orderedFindings(findings)
    }

    private static func orderedFindings(
        _ findings: [CaptureFinding]
    ) -> [CaptureFinding] {
        findings.sorted { lhs, rhs in
            let lhsPriority = findingsCategoryPriority(lhs.category)
            let rhsPriority = findingsCategoryPriority(rhs.category)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            if (lhs.count ?? 0) != (rhs.count ?? 0) {
                return (lhs.count ?? 0) > (rhs.count ?? 0)
            }
            return lhs.key < rhs.key
        }
    }

    private static func findingsCategoryPriority(_ category: String) -> Int {
        switch category {
        case "swiftui-update-group":
            0
        case "swiftui-cause":
            1
        default:
            2
        }
    }

    private static func missingCapture(from capture: RunManifest.Capture) -> MissingCapture {
        MissingCapture(
            scenario: capture.scenario,
            template: capture.template,
            reason: capture.warnings?.joined(separator: "; ")
        )
    }

    private struct CaptureKey: Hashable {
        var scenario: String
        var template: String
    }
}
