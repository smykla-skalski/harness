import Foundation

extension MetricsExtractor {
    public struct EventTable: Codable, Equatable {
        public var count: Int
        public var durationNsTotal: Int
        public var durationNsMax: Int
        public var topLabels: [LabelCount]

        public struct LabelCount: Codable, Equatable {
            public var label: String
            public var count: Int
        }

        enum CodingKeys: String, CodingKey {
            case count
            case durationNsTotal = "duration_ns_total"
            case durationNsMax = "duration_ns_max"
            case topLabels = "top_labels"
        }
    }

    /// Mirrors `parse_event_table` for hitches and potential-hangs. When duration is missing it
    /// falls back to label counts (some xctrace schemas emit only narrative text).
    public static func parseEventTable(
        _ document: XctraceQueryDocument,
        maximumValidDurationNs: Int? = nil
    ) -> EventTable {
        var durations: [Int] = []
        var labels: [String: Int] = [:]

        for row in document.rows {
            let record = document.record(for: row)
            if let duration = parseDurationNs(
                record["duration"],
                maximumValidDurationNs: maximumValidDurationNs
            ) {
                durations.append(duration)
            }
            let labelText = record["narrative-description"]
                ?? record["label"]
                ?? record["description"]
                ?? ""
            let label = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty { labels[label, default: 0] += 1 }
        }

        let topLabels = labels
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map { EventTable.LabelCount(label: $0.key, count: $0.value) }

        let count = durations.isEmpty ? labels.values.reduce(0, +) : durations.count
        return EventTable(
            count: count,
            durationNsTotal: durations.reduce(0, +),
            durationNsMax: durations.max() ?? 0,
            topLabels: topLabels
        )
    }
}
