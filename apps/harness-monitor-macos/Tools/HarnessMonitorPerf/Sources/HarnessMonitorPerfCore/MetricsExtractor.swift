import Foundation

/// Aggregations the python `extract-instruments-metrics.py` produces per Instruments template.
public enum MetricsExtractor {
    public struct SwiftUIUpdates: Codable, Equatable {
        public struct Summary: Codable, Equatable {
            public var totalCount: Int
            public var bodyUpdateCount: Int
            public var durationNsTotal: Int
            public var durationNsMax: Int
            public var durationMsP95: Double
            public var allocationsTotal: Int
            public var updateTypeCounts: [String: Int]
            public var severityCounts: [String: Int]
            public var categoryCounts: [String: Int]

            enum CodingKeys: String, CodingKey {
                case totalCount = "total_count"
                case bodyUpdateCount = "body_update_count"
                case durationNsTotal = "duration_ns_total"
                case durationNsMax = "duration_ns_max"
                case durationMsP95 = "duration_ms_p95"
                case allocationsTotal = "allocations_total"
                case updateTypeCounts = "update_type_counts"
                case severityCounts = "severity_counts"
                case categoryCounts = "category_counts"
            }
        }

        public struct Offender: Codable, Equatable {
            public var description: String
            public var module: String
            public var viewName: String
            public var count: Int
            public var durationNs: Int
            public var durationMs: Double
            public var allocations: Int

            enum CodingKeys: String, CodingKey {
                case description
                case module
                case viewName = "view_name"
                case count
                case durationNs = "duration_ns"
                case durationMs = "duration_ms"
                case allocations
            }
        }

        public var summary: Summary
        public var topOffenders: [Offender]
    }

    public static func parseSwiftUIUpdates(_ document: XctraceQueryDocument) -> SwiftUIUpdates {
        var durationsNs: [Int] = []
        var updateTypeCounts: [String: Int] = [:]
        var severityCounts: [String: Int] = [:]
        var categoryCounts: [String: Int] = [:]
        var bodyUpdateCount = 0
        var totalAllocations = 0
        var offenderTotals: [OffenderKey: OffenderAccumulator] = [:]
        let rows = document.rows
        let total = rows.count

        for row in rows {
            let record = document.record(for: row)
            let durationNs = parseInt(record["duration"])
            let allocations = parseInt(record["allocations"]) ?? 0
            let updateType = normalize(record["update-type"])
            let severity = normalize(record["severity"])
            let category = normalize(record["category"])
            let description = normalize(record["description"])
            let module = normalize(record["module"])
            let viewName = normalize(record["view-name"])

            if let durationNs { durationsNs.append(durationNs) }
            totalAllocations += allocations
            updateTypeCounts[updateType, default: 0] += 1
            severityCounts[severity, default: 0] += 1
            categoryCounts[category, default: 0] += 1

            if updateType.lowercased().contains("body") || description.lowercased().contains("body") {
                bodyUpdateCount += 1
            }

            let key = OffenderKey(description: description, module: module, viewName: viewName)
            var acc = offenderTotals[key] ?? OffenderAccumulator()
            acc.count += 1
            acc.durationNs += durationNs ?? 0
            acc.allocations += allocations
            offenderTotals[key] = acc
        }

        let topOffenders = offenderTotals
            .sorted { (lhs, rhs) -> Bool in
                if lhs.value.durationNs != rhs.value.durationNs {
                    return lhs.value.durationNs > rhs.value.durationNs
                }
                return lhs.value.count > rhs.value.count
            }
            .prefix(15)
            .map { entry -> SwiftUIUpdates.Offender in
                SwiftUIUpdates.Offender(
                    description: entry.key.description,
                    module: entry.key.module,
                    viewName: entry.key.viewName,
                    count: entry.value.count,
                    durationNs: entry.value.durationNs,
                    durationMs: nsToMs(entry.value.durationNs),
                    allocations: entry.value.allocations
                )
            }

        let summary = SwiftUIUpdates.Summary(
            totalCount: total,
            bodyUpdateCount: bodyUpdateCount,
            durationNsTotal: durationsNs.reduce(0, +),
            durationNsMax: durationsNs.max() ?? 0,
            durationMsP95: nsToMs(percentile(durationsNs, percent: 95)),
            allocationsTotal: totalAllocations,
            updateTypeCounts: updateTypeCounts,
            severityCounts: severityCounts,
            categoryCounts: categoryCounts
        )
        return SwiftUIUpdates(summary: summary, topOffenders: topOffenders)
    }

    // MARK: - Shared helpers

    /// Mirrors `parse_int` in the python extractor: strip thousands separators and treat blanks
    /// as `nil` so callers can decide whether 0 or "missing" applies.
    public static func parseInt(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let trimmed = raw.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let direct = Int(trimmed) { return direct }
        if let asDouble = Double(trimmed) { return Int(asDouble) }
        return nil
    }

    /// Replace blank/missing values with `<unknown>` so counters group consistently.
    public static func normalize(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "<unknown>" : trimmed
    }

    /// `ceil((pct/100) * count) - 1` index against the sorted values, matching the python.
    public static func percentile(_ values: [Int], percent: Int) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let pct = Double(percent) / 100.0
        var rank = Int(ceil(pct * Double(sorted.count))) - 1
        if rank < 0 { rank = 0 }
        if rank >= sorted.count { rank = sorted.count - 1 }
        return sorted[rank]
    }

    /// Convert nanoseconds to milliseconds with 4-decimal rounding (`round(x/1e6, 4)`).
    public static func nsToMs(_ value: Int) -> Double {
        let raw = Double(value) / 1_000_000.0
        return (raw * 10_000).rounded() / 10_000
    }

    private struct OffenderKey: Hashable {
        var description: String
        var module: String
        var viewName: String
    }

    private struct OffenderAccumulator {
        var count: Int = 0
        var durationNs: Int = 0
        var allocations: Int = 0
    }
}
