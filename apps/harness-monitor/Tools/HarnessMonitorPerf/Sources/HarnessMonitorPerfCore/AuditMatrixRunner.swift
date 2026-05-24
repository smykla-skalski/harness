import Foundation

public enum AuditMatrixRunner {
    public struct Outcome {
        public var matrixDir: URL
        public var summaryPath: URL
        public var markdownPath: URL
    }

    struct MatrixSummary: Codable {
        var label: String
        var createdAtUTC: String
        var scenarios: [String]
        var variants: [AuditVariant]
        var runs: [VariantRun]

        enum CodingKeys: String, CodingKey {
            case label
            case createdAtUTC = "created_at_utc"
            case scenarios
            case variants
            case runs
        }
    }

    struct VariantRun: Codable {
        var variant: String
        var runDir: String?
        var summaryPath: String?
        var error: String?
        var metrics: [ScenarioMetrics]

        enum CodingKeys: String, CodingKey {
            case variant
            case runDir = "run_dir"
            case summaryPath = "summary_path"
            case error
            case metrics
        }
    }

    struct ScenarioMetrics: Codable {
        var scenario: String
        var template: String
        var totalUpdates: Int?
        var bodyUpdates: Int?
        var maxUpdateGroupMs: Double?
        var hitches: Int?
        var potentialHangs: Int?
        var deltaTotalUpdates: Int?
        var deltaBodyUpdates: Int?

        enum CodingKeys: String, CodingKey {
            case scenario
            case template
            case totalUpdates = "total_updates"
            case bodyUpdates = "body_updates"
            case maxUpdateGroupMs = "max_update_group_ms"
            case hitches
            case potentialHangs = "potential_hangs"
            case deltaTotalUpdates = "delta_total_updates"
            case deltaBodyUpdates = "delta_body_updates"
        }
    }

    public static func run(
        _ inputs: AuditRunner.Inputs,
        variants: [AuditVariant]
    ) throws -> Outcome {
        let matrixDir = inputs.runsRoot.appendingPathComponent(
            "\(AuditRunner.utcCompactTimestamp())-\(slug(inputs.label))-matrix",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: matrixDir, withIntermediateDirectories: true)

        let scenarios = try ScenarioCatalog.resolve(inputs.scenarioSelection)
        var runs: [VariantRun] = []
        var baselineByKey: [MetricKey: ScenarioMetrics] = [:]

        for variant in variants {
            var runInputs = inputs
            runInputs.label = "\(inputs.label)-\(variant.id)"
            runInputs.enforceBudgets = false
            runInputs.environmentOverrides = inputs.environmentOverrides
                .merging(variant.environment) { _, variantValue in variantValue }
            do {
                let outcome = try AuditRunner.run(runInputs)
                var metrics = try readMetrics(from: outcome.summaryPath)
                if baselineByKey.isEmpty {
                    baselineByKey = Dictionary(uniqueKeysWithValues: metrics.map {
                        (MetricKey($0), $0)
                    })
                } else {
                    metrics = metrics.map { metric in
                        var copy = metric
                        if let baseline = baselineByKey[MetricKey(metric)] {
                            copy.deltaTotalUpdates = delta(metric.totalUpdates, baseline.totalUpdates)
                            copy.deltaBodyUpdates = delta(metric.bodyUpdates, baseline.bodyUpdates)
                        }
                        return copy
                    }
                }
                runs.append(
                    VariantRun(
                        variant: variant.id,
                        runDir: outcome.runDir.path,
                        summaryPath: outcome.summaryPath.path,
                        error: nil,
                        metrics: metrics
                    )
                )
            } catch {
                runs.append(
                    VariantRun(
                        variant: variant.id,
                        runDir: nil,
                        summaryPath: nil,
                        error: String(describing: error),
                        metrics: []
                    )
                )
            }
        }

        let summary = MatrixSummary(
            label: inputs.label,
            createdAtUTC: AuditRunner.utcExtendedTimestamp(),
            scenarios: scenarios,
            variants: variants,
            runs: runs
        )
        let summaryPath = matrixDir.appendingPathComponent("matrix-summary.json")
        let markdownPath = matrixDir.appendingPathComponent("matrix.md")
        try write(summary, to: summaryPath)
        try Data(markdown(summary).utf8).write(to: markdownPath, options: .atomic)
        return Outcome(matrixDir: matrixDir, summaryPath: summaryPath, markdownPath: markdownPath)
    }

    private static func readMetrics(from summaryPath: URL) throws -> [ScenarioMetrics] {
        let data = try Data(contentsOf: summaryPath)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let captures = root?["captures"] as? [[String: Any]] ?? []
        return captures.compactMap { capture in
            guard let scenario = capture["scenario"] as? String,
                  let template = capture["template"] as? String
            else { return nil }
            let metrics = capture["metrics"] as? [String: Any] ?? [:]
            return ScenarioMetrics(
                scenario: scenario,
                template: template,
                totalUpdates: int(metrics, "swiftui_updates", "total_count"),
                bodyUpdates: int(metrics, "swiftui_updates", "body_update_count"),
                maxUpdateGroupMs: double(metrics, "swiftui_update_groups", "duration_ns_max")
                    .map { $0 / 1_000_000 },
                hitches: int(metrics, "hitches", "count"),
                potentialHangs: int(metrics, "potential_hangs", "count"),
                deltaTotalUpdates: nil,
                deltaBodyUpdates: nil
            )
        }
    }

    private static func markdown(_ summary: MatrixSummary) -> String {
        var lines = [
            "# \(summary.label) matrix",
            "",
            "| Variant | Scenario | Template | Updates | Body | Max group ms | Hitches | Hangs | Delta updates | Delta body |",
            "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
        ]
        for run in summary.runs {
            if let error = run.error {
                lines.append("| \(run.variant) | error |  |  |  |  |  |  |  | \(escape(error)) |")
                continue
            }
            for metric in run.metrics {
                lines.append([
                    "| \(run.variant)",
                    metric.scenario,
                    metric.template,
                    text(metric.totalUpdates),
                    text(metric.bodyUpdates),
                    text(metric.maxUpdateGroupMs),
                    text(metric.hitches),
                    text(metric.potentialHangs),
                    text(metric.deltaTotalUpdates),
                    text(metric.deltaBodyUpdates) + " |",
                ].joined(separator: " | "))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func write(_ summary: MatrixSummary, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(to: url, options: .atomic)
    }

    private static func int(_ root: [String: Any], _ path: String...) -> Int? {
        number(root, path)?.intValue
    }

    private static func double(_ root: [String: Any], _ path: String...) -> Double? {
        number(root, path)?.doubleValue
    }

    private static func number(_ root: [String: Any], _ path: [String]) -> NSNumber? {
        var current: Any = root
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
            current = next
        }
        return current as? NSNumber
    }

    private static func delta(_ current: Int?, _ baseline: Int?) -> Int? {
        guard let current, let baseline else { return nil }
        return current - baseline
    }

    private static func text<T>(_ value: T?) -> String {
        value.map { "\($0)" } ?? ""
    }

    private static func slug(_ label: String) -> String {
        label.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
    }

    private struct MetricKey: Hashable {
        var scenario: String
        var template: String

        init(_ metric: ScenarioMetrics) {
            scenario = metric.scenario
            template = metric.template
        }
    }
}
