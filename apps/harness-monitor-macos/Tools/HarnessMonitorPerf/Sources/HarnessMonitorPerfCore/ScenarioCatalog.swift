import Foundation

/// Static catalog mirroring the ALL_SCENARIOS / SWIFTUI_SCENARIOS / ALLOCATIONS_SCENARIOS
/// arrays plus duration_for/preview_scenario_for switch tables in run-instruments-audit.sh.
public enum ScenarioCatalog {
    public static let all: [String] = [
        "launch-dashboard",
        "select-session-cockpit",
        "refresh-and-search",
        "sidebar-overflow-search",
        "settings-backdrop-cycle",
        "settings-background-cycle",
        "timeline-burst",
        "toast-overlay-churn",
        "offline-cached-open",
    ]

    public static let swiftUI: Set<String> = [
        "launch-dashboard",
        "select-session-cockpit",
        "refresh-and-search",
        "sidebar-overflow-search",
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
        case "launch-dashboard": return 6
        case "select-session-cockpit": return 8
        case "refresh-and-search": return 10
        case "sidebar-overflow-search": return 8
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
        case "launch-dashboard", "select-session-cockpit": return "dashboard-landing"
        case "settings-backdrop-cycle", "settings-background-cycle": return "dashboard"
        case "refresh-and-search", "sidebar-overflow-search": return "overflow"
        case "timeline-burst", "toast-overlay-churn": return "cockpit"
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
