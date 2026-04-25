import Foundation

/// Enforces per-scenario performance budgets against an instruments run `summary.json`.
public enum BudgetEnforcer {
    public struct Failure: Error, CustomStringConvertible {
        public let messages: [String]
        public var description: String {
            "Instruments metric budgets failed:\n" + messages.map { "- \($0)" }.joined(separator: "\n")
        }
    }

    /// Validate all captures inside a summary payload. Throws `Failure` when any budget exceeded.
    public static func enforce(summaryJSON: Data) throws {
        let failures = collectFailures(summaryJSON: summaryJSON)
        if !failures.isEmpty { throw Failure(messages: failures) }
    }

    /// Collect failures without throwing - useful for tests and structured reporting.
    public static func collectFailures(summaryJSON: Data) -> [String] {
        guard
            let root = try? JSONSerialization.jsonObject(with: summaryJSON) as? [String: Any],
            let captures = root["captures"] as? [[String: Any]]
        else { return [] }

        var failures: [String] = []
        for capture in captures {
            let template = capture["template"] as? String
            switch template {
            case "SwiftUI":
                failures.append(contentsOf: swiftUIFailures(capture))
            case "Allocations":
                failures.append(contentsOf: allocationsFailures(capture))
            default:
                continue
            }
        }
        return failures
    }

    private static func swiftUIFailures(_ capture: [String: Any]) -> [String] {
        guard let scenario = capture["scenario"] as? String else { return [] }
        let metrics = capture["metrics"] as? [String: Any] ?? [:]
        let budget = Budgets.swiftUIByScenario[scenario] ?? Budgets.defaultSwiftUI

        let totalUpdates = number(metrics, "swiftui_updates", "total_count")
        let bodyUpdates = number(metrics, "swiftui_updates", "body_update_count")
        let maxGroupMillis = number(metrics, "swiftui_update_groups", "duration_ns_max") / 1_000_000
        let hitches = number(metrics, "hitches", "count")
        let hangs = number(metrics, "potential_hangs", "count")

        let checks: [(String, Double, Double)] = [
            ("total_updates", totalUpdates, budget.totalUpdates),
            ("body_updates", bodyUpdates, budget.bodyUpdates),
            ("max_update_group_ms", maxGroupMillis, budget.maxUpdateGroupMilliseconds),
            ("hitches", hitches, budget.hitches),
            ("potential_hangs", hangs, budget.potentialHangs),
        ]
        return checks.compactMap { name, value, limit in
            value > limit
                ? "\(scenario) SwiftUI \(name) exceeded budget: \(format(value)) > \(format(limit))"
                : nil
        }
    }

    private static func allocationsFailures(_ capture: [String: Any]) -> [String] {
        guard
            let scenario = capture["scenario"] as? String,
            let budget = Budgets.allocationsByScenario[scenario]
        else { return [] }

        let metrics = capture["metrics"] as? [String: Any] ?? [:]
        let allocations = metrics["allocations"] as? [String: Any] ?? [:]
        let summaryRows = allocations["summary_rows"] as? [String: Any] ?? [:]
        let heap = summaryRows["All Heap Allocations"] as? [String: Any] ?? [:]
        let totalBytes = (heap["total_bytes"] as? NSNumber)?.doubleValue ?? 0

        guard totalBytes > budget.heapTotalBytes else { return [] }
        return [
            "\(scenario) Allocations heap_total_bytes exceeded budget: "
                + "\(format(totalBytes)) > \(format(budget.heapTotalBytes))"
        ]
    }

    private static func number(_ root: [String: Any], _ path: String...) -> Double {
        var current: Any = root
        for key in path {
            guard let dict = current as? [String: Any], let next = dict[key] else { return 0 }
            current = next
        }
        if let num = current as? NSNumber { return num.doubleValue }
        return 0
    }

    private static func format(_ value: Double) -> String {
        // Match python `f"{value:g}"` shortest representation.
        if value == value.rounded(), abs(value) < 1e16 {
            return String(Int64(value))
        }
        return String(value)
    }
}
