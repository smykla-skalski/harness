import Foundation

/// Per-scenario budgets for SwiftUI and Allocations Instruments templates.
///
/// Mirrors the python tables in `Scripts/run-instruments-audit.sh` exactly so the Swift CLI
/// produces identical pass/fail verdicts on the same `summary.json` inputs. Update both sides
/// when adding scenarios; golden fixtures under `Tests/.../Fixtures/` lock the cross-check.
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
        "launch-dashboard": SwiftUIBudget(
            totalUpdates: 25_000, bodyUpdates: 2_500,
            maxUpdateGroupMilliseconds: 50, hitches: 0, potentialHangs: 0
        ),
        "select-session-cockpit": SwiftUIBudget(
            totalUpdates: 35_000, bodyUpdates: 3_500,
            maxUpdateGroupMilliseconds: 50, hitches: 0, potentialHangs: 0
        ),
        "refresh-and-search": SwiftUIBudget(
            totalUpdates: 30_000, bodyUpdates: 3_000,
            maxUpdateGroupMilliseconds: 50, hitches: 0, potentialHangs: 0
        ),
        "timeline-burst": SwiftUIBudget(
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
