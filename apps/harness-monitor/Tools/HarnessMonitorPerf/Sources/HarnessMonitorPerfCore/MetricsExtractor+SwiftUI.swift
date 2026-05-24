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

    public static func parseSwiftUIUpdateGroups(
        _ document: XctraceQueryDocument,
        maximumValidDurationNs: Int? = nil
    ) -> UpdateGroups {
        var durations: [Int] = []
        var labelCounts: [String: Int] = [:]
        var labelTotals: [String: (count: Int, durationNs: Int)] = [:]

        for row in document.rows {
            let record = document.record(for: row)
            let label = normalize(record["label"])
            let durationNs = parseDurationNs(
                record["duration"],
                maximumValidDurationNs: maximumValidDurationNs
            ) ?? 0
            if durationNs > 0 { durations.append(durationNs) }
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

    public static func deriveSwiftUIFindings(
        updateGroupsDocument: XctraceQueryDocument?,
        causes: Causes?
    ) -> [CaptureFinding] {
        var findings: [CaptureFinding] = []
        if let updateGroupsDocument {
            findings.append(contentsOf: parseUpdateGroupFindings(updateGroupsDocument))
        }
        if let causes {
            findings.append(contentsOf: parseCauseFindings(causes))
        }
        return deduplicatedFindings(findings)
    }

    public static func parseUpdateGroupFindings(
        _ document: XctraceQueryDocument,
        maximumValidDurationNs: Int? = nil
    ) -> [CaptureFinding] {
        struct Aggregate {
            var key: String
            var category: String
            var headline: String
            var detail: String?
            var count: Int
            var durationNs: Int
        }

        var aggregates: [String: Aggregate] = [:]
        for row in document.rows {
            let record = document.record(for: row)
            let label = normalize(record["label"])
            guard
                let prototype = updateGroupFindingPrototype(
                    for: row,
                    label: label,
                    document: document
                )
            else {
                continue
            }
            let durationNs = parseDurationNs(
                record["duration"],
                maximumValidDurationNs: maximumValidDurationNs
            ) ?? 0
            var aggregate = aggregates[prototype.key] ?? Aggregate(
                key: prototype.key,
                category: prototype.category,
                headline: prototype.headline,
                detail: prototype.detail,
                count: 0,
                durationNs: 0
            )
            aggregate.count += 1
            aggregate.durationNs += durationNs
            aggregates[prototype.key] = aggregate
        }

        return aggregates.values
            .sorted {
                if $0.count != $1.count {
                    return $0.count > $1.count
                }
                if $0.durationNs != $1.durationNs {
                    return $0.durationNs > $1.durationNs
                }
                return $0.key < $1.key
            }
            .prefix(8)
            .map {
                CaptureFinding(
                    key: $0.key,
                    category: $0.category,
                    headline: $0.headline,
                    detail: $0.detail,
                    count: $0.count
                )
            }
    }
}
