import Foundation

public enum MetricBudgetTier: String, Codable, Equatable, Sendable {
    case hardBudget = "hard_budget"
    case investigative
}

public enum MetricName {
    public static let launchAppInitToReadyMs = "launch_app_init_to_ready_ms"
    public static let totalUpdates = "total_updates"
    public static let bodyUpdates = "body_updates"
    public static let maxUpdateGroupMs = "max_update_group_ms"
    public static let p95UpdateMs = "p95_update_ms"
    public static let maxUpdateMs = "max_update_ms"
    public static let updateGroupP95Ms = "update_group_p95_ms"
    public static let hitches = "hitches"
    public static let potentialHangs = "potential_hangs"
    public static let timeProfileSampleCount = "time_profile_sample_count"
    public static let timeProfileAppOwnedFrameCount = "time_profile_app_owned_frame_count"
    public static let timeProfileFallbackSymbolicFrameCount =
        "time_profile_fallback_symbolic_frame_count"
    public static let heapTotalBytes = "heap_total_bytes"
}

public struct CaptureLaunchMetrics: Codable, Equatable, Sendable {
    public var appInitToReadyMilliseconds: Double
    public var measuredFrom: String
    public var stateLabel: String
    public var windowID: String
    public var includesBootstrapInScenarioMeasurement: Bool

    enum CodingKeys: String, CodingKey {
        case appInitToReadyMilliseconds = "app_init_to_ready_ms"
        case measuredFrom = "measured_from"
        case stateLabel = "state_label"
        case windowID = "window_id"
        case includesBootstrapInScenarioMeasurement = "includes_bootstrap_in_scenario_measurement"
    }

    static func fromFile(_ url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

public struct CaptureMetricTiers: Codable, Equatable, Sendable {
    public var hardBudget: [String]
    public var investigative: [String]

    enum CodingKeys: String, CodingKey {
        case hardBudget = "hard_budget"
        case investigative
    }
}

enum MetricTierCatalog {
    static func tiers(
        for scenario: String,
        template: String
    ) -> CaptureMetricTiers {
        var hardBudget: [String] = []
        var investigative: [String] = []

        if Budgets.launchByScenario[scenario] != nil {
            hardBudget.append(MetricName.launchAppInitToReadyMs)
        } else {
            investigative.append(MetricName.launchAppInitToReadyMs)
        }

        switch template {
        case "SwiftUI":
            let budget = Budgets.swiftUIByScenario[scenario] ?? Budgets.defaultSwiftUI
            let p95HasBudget = budget.p95UpdateMilliseconds != nil
            let groupP95HasBudget = budget.updateGroupP95Milliseconds != nil
            hardBudget.append(
                contentsOf: [
                    MetricName.totalUpdates,
                    MetricName.bodyUpdates,
                    MetricName.maxUpdateGroupMs,
                    MetricName.hitches,
                    MetricName.potentialHangs,
                ]
            )
            if p95HasBudget {
                hardBudget.append(MetricName.p95UpdateMs)
            } else {
                investigative.append(MetricName.p95UpdateMs)
            }
            if groupP95HasBudget {
                hardBudget.append(MetricName.updateGroupP95Ms)
            } else {
                investigative.append(MetricName.updateGroupP95Ms)
            }
            investigative.append(
                contentsOf: [
                    MetricName.maxUpdateMs,
                    MetricName.timeProfileSampleCount,
                    MetricName.timeProfileAppOwnedFrameCount,
                    MetricName.timeProfileFallbackSymbolicFrameCount,
                    "top_group_label",
                    "top_cause_source",
                    "top_frames",
                    "top_offenders",
                    "top_update_groups",
                    "top_causes",
                ]
            )
        case "Allocations":
            hardBudget.append(MetricName.heapTotalBytes)
            investigative.append(
                contentsOf: [
                    "all_heap_anonymous_vm_persistent_bytes",
                    "all_heap_anonymous_vm_total_bytes",
                    "all_heap_allocations_persistent_bytes",
                    "all_heap_allocations_count_events",
                    "all_anonymous_vm_persistent_bytes",
                    "all_anonymous_vm_total_bytes",
                    "all_vm_regions_persistent_bytes",
                    "all_vm_regions_total_bytes",
                    "all_vm_regions_count_events",
                ]
            )
        default:
            break
        }

        return CaptureMetricTiers(
            hardBudget: hardBudget,
            investigative: investigative
        )
    }
}
