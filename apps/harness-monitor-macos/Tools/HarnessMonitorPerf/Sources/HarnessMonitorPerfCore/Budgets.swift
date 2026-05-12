import Foundation

/// Per-scenario budgets for SwiftUI and Allocations Instruments templates.
public enum Budgets {
    public struct SwiftUIBudget: Equatable, Sendable {
        public var totalUpdates: Double
        public var bodyUpdates: Double
        public var maxUpdateGroupMilliseconds: Double
        public var hitches: Double
        public var potentialHangs: Double

        public init(
            totalUpdates: Double,
            bodyUpdates: Double,
            maxUpdateGroupMilliseconds: Double,
            hitches: Double,
            potentialHangs: Double
        ) {
            self.totalUpdates = totalUpdates
            self.bodyUpdates = bodyUpdates
            self.maxUpdateGroupMilliseconds = maxUpdateGroupMilliseconds
            self.hitches = hitches
            self.potentialHangs = potentialHangs
        }
    }

    public struct AllocationsBudget: Equatable, Sendable {
        public var heapTotalBytes: Double
        public init(heapTotalBytes: Double) { self.heapTotalBytes = heapTotalBytes }
    }

    public static let defaultSwiftUI = SwiftUIBudget(
        totalUpdates: 35_000,
        bodyUpdates: 3_500,
        maxUpdateGroupMilliseconds: 50,
        hitches: 0,
        potentialHangs: 0
    )

    public static let swiftUIByScenario: [String: SwiftUIBudget] = [
        "open-recent-window": SwiftUIBudget(
            totalUpdates: 25_000, bodyUpdates: 2_500,
            maxUpdateGroupMilliseconds: 50, hitches: 0, potentialHangs: 0
        ),
        "open-session-window": SwiftUIBudget(
            totalUpdates: 35_000, bodyUpdates: 3_500,
            maxUpdateGroupMilliseconds: 50, hitches: 0, potentialHangs: 0
        ),
        "agent-detail-form": SwiftUIBudget(
            totalUpdates: 35_000, bodyUpdates: 3_500,
            maxUpdateGroupMilliseconds: 50, hitches: 0, potentialHangs: 0
        ),
        "decision-detail-form": SwiftUIBudget(
            totalUpdates: 35_000, bodyUpdates: 3_500,
            maxUpdateGroupMilliseconds: 50, hitches: 0, potentialHangs: 0
        ),
        "task-detail-form": SwiftUIBudget(
            totalUpdates: 35_000, bodyUpdates: 3_500,
            maxUpdateGroupMilliseconds: 50, hitches: 0, potentialHangs: 0
        ),
        "session-search-full": SwiftUIBudget(
            totalUpdates: 35_000, bodyUpdates: 3_500,
            maxUpdateGroupMilliseconds: 50, hitches: 0, potentialHangs: 0
        ),
        "timeline-filter-form": SwiftUIBudget(
            totalUpdates: 35_000, bodyUpdates: 3_500,
            maxUpdateGroupMilliseconds: 50, hitches: 0, potentialHangs: 0
        ),
        "permission-modal": SwiftUIBudget(
            totalUpdates: 35_000, bodyUpdates: 3_500,
            maxUpdateGroupMilliseconds: 50, hitches: 0, potentialHangs: 0
        ),
        "timeline-burst": SwiftUIBudget(
            totalUpdates: 30_000, bodyUpdates: 3_000,
            maxUpdateGroupMilliseconds: 50, hitches: 0, potentialHangs: 0
        ),
        "toast-overlay-churn": SwiftUIBudget(
            totalUpdates: 35_000, bodyUpdates: 3_500,
            maxUpdateGroupMilliseconds: 50, hitches: 0, potentialHangs: 0
        ),
        "offline-cached-open": SwiftUIBudget(
            totalUpdates: 30_000, bodyUpdates: 3_000,
            maxUpdateGroupMilliseconds: 50, hitches: 0, potentialHangs: 0
        ),
    ]

    public static let allocationsByScenario: [String: AllocationsBudget] = [
        "settings-background-cycle": AllocationsBudget(heapTotalBytes: 350 * 1024 * 1024),
        "settings-backdrop-cycle": AllocationsBudget(heapTotalBytes: 350 * 1024 * 1024),
        "offline-cached-open": AllocationsBudget(heapTotalBytes: 300 * 1024 * 1024),
    ]

    /// Maximum size of a retained run directory under tmp/perf/harness-monitor-instruments/runs/.
    public static let retainedRunSizeKiB: Int = 10_240
}
