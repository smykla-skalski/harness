import Foundation

extension MetricsExtractor {
    public struct Allocations: Codable, Equatable {
        public struct Snapshot: Codable, Equatable {
            public var summaryRows: [String: [String: Int]]
            public var categoryCount: Int

            enum CodingKeys: String, CodingKey {
                case summaryRows = "summary_rows"
                case categoryCount = "category_count"
            }
        }

        public struct Offender: Codable, Equatable {
            public var category: String
            public var persistentBytes: Int
            public var totalBytes: Int
            public var countEvents: Int

            enum CodingKeys: String, CodingKey {
                case category
                case persistentBytes = "persistent_bytes"
                case totalBytes = "total_bytes"
                case countEvents = "count_events"
            }
        }

        public var allocations: Snapshot
        public var topOffenders: [Offender]
    }

    public static let allocationsSummaryCategories: [String] = [
        "All Heap & Anonymous VM",
        "All Heap Allocations",
        "All Anonymous VM",
        "All VM Regions",
    ]

    /// Parses the Statistics detail of an Allocations track. Each `<row>` is a flat element
    /// with attributes such as `persistent_bytes`, `total_bytes`, `count_events`.
    public static func parseAllocationsStatistics(data: Data) throws -> Allocations {
        let document = try XMLDocument(data: data, options: [.nodePreserveAttributeOrder])
        guard let root = document.rootElement() else {
            throw XctraceQueryDocument.ParseError.missingRootElement
        }
        let rowElements = (try? root.nodes(forXPath: ".//row"))?.compactMap { $0 as? XMLElement } ?? []
        var rows: [String: [String: Int]] = [:]
        for row in rowElements {
            guard
                let category = row.attribute(forName: "category")?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !category.isEmpty
            else { continue }
            var entry: [String: Int] = [:]
            for case let attribute as XMLNode in row.attributes ?? [] {
                guard
                    let name = attribute.name,
                    name != "category",
                    let value = attribute.stringValue,
                    let intValue = Int(value)
                else { continue }
                entry[name.replacingOccurrences(of: "-", with: "_")] = intValue
            }
            rows[category] = entry
        }

        var summaryRows: [String: [String: Int]] = [:]
        for category in allocationsSummaryCategories {
            summaryRows[category] = rows[category] ?? [:]
        }

        let topOffenders = rows
            .sorted { lhs, rhs in
                let lp = lhs.value["persistent_bytes"] ?? 0
                let rp = rhs.value["persistent_bytes"] ?? 0
                if lp != rp { return lp > rp }
                let lt = lhs.value["total_bytes"] ?? 0
                let rt = rhs.value["total_bytes"] ?? 0
                if lt != rt { return lt > rt }
                return (lhs.value["count_events"] ?? 0) > (rhs.value["count_events"] ?? 0)
            }
            .prefix(15)
            .map { entry in
                Allocations.Offender(
                    category: entry.key,
                    persistentBytes: entry.value["persistent_bytes"] ?? 0,
                    totalBytes: entry.value["total_bytes"] ?? 0,
                    countEvents: entry.value["count_events"] ?? 0
                )
            }

        return Allocations(
            allocations: .init(summaryRows: summaryRows, categoryCount: rows.count),
            topOffenders: topOffenders
        )
    }
}
