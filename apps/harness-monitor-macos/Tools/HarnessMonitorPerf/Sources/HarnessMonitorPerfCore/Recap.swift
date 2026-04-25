import Foundation

/// Renders a one-line-per-capture recap of an audit run, plus optional delta values when a
/// comparison.json sits alongside summary.json. Direct port of summarize-instruments-run.py.
public enum Recap {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Reads `runDir/summary.json` (and `runDir/comparison.json` if present) and returns the
    /// rendered recap. Throws when summary.json is missing.
    public static func render(runDir: URL, topCount: Int) throws -> String {
        let summaryURL = runDir.appendingPathComponent("summary.json")
        guard FileManager.default.fileExists(atPath: summaryURL.path) else {
            throw Failure(message: "summary.json not found under \(runDir.path)")
        }
        let summary = try JSONValue.fromFile(summaryURL)
        let comparisonURL = runDir.appendingPathComponent("comparison.json")
        let comparison: JSONValue? = FileManager.default.fileExists(atPath: comparisonURL.path)
            ? try JSONValue.fromFile(comparisonURL)
            : nil
        return render(summary: summary, comparison: comparison, topCount: max(topCount, 0))
    }

    public static func render(
        summary: JSONValue, comparison: JSONValue?, topCount: Int
    ) -> String {
        var lines: [String] = []
        lines.append("Run recap:")
        lines.append("- label=\(summary["label"]?.stringValue ?? "unknown")")
        lines.append("- run_id=\(summary["created_at_utc"]?.stringValue ?? "unknown")")

        if let git = summary["git"], let commit = git["commit"]?.stringValue {
            let dirty = formatDirty(git["dirty"])
            lines.append("- commit=\(commit) dirty=\(dirty)")
        }

        let comparisonIndex = buildComparisonIndex(comparison)
        let captures: [JSONValue] = {
            if case .array(let arr) = summary["captures"] ?? .array([]) { return arr }
            return []
        }()

        for capture in captures {
            let scenario = capture["scenario"]?.stringValue ?? "unknown"
            let template = capture["template"]?.stringValue ?? "unknown"
            let captureCompare = comparisonIndex[CaptureKey(scenario: scenario, template: template)]
            lines.append(contentsOf: renderCapture(
                capture: capture, comparison: captureCompare, topCount: topCount
            ))
        }

        return lines.joined(separator: "\n")
    }

    private static func renderCapture(
        capture: JSONValue, comparison: JSONValue?, topCount: Int
    ) -> [String] {
        let template = capture["template"]?.stringValue ?? "unknown"
        switch template {
        case "SwiftUI":
            return renderSwiftUI(capture: capture, comparison: comparison, topCount: topCount)
        case "Allocations":
            return renderAllocations(capture: capture)
        default:
            let scenario = capture["scenario"]?.stringValue ?? "unknown"
            return ["- \(scenario) [\(template)] unsupported capture summary"]
        }
    }

    private static func renderSwiftUI(
        capture: JSONValue, comparison: JSONValue?, topCount: Int
    ) -> [String] {
        let metrics = capture["metrics"] ?? .object([:])
        let swiftui = metrics["swiftui_updates"] ?? .object([:])
        let hitches = metrics["hitches"]?["count"]?.intValue ?? 0
        let hangs = metrics["potential_hangs"]?["count"]?.intValue ?? 0
        let maxMs = nsToMs(swiftui["duration_ns_max"]?.intValue ?? 0)
        let scenario = capture["scenario"]?.stringValue ?? "unknown"

        var line = "- \(scenario) [SwiftUI]: "
        line += "total_updates=\(swiftui["total_count"]?.intValue ?? 0) "
        line += "body_updates=\(swiftui["body_update_count"]?.intValue ?? 0) "
        line += "p95_ms=\(formatFloat(swiftui["duration_ms_p95"]?.doubleValue ?? 0)) "
        line += "max_ms=\(formatFloat(maxMs)) "
        line += "hitches=\(hitches) "
        line += "potential_hangs=\(hangs)"

        if let comparison {
            let deltaMetrics = comparison["metrics"] ?? .object([:])
            line += " d_total_updates=\(deltaValue(deltaMetrics["total_updates"]))"
            line += " d_body_updates=\(deltaValue(deltaMetrics["body_updates"]))"
            line += " d_hitches=\(deltaValue(deltaMetrics["hitches"]))"
            line += " d_potential_hangs=\(deltaValue(deltaMetrics["potential_hangs"]))"
        }

        var lines = [line]
        let offenders: [JSONValue] = {
            if case .array(let arr) = metrics["top_offenders"] ?? .array([]) { return arr }
            return []
        }()
        for (index, offender) in offenders.prefix(topCount).enumerated() {
            let description = offender["description"]?.stringValue ?? "<unknown>"
            let viewName = offender["view_name"]?.stringValue ?? "<unknown>"
            let durationMs = formatFloat(offender["duration_ms"]?.doubleValue ?? 0)
            let count = offender["count"]?.intValue ?? 0
            lines.append("  \(index + 1). \(description) | \(viewName) | duration_ms=\(durationMs) | count=\(count)")
        }
        return lines
    }

    private static func renderAllocations(capture: JSONValue) -> [String] {
        let metrics = capture["metrics"] ?? .object([:])
        let rows = metrics["allocations"]?["summary_rows"] ?? .object([:])
        let selectedCategories = ["All Heap & Anonymous VM", "All VM Regions"]
        var parts: [String] = []
        for category in selectedCategories {
            let row = rows[category] ?? .object([:])
            guard case .object(let dict) = row, !dict.isEmpty else { continue }
            let persistent = row["persistent_bytes"]?.intValue ?? 0
            let total = row["total_bytes"]?.intValue ?? 0
            parts.append("\(category): persistent_bytes=\(persistent) total_bytes=\(total)")
        }
        if parts.isEmpty { parts.append("no allocation summary rows") }
        let scenario = capture["scenario"]?.stringValue ?? "unknown"
        return ["- \(scenario) [Allocations]: " + parts.joined(separator: " ; ")]
    }

    private static func buildComparisonIndex(_ comparison: JSONValue?) -> [CaptureKey: JSONValue] {
        guard let comparison else { return [:] }
        let entries: [JSONValue] = {
            if case .array(let arr) = comparison["comparisons"] ?? .array([]) { return arr }
            return []
        }()
        var result: [CaptureKey: JSONValue] = [:]
        for entry in entries {
            let scenario = entry["scenario"]?.stringValue ?? ""
            let template = entry["template"]?.stringValue ?? ""
            result[CaptureKey(scenario: scenario, template: template)] = entry
        }
        return result
    }

    private static func deltaValue(_ block: JSONValue?) -> String {
        guard let block, let delta = block["delta"] else { return "n/a" }
        if case .double(let v) = delta { return formatFloat(v) }
        if case .int(let v) = delta { return String(v) }
        return "n/a"
    }

    private static func nsToMs(_ value: Int) -> Double { Double(value) / 1_000_000 }

    /// Match python's `str(True/False)` rendering. Other values fall through to their JSON
    /// string form so the recap surfaces unexpected types instead of swallowing them.
    private static func formatDirty(_ value: JSONValue?) -> String {
        guard let value else { return "None" }
        if case .bool(let b) = value { return b ? "True" : "False" }
        if let str = value.stringValue { return str }
        return "None"
    }

    private static func formatFloat(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private struct CaptureKey: Hashable {
        var scenario: String
        var template: String
    }
}
