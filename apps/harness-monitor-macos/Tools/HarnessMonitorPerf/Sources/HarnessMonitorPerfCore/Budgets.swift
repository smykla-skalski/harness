import Foundation

/// Per-scenario budgets for SwiftUI and Allocations Instruments templates.
public enum Budgets {
    public struct SwiftUIBudget: Codable, Equatable, Sendable {
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

    public struct AllocationsBudget: Codable, Equatable, Sendable {
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

    public static let swiftUIByScenario: [String: SwiftUIBudget] = Dictionary(
        PerfScenarioDefinitions.all.compactMap { definition in
            guard let budget = definition.swiftUIBudget else {
                return nil
            }
            return (definition.id, budget)
        },
        uniquingKeysWith: { existing, _ in existing }
    )

    public static let allocationsByScenario: [String: AllocationsBudget] = Dictionary(
        PerfScenarioDefinitions.all.compactMap { definition in
            guard let budget = definition.allocationsBudget else {
                return nil
            }
            return (definition.id, budget)
        },
        uniquingKeysWith: { existing, _ in existing }
    )

    /// Maximum size of a retained run directory under tmp/perf/harness-monitor-instruments/runs/.
    public static let retainedRunSizeKiB: Int = 10_240
}
