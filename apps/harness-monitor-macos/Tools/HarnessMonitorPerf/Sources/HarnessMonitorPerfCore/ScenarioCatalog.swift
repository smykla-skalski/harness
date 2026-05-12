import Foundation

/// Static scenario catalog shared by the audit CLI, manifest writer, and tests.
public enum ScenarioCatalog {
    private static let visualOptionsSuffix = "-visual-options-disabled"

    public static let all: [String] = [
        "open-recent-window",
        "open-session-window",
        "open-session-window-visual-options-disabled",
        "agent-detail-form",
        "agent-detail-form-visual-options-disabled",
        "decision-detail-form",
        "decision-detail-form-visual-options-disabled",
        "task-detail-form",
        "task-detail-form-visual-options-disabled",
        "session-search-full",
        "session-search-full-visual-options-disabled",
        "sidebar-toggle-rich-detail",
        "sidebar-toggle-rich-detail-visual-options-disabled",
        "timeline-filter-form",
        "timeline-filter-form-visual-options-disabled",
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
        "open-session-window-visual-options-disabled",
        "agent-detail-form",
        "agent-detail-form-visual-options-disabled",
        "decision-detail-form",
        "decision-detail-form-visual-options-disabled",
        "task-detail-form",
        "task-detail-form-visual-options-disabled",
        "session-search-full",
        "session-search-full-visual-options-disabled",
        "sidebar-toggle-rich-detail",
        "sidebar-toggle-rich-detail-visual-options-disabled",
        "timeline-filter-form",
        "timeline-filter-form-visual-options-disabled",
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
        switch baseScenario(for: scenario) {
        case "open-recent-window": return 6
        case "open-session-window": return 8
        case "agent-detail-form": return 8
        case "decision-detail-form": return 8
        case "task-detail-form": return 8
        case "session-search-full": return 8
        case "sidebar-toggle-rich-detail": return 8
        case "timeline-filter-form": return 8
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
        switch baseScenario(for: scenario) {
        case "open-recent-window", "open-session-window",
             "agent-detail-form", "task-detail-form", "session-search-full",
             "sidebar-toggle-rich-detail",
             "timeline-filter-form", "timeline-burst", "toast-overlay-churn":
            return "dashboard-landing"
        case "decision-detail-form", "permission-modal":
            return "cockpit"
        case "settings-backdrop-cycle", "settings-background-cycle":
            return "dashboard"
        case "offline-cached-open": return "offline-cached"
        default: return "dashboard"
        }
    }

    private static func baseScenario(for scenario: String) -> String {
        guard scenario.hasSuffix(visualOptionsSuffix) else {
            return scenario
        }
        return String(scenario.dropLast(visualOptionsSuffix.count))
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
