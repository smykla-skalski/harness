import Foundation

extension MetricsExtractor {
    public struct UpdateGroups: Codable, Equatable {
        public struct Summary: Codable, Equatable {
            public var totalCount: Int
            public var durationNsTotal: Int
            public var durationNsMax: Int
            public var durationMsP95: Double
            public var labelCounts: [String: Int]

            enum CodingKeys: String, CodingKey {
                case totalCount = "total_count"
                case durationNsTotal = "duration_ns_total"
                case durationNsMax = "duration_ns_max"
                case durationMsP95 = "duration_ms_p95"
                case labelCounts = "label_counts"
            }
        }

        public struct Group: Codable, Equatable {
            public var label: String
            public var count: Int
            public var durationNs: Int
            public var durationMs: Double

            enum CodingKeys: String, CodingKey {
                case label, count
                case durationNs = "duration_ns"
                case durationMs = "duration_ms"
            }
        }

        public var summary: Summary
        public var topGroups: [Group]
    }

    public static func parseSwiftUIUpdateGroups(_ document: XctraceQueryDocument) -> UpdateGroups {
        var durations: [Int] = []
        var labelCounts: [String: Int] = [:]
        var labelTotals: [String: (count: Int, durationNs: Int)] = [:]

        for row in document.rows {
            let record = document.record(for: row)
            let label = normalize(record["label"])
            let durationNs = parseInt(record["duration"]) ?? 0
            durations.append(durationNs)
            labelCounts[label, default: 0] += 1
            var entry = labelTotals[label] ?? (0, 0)
            entry.count += 1
            entry.durationNs += durationNs
            labelTotals[label] = entry
        }

        let topGroups = labelTotals
            .sorted { lhs, rhs in
                if lhs.value.durationNs != rhs.value.durationNs {
                    return lhs.value.durationNs > rhs.value.durationNs
                }
                return lhs.value.count > rhs.value.count
            }
            .prefix(12)
            .map { entry in
                UpdateGroups.Group(
                    label: entry.key,
                    count: entry.value.count,
                    durationNs: entry.value.durationNs,
                    durationMs: nsToMs(entry.value.durationNs)
                )
            }

        let summary = UpdateGroups.Summary(
            totalCount: labelCounts.values.reduce(0, +),
            durationNsTotal: durations.reduce(0, +),
            durationNsMax: durations.max() ?? 0,
            durationMsP95: nsToMs(percentile(durations, percent: 95)),
            labelCounts: topNCounter(labelCounts, n: 12)
        )
        return UpdateGroups(summary: summary, topGroups: topGroups)
    }

    public struct Causes: Codable, Equatable {
        public struct Summary: Codable, Equatable {
            public var totalCount: Int
            public var labelCounts: [String: Int]
            public var sourceNodeCounts: [String: Int]
            public var destinationNodeCounts: [String: Int]
            public var valueTypeCounts: [String: Int]
            public var changedPropertyCounts: [String: Int]

            enum CodingKeys: String, CodingKey {
                case totalCount = "total_count"
                case labelCounts = "label_counts"
                case sourceNodeCounts = "source_node_counts"
                case destinationNodeCounts = "destination_node_counts"
                case valueTypeCounts = "value_type_counts"
                case changedPropertyCounts = "changed_property_counts"
            }
        }

        public struct Cause: Codable, Equatable {
            public var sourceNode: String
            public var destinationNode: String
            public var label: String
            public var count: Int

            enum CodingKeys: String, CodingKey {
                case sourceNode = "source_node"
                case destinationNode = "destination_node"
                case label, count
            }
        }

        public var summary: Summary
        public var topCauses: [Cause]
    }

    public static func parseSwiftUICauses(_ document: XctraceQueryDocument) -> Causes {
        var labelCounts: [String: Int] = [:]
        var sourceCounts: [String: Int] = [:]
        var destinationCounts: [String: Int] = [:]
        var valueTypeCounts: [String: Int] = [:]
        var propertyCounts: [String: Int] = [:]
        var causeCounts: [CauseKey: Int] = [:]

        for row in document.rows {
            let record = document.record(for: row)
            let label = normalize(record["label"])
            let source = normalize(record["source-node"])
            let destination = normalize(record["destination-node"])
            let valueType = normalize(record["value-type"])
            let changedProperties = normalize(record["changed-properties"])

            labelCounts[label, default: 0] += 1
            sourceCounts[source, default: 0] += 1
            destinationCounts[destination, default: 0] += 1
            if valueType != "<unknown>" { valueTypeCounts[valueType, default: 0] += 1 }
            if changedProperties != "<unknown>" { propertyCounts[changedProperties, default: 0] += 1 }
            causeCounts[CauseKey(source: source, destination: destination, label: label), default: 0] += 1
        }

        let topCauses = causeCounts
            .sorted { $0.value > $1.value }
            .prefix(15)
            .map {
                Causes.Cause(
                    sourceNode: $0.key.source,
                    destinationNode: $0.key.destination,
                    label: $0.key.label,
                    count: $0.value
                )
            }

        let summary = Causes.Summary(
            totalCount: labelCounts.values.reduce(0, +),
            labelCounts: topNCounter(labelCounts, n: 12),
            sourceNodeCounts: topNCounter(sourceCounts, n: 12),
            destinationNodeCounts: topNCounter(destinationCounts, n: 12),
            valueTypeCounts: topNCounter(valueTypeCounts, n: 12),
            changedPropertyCounts: topNCounter(propertyCounts, n: 12)
        )
        return Causes(summary: summary, topCauses: topCauses)
    }

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
    public static func parseEventTable(_ document: XctraceQueryDocument) -> EventTable {
        var durations: [Int] = []
        var labels: [String: Int] = [:]

        for row in document.rows {
            let record = document.record(for: row)
            if let duration = parseInt(record["duration"]) { durations.append(duration) }
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

    public struct TimeProfile: Codable, Equatable {
        public struct Summary: Codable, Equatable {
            public var sampleCount: Int
            public var appOwnedFrameCount: Int
            public var fallbackSymbolicFrameCount: Int

            enum CodingKeys: String, CodingKey {
                case sampleCount = "sample_count"
                case appOwnedFrameCount = "app_owned_frame_count"
                case fallbackSymbolicFrameCount = "fallback_symbolic_frame_count"
            }
        }

        public struct Frame: Codable, Equatable {
            public var name: String
            public var samples: Int
        }

        public var summary: Summary
        public var topFrames: [Frame]
    }

    /// Walks each row's `<backtrace>` looking for the first symbolic frame, preferring frames
    /// whose binary path contains "Harness Monitor.app" / "Harness Monitor UI Testing.app".
    public static func parseTimeProfile(_ document: XctraceQueryDocument) -> TimeProfile {
        let appBundleTokens = ["Harness Monitor.app", "Harness Monitor UI Testing.app"]
        var appOwned: [String: Int] = [:]
        var symbolic: [String: Int] = [:]
        var sampleCount = 0

        for row in document.rows {
            sampleCount += 1
            guard let backtrace = resolveBacktrace(in: row, document: document) else { continue }
            var firstSymbolic: String?
            var firstAppOwned: String?

            for frame in iterBacktraceFrames(backtrace, document: document) {
                guard isSymbolicFrame(frame.name) else { continue }
                if firstSymbolic == nil { firstSymbolic = frame.name }
                if appBundleTokens.contains(where: { frame.binaryPath.contains($0) }) {
                    firstAppOwned = frame.name
                    break
                }
            }

            if let firstSymbolic { symbolic[firstSymbolic, default: 0] += 1 }
            if let firstAppOwned { appOwned[firstAppOwned, default: 0] += 1 }
        }

        let source = !appOwned.isEmpty ? appOwned : symbolic
        let topFrames = source
            .sorted { $0.value > $1.value }
            .prefix(12)
            .map { TimeProfile.Frame(name: $0.key, samples: $0.value) }

        let summary = TimeProfile.Summary(
            sampleCount: sampleCount,
            appOwnedFrameCount: appOwned.values.reduce(0, +),
            fallbackSymbolicFrameCount: symbolic.values.reduce(0, +)
        )
        return TimeProfile(summary: summary, topFrames: topFrames)
    }

    private static func resolveBacktrace(in row: XMLElement, document: XctraceQueryDocument) -> XMLElement? {
        let children = row.children?.compactMap { $0 as? XMLElement } ?? []
        for child in children {
            guard let resolved = document.dereference(child) else { continue }
            if resolved.name == "backtrace" { return resolved }
        }
        return nil
    }

    private struct ResolvedFrame {
        var name: String
        var binaryPath: String
    }

    private static func iterBacktraceFrames(_ backtrace: XMLElement, document: XctraceQueryDocument) -> [ResolvedFrame] {
        backtrace.elements(forName: "frame").compactMap { frame -> ResolvedFrame? in
            guard let resolved = document.dereference(frame) else { return nil }
            var binaryPath = ""
            if let binary = resolved.elements(forName: "binary").first {
                if binary.attribute(forName: "ref") != nil,
                   let derefBinary = document.dereference(binary)
                {
                    binaryPath = derefBinary.attribute(forName: "path")?.stringValue ?? ""
                } else {
                    binaryPath = binary.attribute(forName: "path")?.stringValue ?? ""
                }
            }
            return ResolvedFrame(
                name: resolved.attribute(forName: "name")?.stringValue ?? "",
                binaryPath: binaryPath
            )
        }
    }

    private static func isSymbolicFrame(_ name: String) -> Bool {
        if name.isEmpty || name == "<deduplicated_symbol>" { return false }
        if name.hasPrefix("0x") { return false }
        return true
    }

    /// Mirrors `Counter.most_common(n)` - keeps top n entries by count.
    private static func topNCounter(_ counts: [String: Int], n: Int) -> [String: Int] {
        let sorted = counts.sorted { $0.value > $1.value }.prefix(n)
        return Dictionary(uniqueKeysWithValues: sorted.map { ($0.key, $0.value) })
    }

    private struct CauseKey: Hashable {
        var source: String
        var destination: String
        var label: String
    }
}
