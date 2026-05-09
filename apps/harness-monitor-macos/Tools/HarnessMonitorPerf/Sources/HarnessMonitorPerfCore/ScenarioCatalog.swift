import Foundation

/// Static scenario catalog shared by the audit CLI, manifest writer, and tests.
public enum ScenarioCatalog {
    public static let all: [String] = [
        "open-recent-window",
        "open-session-window",
        "permission-modal",
        "settings-backdrop-cycle",
        "settings-background-cycle",
        "timeline-burst",
        "toast-overlay-churn",
        "offline-cached-open",
    ]

    public static let swiftUI: Set<String> = [
        "open-recent-window",
        "open-session-window",
        "permission-modal",
        "timeline-burst",
        "toast-overlay-churn",
        "offline-cached-open",
    ]

    public static let allocations: Set<String> = [
        "settings-backdrop-cycle",
        "settings-background-cycle",
        "offline-cached-open",
    ]

    public static func durationSeconds(for scenario: String) -> Int {
        switch scenario {
        case "open-recent-window": return 6
        case "open-session-window": return 8
        case "permission-modal": return 8
        case "settings-backdrop-cycle": return 9
        case "settings-background-cycle": return 10
        case "timeline-burst": return 8
        case "toast-overlay-churn": return 8
        case "offline-cached-open": return 7
        default: return 8
        }
    }

    public static func previewScenario(for scenario: String) -> String {
        switch scenario {
        case "open-recent-window", "open-session-window", "timeline-burst", "toast-overlay-churn":
            return "dashboard-landing"
        case "permission-modal":
            return "cockpit"
        case "settings-backdrop-cycle", "settings-background-cycle": return "dashboard"
        case "offline-cached-open": return "offline-cached"
        default: return "dashboard"
        }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public static func resolve(_ selection: String) throws -> [String] {
        if selection == "all" { return all }
        let known = Set(all)
        let parts = selection.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        var out: [String] = []
        for raw in parts where !raw.isEmpty {
            guard known.contains(raw) else {
                throw Failure(message: "unknown scenario: \(raw)")
            }
            out.append(raw)
        }
        if out.isEmpty {
            throw Failure(message: "no scenarios selected")
        }
        return out
    }
}
