import Foundation

/// Reads a run directory laid out by the audit pipeline and emits `summary.json` plus
/// `summary.csv`. Mirrors the python tail of `extract-instruments-metrics.py` (lines 100-117
/// and `write_summary_csv`), so downstream consumers (compare, dashboards) can keep treating
/// the JSON+CSV outputs as the canonical artefacts.
public enum Summarizer {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Drive the full summary write for `runDir`. `runDir/manifest.json` must exist and
    /// `runDir/metrics/{scenario}/{template-slug}.json` must exist for every capture.
    @discardableResult
    public static func summarize(runDir: URL) throws -> RunManifest {
        let manifestURL = runDir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw Failure(message: "manifest.json not found under \(runDir.path)")
        }
        let manifestData = try Data(contentsOf: manifestURL)
        var manifest = try JSONDecoder().decode(RunManifest.self, from: manifestData)

        let metricsRoot = runDir.appendingPathComponent("metrics")
        var enrichedCaptures: [RunManifest.Capture] = []
        for capture in manifest.captures {
            let templateSlug = templateSlug(capture.template)
            let metricsURL = metricsRoot
                .appendingPathComponent(capture.scenario)
                .appendingPathComponent("\(templateSlug).json")
            guard FileManager.default.fileExists(atPath: metricsURL.path) else {
                throw Failure(message: "metrics file missing: \(metricsURL.path)")
            }
            let metrics = try JSONValue.fromFile(metricsURL)
            var enriched = capture
            enriched.metrics = metrics
            enrichedCaptures.append(enriched)
        }
        manifest.captures = enrichedCaptures

        try writeSummaryJSON(manifest: manifest, to: runDir.appendingPathComponent("summary.json"))
        try writeSummaryCSV(captures: enrichedCaptures, to: runDir.appendingPathComponent("summary.csv"))
        return manifest
    }

    public static func templateSlug(_ template: String) -> String {
        template.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    static func writeSummaryJSON(manifest: RunManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    static let csvHeader: [String] = [
        "scenario",
        "template",
        "duration_seconds",
        "exit_status",
        "end_reason",
        "swiftui_total_updates",
        "swiftui_body_updates",
        "swiftui_p95_ms",
        "swiftui_max_ms",
        "swiftui_update_group_p95_ms",
        "swiftui_top_group_label",
        "swiftui_top_cause_source",
        "hitches",
        "potential_hangs",
        "alloc_all_heap_and_vm_persistent_bytes",
        "alloc_all_heap_and_vm_total_bytes",
        "alloc_all_vm_regions_persistent_bytes",
        "alloc_all_vm_regions_total_bytes",
    ]

    static func writeSummaryCSV(captures: [RunManifest.Capture], to url: URL) throws {
        var lines: [String] = [csvHeader.joined(separator: ",")]
        for capture in captures {
            lines.append(csvRow(for: capture))
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        try data.write(to: url, options: .atomic)
    }

    private static func csvRow(for capture: RunManifest.Capture) -> String {
        let metrics = capture.metrics ?? .object([:])
        let swiftui = metrics["swiftui_updates"] ?? .object([:])
        let updateGroups = metrics["swiftui_update_groups"] ?? .object([:])
        let causes = metrics["swiftui_causes"] ?? .object([:])
        let allocations = metrics["allocations"]?["summary_rows"] ?? .object([:])
        let heapVM = allocations["All Heap & Anonymous VM"] ?? .object([:])
        let vmRegions = allocations["All VM Regions"] ?? .object([:])

        let topGroupLabel = firstKey(in: updateGroups["label_counts"]) ?? ""
        let topCauseSource = firstKey(in: causes["source_node_counts"]) ?? ""

        let durationNsMax = swiftui["duration_ns_max"]?.intValue ?? 0
        let swiftuiMaxMs: String = swiftui.isEmptyObject ? "" : formatDouble(MetricsExtractor.nsToMs(durationNsMax))

        let fields: [String] = [
            csvEscape(capture.scenario),
            csvEscape(capture.template),
            string(capture.durationSeconds),
            string(capture.exitStatus),
            csvEscape(capture.endReason ?? ""),
            string(swiftui["total_count"]?.intValue),
            string(swiftui["body_update_count"]?.intValue),
            string(swiftui["duration_ms_p95"]?.doubleValue),
            swiftuiMaxMs,
            string(updateGroups["duration_ms_p95"]?.doubleValue),
            csvEscape(topGroupLabel),
            csvEscape(topCauseSource),
            string(metrics["hitches"]?["count"]?.intValue),
            string(metrics["potential_hangs"]?["count"]?.intValue),
            string(heapVM["persistent_bytes"]?.intValue),
            string(heapVM["total_bytes"]?.intValue),
            string(vmRegions["persistent_bytes"]?.intValue),
            string(vmRegions["total_bytes"]?.intValue),
        ]
        return fields.joined(separator: ",")
    }

    private static func string(_ value: Int?) -> String {
        guard let value else { return "" }
        return String(value)
    }

    private static func string(_ value: Double?) -> String {
        guard let value else { return "" }
        return formatDouble(value)
    }

    private static func formatDouble(_ value: Double) -> String {
        if value == value.rounded() { return String(Int64(value)) }
        return String(value)
    }

    /// Mirrors `next(iter(dict), "")` over a JSONValue object - returns the first inserted key
    /// the encoder produced (Counter.most_common keeps insertion order so the python output is
    /// deterministic).
    private static func firstKey(in value: JSONValue?) -> String? {
        guard case .object(let dict) = value else { return nil }
        return dict.keys.sorted().first
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }
}

extension JSONValue {
    static func fromFile(_ url: URL) throws -> JSONValue {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    var isEmptyObject: Bool {
        if case .object(let dict) = self { return dict.isEmpty }
        return true
    }
}
