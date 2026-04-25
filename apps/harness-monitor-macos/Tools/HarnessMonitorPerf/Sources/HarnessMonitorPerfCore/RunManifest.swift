import Foundation

/// Read/write model for `manifest.json` and `summary.json` under
/// `tmp/perf/harness-monitor-instruments/runs/{ts}-{label}/`. The inline `JSONValue` slots
/// preserve git/system/targets blocks the audit script writes without forcing this CLI to
/// model every embedded field.
public struct RunManifest: Codable, Equatable {
    public var label: String?
    public var createdAtUTC: String?
    public var git: JSONValue?
    public var system: JSONValue?
    public var targets: JSONValue?
    public var selectedScenarios: [String]?
    public var captures: [Capture]

    enum CodingKeys: String, CodingKey {
        case label
        case createdAtUTC = "created_at_utc"
        case git
        case system
        case targets
        case selectedScenarios = "selected_scenarios"
        case captures
    }

    public struct Capture: Codable, Equatable {
        public var scenario: String
        public var template: String
        public var durationSeconds: Double?
        public var traceRelpath: String?
        public var exitStatus: Int?
        public var endReason: String?
        /// Present in summary.json (filled by Summarizer); absent in manifest.json.
        public var metrics: JSONValue?

        enum CodingKeys: String, CodingKey {
            case scenario
            case template
            case durationSeconds = "duration_seconds"
            case traceRelpath = "trace_relpath"
            case exitStatus = "exit_status"
            case endReason = "end_reason"
            case metrics
        }
    }

    public init(
        label: String? = nil,
        createdAtUTC: String? = nil,
        git: JSONValue? = nil,
        system: JSONValue? = nil,
        targets: JSONValue? = nil,
        selectedScenarios: [String]? = nil,
        captures: [Capture] = []
    ) {
        self.label = label
        self.createdAtUTC = createdAtUTC
        self.git = git
        self.system = system
        self.targets = targets
        self.selectedScenarios = selectedScenarios
        self.captures = captures
    }
}
