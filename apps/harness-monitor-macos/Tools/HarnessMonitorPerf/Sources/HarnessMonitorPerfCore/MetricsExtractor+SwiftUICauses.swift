extension MetricsExtractor {
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

    public static func parseCauseFindings(_ causes: Causes) -> [CaptureFinding] {
        causes.topCauses
            .filter {
                $0.sourceNode != "<unknown>"
                    || $0.destinationNode != "<unknown>"
            }
            .prefix(6)
            .map { cause in
                let headline = "\(cause.label): \(cause.sourceNode) -> \(cause.destinationNode)"
                return CaptureFinding(
                    key: [
                        "cause",
                        slug(cause.label),
                        slug(cause.sourceNode),
                        slug(cause.destinationNode),
                    ].joined(separator: ":"),
                    category: "swiftui-cause",
                    headline: headline,
                    detail: nil,
                    count: cause.count
                )
            }
    }

    private struct CauseKey: Hashable {
        var source: String
        var destination: String
        var label: String
    }
}
