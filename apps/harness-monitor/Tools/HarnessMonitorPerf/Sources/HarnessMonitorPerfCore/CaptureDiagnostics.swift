import Foundation

public struct CaptureAppTrace: Codable, Equatable {
    public struct ComponentCount: Codable, Equatable {
        public var component: String
        public var count: Int
    }

    public struct StepTiming: Codable, Equatable {
        public var step: String
        public var startTimestamp: String
        public var endTimestamp: String
        public var durationMilliseconds: Double

        enum CodingKeys: String, CodingKey {
            case step
            case startTimestamp = "start_timestamp"
            case endTimestamp = "end_timestamp"
            case durationMilliseconds = "duration_ms"
        }
    }

    public var relpath: String
    public var eventCount: Int
    public var components: [ComponentCount]
    public var orderedSteps: [String]
    public var stepTimings: [StepTiming]

    enum CodingKeys: String, CodingKey {
        case relpath
        case eventCount = "event_count"
        case components
        case orderedSteps = "ordered_steps"
        case stepTimings = "step_timings"
    }

    public init(
        relpath: String,
        eventCount: Int,
        components: [ComponentCount],
        orderedSteps: [String],
        stepTimings: [StepTiming] = []
    ) {
        self.relpath = relpath
        self.eventCount = eventCount
        self.components = components
        self.orderedSteps = orderedSteps
        self.stepTimings = stepTimings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        relpath = try container.decode(String.self, forKey: .relpath)
        eventCount = try container.decode(Int.self, forKey: .eventCount)
        components = try container.decode([ComponentCount].self, forKey: .components)
        orderedSteps = try container.decode([String].self, forKey: .orderedSteps)
        stepTimings = try container.decodeIfPresent([StepTiming].self, forKey: .stepTimings) ?? []
    }
}

public struct CaptureFinding: Codable, Equatable, Hashable {
    public var key: String
    public var category: String
    public var headline: String
    public var detail: String?
    public var count: Int?
}

enum AuditArtifactPaths {
    static let perfArtifactsDirectoryKey = "HARNESS_MONITOR_PERF_ARTIFACTS_DIR"
    static let appTraceFileName = "app-trace.jsonl"

    static func appTraceRelpath(scenario: String, templateSlug: String) -> String {
        "app-traces/\(scenario)/\(templateSlug)/\(appTraceFileName)"
    }

    static func appTraceDirectory(
        runDir: URL,
        scenario: String,
        templateSlug: String
    ) -> URL {
        runDir
            .appendingPathComponent("app-traces", isDirectory: true)
            .appendingPathComponent(scenario, isDirectory: true)
            .appendingPathComponent(templateSlug, isDirectory: true)
    }

    static func appTraceURL(runDir: URL, relpath: String) -> URL {
        runDir.appendingPathComponent(relpath)
    }
}

enum AppTraceParser {
    struct TraceEvent: Codable, Equatable {
        var timestamp: String
        var component: String
        var event: String
        var details: [String: String]
    }

    static func summarize(fileURL: URL, relpath: String) throws -> CaptureAppTrace {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)

        var componentCounts: [String: Int] = [:]
        var orderedSteps: [String] = []
        var stepTimings: [CaptureAppTrace.StepTiming] = []
        var openSteps: [String: AppTraceStepStart] = [:]
        var eventCount = 0

        for line in lines {
            guard let event = try? decoder.decode(TraceEvent.self, from: Data(line.utf8)) else {
                continue
            }
            eventCount += 1
            componentCounts[event.component, default: 0] += 1
            if stepEventBeginsOrderedStep(event),
               let step = event.details["step"], !step.isEmpty {
                orderedSteps.append(step)
            }
            if event.event == "step.begin",
               let step = event.details["step"], !step.isEmpty,
               let start = parseTimestamp(event.timestamp) {
                openSteps[step] = AppTraceStepStart(timestamp: event.timestamp, date: start)
            } else if event.event == "step.end",
                      let step = event.details["step"], !step.isEmpty,
                      let start = openSteps.removeValue(forKey: step),
                      let end = parseTimestamp(event.timestamp) {
                stepTimings.append(
                    CaptureAppTrace.StepTiming(
                        step: step,
                        startTimestamp: start.timestamp,
                        endTimestamp: event.timestamp,
                        durationMilliseconds: max(0, end.timeIntervalSince(start.date) * 1_000)
                    )
                )
            }
        }

        let components = componentCounts
            .map { CaptureAppTrace.ComponentCount(component: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count {
                    return $0.count > $1.count
                }
                return $0.component < $1.component
            }

        return CaptureAppTrace(
            relpath: relpath,
            eventCount: eventCount,
            components: components,
            orderedSteps: orderedSteps,
            stepTimings: stepTimings
        )
    }

    private struct AppTraceStepStart {
        var timestamp: String
        var date: Date
    }

    private static func stepEventBeginsOrderedStep(_ event: TraceEvent) -> Bool {
        event.event == "step" || event.event == "step.begin"
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: raw)
    }
}
