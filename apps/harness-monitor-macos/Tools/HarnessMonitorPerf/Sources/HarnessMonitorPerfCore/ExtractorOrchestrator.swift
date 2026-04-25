import Foundation

/// Drives the parse-and-write pipeline that `extract-instruments-metrics.py main()` performs.
/// Reads `manifest.json`, runs `xctrace export` for each capture's expected schemas, parses
/// every XML, and writes:
///   - `metrics/{scenario}/{template-slug}.json`
///   - `metrics/{scenario}/top-offenders.json`
///   - `summary.json`, `summary.csv` via Summarizer
///
/// The `XctraceExporting` protocol abstracts xctrace so tests can feed pre-baked XML payloads
/// without invoking Instruments.
public enum ExtractorOrchestrator {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public protocol XctraceExporting {
        /// Emits a TOC payload for `tracePath`.
        func exportTOC(tracePath: URL) throws -> Data
        /// Emits a query payload for `tracePath` filtered by `xpath`.
        func exportQuery(tracePath: URL, xpath: String) throws -> Data
    }

    public struct ProcessXctrace: XctraceExporting {
        public var command: String
        public var arguments: [String]
        public var tempRoot: URL

        public init(command: String, arguments: [String], tempRoot: URL) {
            self.command = command
            self.arguments = arguments
            self.tempRoot = tempRoot
        }

        public func exportTOC(tracePath: URL) throws -> Data {
            try export(tracePath: tracePath, extra: ["--toc"])
        }

        public func exportQuery(tracePath: URL, xpath: String) throws -> Data {
            try export(tracePath: tracePath, extra: ["--xpath", xpath])
        }

        private func export(tracePath: URL, extra: [String]) throws -> Data {
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            let result = try ProcessRunner.runChecked(
                command,
                arguments: arguments + ["export", "--input", tracePath.path] + extra,
                environmentOverrides: ["TMPDIR": tempRoot.path + "/"]
            )
            return result.stdout
        }
    }

    public static let swiftUISchemaXPaths: [(name: String, xpath: String)] = [
        ("swiftui-updates", "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"swiftui-updates\"]"),
        ("swiftui-update-groups", "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"swiftui-update-groups\"]"),
        ("swiftui-causes", "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"swiftui-causes\"]"),
        ("hitches", "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"hitches\"]"),
        ("potential-hangs", "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"potential-hangs\"]"),
        ("time-profile", "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"time-profile\"]"),
    ]

    public static let allocationsXPath =
        "/trace-toc/run[@number=\"1\"]/tracks/track[@name=\"Allocations\"]/details/detail[@name=\"Statistics\"]"

    /// Runs the full extractor pipeline against `runDir`, then invokes Summarizer.
    @discardableResult
    public static func extract(
        runDir: URL,
        exporter: XctraceExporting
    ) throws -> RunManifest {
        let manifestURL = runDir.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw Failure(message: "manifest.json not found under \(runDir.path)")
        }
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(RunManifest.self, from: manifestData)

        let metricsRoot = runDir.appendingPathComponent("metrics", isDirectory: true)
        try FileManager.default.createDirectory(at: metricsRoot, withIntermediateDirectories: true)

        var topOffendersByScenario: [String: [String: JSONValue]] = [:]

        for capture in manifest.captures {
            guard let traceRelpath = capture.traceRelpath else { continue }
            let tracePath = runDir.appendingPathComponent(traceRelpath)
            let metrics = try extractCaptureMetrics(
                capture: capture, tracePath: tracePath, exporter: exporter
            )
            let scenarioRoot = metricsRoot.appendingPathComponent(capture.scenario, isDirectory: true)
            try FileManager.default.createDirectory(at: scenarioRoot, withIntermediateDirectories: true)
            let templateSlug = Summarizer.templateSlug(capture.template)
            let metricsURL = scenarioRoot.appendingPathComponent("\(templateSlug).json")
            try writePretty(metrics, to: metricsURL)

            let offenders = metrics["top_offenders"] ?? .array([])
            topOffendersByScenario[capture.scenario, default: [:]][capture.template] = offenders
        }

        for (scenario, offenders) in topOffendersByScenario {
            let scenarioRoot = metricsRoot.appendingPathComponent(scenario, isDirectory: true)
            let url = scenarioRoot.appendingPathComponent("top-offenders.json")
            try writePretty(.object(offenders), to: url)
        }

        return try Summarizer.summarize(runDir: runDir)
    }

    /// Parses every available schema for the capture's template and merges into the canonical
    /// metrics JSON shape the python emitter writes.
    public static func extractCaptureMetrics(
        capture: RunManifest.Capture,
        tracePath: URL,
        exporter: XctraceExporting
    ) throws -> JSONValue {
        let tocData = try exporter.exportTOC(tracePath: tracePath)
        let toc = try XctraceTOC(data: tocData)
        let availableSchemas = toc.availableSchemas()
        let availableAllocDetails = toc.availableAllocationDetails()

        switch capture.template {
        case "SwiftUI":
            return try extractSwiftUI(
                tracePath: tracePath, exporter: exporter,
                availableSchemas: availableSchemas
            )
        case "Allocations":
            return try extractAllocations(
                tracePath: tracePath, exporter: exporter,
                availableAllocDetails: availableAllocDetails,
                availableSchemas: availableSchemas
            )
        default:
            throw Failure(message: "Unsupported template \(capture.template)")
        }
    }

    private static func extractSwiftUI(
        tracePath: URL, exporter: XctraceExporting, availableSchemas: Set<String>
    ) throws -> JSONValue {
        var documents: [String: XctraceQueryDocument] = [:]
        for schema in swiftUISchemaXPaths {
            guard availableSchemas.contains(schema.name) else { continue }
            let data = try exporter.exportQuery(tracePath: tracePath, xpath: schema.xpath)
            documents[schema.name] = try XctraceQueryDocument(data: data)
        }

        let updates = documents["swiftui-updates"].map { MetricsExtractor.parseSwiftUIUpdates($0) }
        let updateGroups = documents["swiftui-update-groups"].map { MetricsExtractor.parseSwiftUIUpdateGroups($0) }
        let causes = documents["swiftui-causes"].map { MetricsExtractor.parseSwiftUICauses($0) }
        let hitches = documents["hitches"].map { MetricsExtractor.parseEventTable($0) }
        let hangs = documents["potential-hangs"].map { MetricsExtractor.parseEventTable($0) }
        let profile = documents["time-profile"].map { MetricsExtractor.parseTimeProfile($0) }

        var root: [String: JSONValue] = [:]
        root["swiftui_updates"] = updates.map { encodeJSON($0.summary) } ?? .object([:])
        root["swiftui_update_groups"] = updateGroups.map { encodeJSON($0.summary) } ?? .object([:])
        root["swiftui_causes"] = causes.map { encodeJSON($0.summary) } ?? .object([:])
        root["hitches"] = hitches.map { encodeJSON($0) } ?? .object([:])
        root["potential_hangs"] = hangs.map { encodeJSON($0) } ?? .object([:])
        root["time_profile"] = profile.map { encodeJSON($0.summary) } ?? .object([:])
        root["top_offenders"] = updates.map { encodeJSON($0.topOffenders) } ?? .array([])
        root["top_update_groups"] = updateGroups.map { encodeJSON($0.topGroups) } ?? .array([])
        root["top_causes"] = causes.map { encodeJSON($0.topCauses) } ?? .array([])
        root["top_frames"] = profile.map { encodeJSON($0.topFrames) } ?? .array([])
        root["available_schemas"] = .array(availableSchemas.sorted().map(JSONValue.string))
        return .object(root)
    }

    private static func extractAllocations(
        tracePath: URL, exporter: XctraceExporting,
        availableAllocDetails: Set<String>, availableSchemas: Set<String>
    ) throws -> JSONValue {
        var rootObject: [String: JSONValue] = [:]
        if availableAllocDetails.contains("Statistics") {
            let data = try exporter.exportQuery(tracePath: tracePath, xpath: allocationsXPath)
            let parsed = try MetricsExtractor.parseAllocationsStatistics(data: data)
            rootObject["allocations"] = encodeJSON(parsed.allocations)
            rootObject["top_offenders"] = encodeJSON(parsed.topOffenders)
        } else {
            rootObject["allocations"] = .object([
                "summary_rows": .object(Dictionary(uniqueKeysWithValues:
                    MetricsExtractor.allocationsSummaryCategories.map { ($0, JSONValue.object([:])) }
                )),
                "category_count": .int(0),
            ])
            rootObject["top_offenders"] = .array([])
        }
        rootObject["available_schemas"] = .array(availableSchemas.sorted().map(JSONValue.string))
        return .object(rootObject)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let data = try? encoder.encode(value),
            let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .null }
        return decoded
    }

    private static func writePretty(_ value: JSONValue, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}
