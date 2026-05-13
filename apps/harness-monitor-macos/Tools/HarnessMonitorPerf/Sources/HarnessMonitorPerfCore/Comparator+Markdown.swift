extension Comparator {
    private static let allocationsMetricOrder = [
        "persistent_bytes",
        "total_bytes",
        "count_events",
    ]

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

        appendMissingSections(comparison, to: &lines)

        for item in comparison.comparisons {
            lines.append("## \(item.scenario) (\(item.template))")
            lines.append("")
            switch item.metrics {
            case .swiftUI:
                appendSwiftUISections(item, to: &lines)
                appendTopFrames(item, to: &lines)
            case .allocations:
                appendAllocationsSections(item, to: &lines)
            }
            appendFindingsSections(item, to: &lines)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func appendMissingSections(
        _ comparison: Comparison,
        to lines: inout [String]
    ) {
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

    private static func appendTopFrames(
        _ item: CaptureComparison,
        to lines: inout [String]
    ) {
        let baselineNames = item.topFrames?.baseline.map(\.name).joined(separator: ", ") ?? ""
        let currentNames = item.topFrames?.current.map(\.name).joined(separator: ", ") ?? ""
        lines.append("")
        lines.append("- Baseline hot frames: \(baselineNames.isEmpty ? "n/a" : baselineNames)")
        lines.append("- Current hot frames: \(currentNames.isEmpty ? "n/a" : currentNames)")
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
        appendMetricRowsTable(
            title: "Hard budget metrics",
            rows: allocationsHardBudgetRows(
                sharedMetrics: item.sharedMetrics ?? [:],
                byCategory: byCategory,
                hardMetricNames: Set(tiers.hardBudget)
            ),
            to: &lines
        )
        appendMetricRowsTable(
            title: "Investigative metrics",
            rows: investigativeLaunchRows(item: item, tiers: tiers),
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

    private static func investigativeLaunchRows(
        item: CaptureComparison,
        tiers: CaptureMetricTiers
    ) -> [(String, DeltaBlock)] {
        guard
            tiers.investigative.contains(MetricName.launchAppInitToReadyMs),
            let launch = item.sharedMetrics?[MetricName.launchAppInitToReadyMs]
        else {
            return []
        }
        return [(MetricName.launchAppInitToReadyMs, launch)]
    }

    private static func appendFindingsSections(
        _ item: CaptureComparison,
        to lines: inout [String]
    ) {
        if let newFindings = item.newFindings, !newFindings.isEmpty {
            appendFindingsList(title: "New findings", findings: newFindings, to: &lines)
        }
        if let resolvedFindings = item.resolvedFindings, !resolvedFindings.isEmpty {
            appendFindingsList(title: "Resolved findings", findings: resolvedFindings, to: &lines)
        }
        if
            (item.newFindings?.isEmpty ?? true),
            (item.resolvedFindings?.isEmpty ?? true),
            let currentFindings = item.currentFindings,
            !currentFindings.isEmpty
        {
            appendFindingsList(title: "Current findings", findings: currentFindings, to: &lines)
        }
    }

    private static func appendFindingsList(
        title: String,
        findings: [CaptureFinding],
        to lines: inout [String]
    ) {
        guard !findings.isEmpty else { return }
        lines.append("### \(title)")
        lines.append("")
        for finding in findings {
            let countSuffix = finding.count.map { " (\($0))" } ?? ""
            let detailSuffix = finding.detail.map { $0.isEmpty ? "" : " - \($0)" } ?? ""
            lines.append(
                "- `\(finding.category)` \(finding.headline)\(countSuffix)\(detailSuffix)"
            )
        }
        lines.append("")
    }
}
