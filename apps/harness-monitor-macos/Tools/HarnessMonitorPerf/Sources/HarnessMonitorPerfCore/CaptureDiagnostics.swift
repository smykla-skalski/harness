import Foundation

public struct CaptureAppTrace: Codable, Equatable {
    public struct ComponentCount: Codable, Equatable {
        public var component: String
        public var count: Int
    }

    public var relpath: String
    public var eventCount: Int
    public var components: [ComponentCount]
    public var orderedSteps: [String]

    enum CodingKeys: String, CodingKey {
        case relpath
        case eventCount = "event_count"
        case components
        case orderedSteps = "ordered_steps"
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
        var eventCount = 0

        for line in lines {
            guard let event = try? decoder.decode(TraceEvent.self, from: Data(line.utf8)) else {
                continue
            }
            eventCount += 1
            componentCounts[event.component, default: 0] += 1
            if event.event == "step", let step = event.details["step"], !step.isEmpty {
                orderedSteps.append(step)
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
            orderedSteps: orderedSteps
        )
    }
}
