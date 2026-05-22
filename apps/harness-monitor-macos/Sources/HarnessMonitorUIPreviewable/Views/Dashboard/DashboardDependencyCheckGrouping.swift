import Foundation
import HarnessMonitorKit

struct DashboardDependencyCheckGroup: Equatable, Identifiable {
  let id: String
  let title: String
  let checks: [DependencyUpdateCheck]

  var checkCountLabel: String {
    "\(checks.count) \(checks.count == 1 ? "check" : "checks")"
  }

  var displayPriority: Int {
    checks.map(\.displayPriority).min() ?? Int.max
  }
}

func dashboardDependencyCheckGroups(
  for checks: [DependencyUpdateCheck]
) -> [DashboardDependencyCheckGroup] {
  var buckets: [String: [DependencyUpdateCheck]] = [:]
  var titlesByID: [String: String] = [:]

  for check in checks {
    let title = dashboardDependencyCheckWorkflowTitle(for: check)
    let id = dashboardDependencyCheckGroupID(for: check, title: title)
    buckets[id, default: []].append(check)
    titlesByID[id] = titlesByID[id] ?? title
  }

  return buckets.map { id, groupedChecks in
    DashboardDependencyCheckGroup(
      id: id,
      title: titlesByID[id] ?? "Other checks",
      checks: dashboardDependencySortedChecks(groupedChecks)
    )
  }
  .sorted { lhs, rhs in
    if lhs.displayPriority != rhs.displayPriority {
      return lhs.displayPriority < rhs.displayPriority
    }
    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
  }
}

func dashboardDependencySortedChecks(
  _ checks: [DependencyUpdateCheck]
) -> [DependencyUpdateCheck] {
  checks.sorted { lhs, rhs in
    if lhs.displayPriority != rhs.displayPriority {
      return lhs.displayPriority < rhs.displayPriority
    }
    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
  }
}

func dashboardDependencyCheckWorkflowTitle(for check: DependencyUpdateCheck) -> String {
  let name = check.name.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !name.isEmpty else {
    return check.checkSuiteID.map { "Suite \($0.suffix(6))" } ?? "Other checks"
  }
  if let slashRange = name.range(of: " / ") {
    return String(name[..<slashRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  if let parentheticalRange = name.range(of: " (", options: .backwards),
    name.hasSuffix(")")
  {
    let prefix = String(name[..<parentheticalRange.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !prefix.isEmpty {
      return prefix
    }
  }
  return name
}

private func dashboardDependencyCheckGroupID(
  for check: DependencyUpdateCheck,
  title: String
) -> String {
  if let checkSuiteID = check.checkSuiteID, !checkSuiteID.isEmpty {
    return "suite:\(checkSuiteID)"
  }
  return "workflow:\(title.lowercased())"
}
