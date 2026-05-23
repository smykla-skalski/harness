import Foundation
import HarnessMonitorKit

struct DashboardReviewCheckGroup: Equatable, Identifiable {
  let id: String
  let title: String
  let checks: [ReviewCheck]

  var checkCountLabel: String {
    "\(checks.count) \(checks.count == 1 ? "check" : "checks")"
  }

  var displayPriority: Int {
    checks.map(\.displayPriority).min() ?? Int.max
  }
}

func dashboardReviewCheckGroups(
  for checks: [ReviewCheck]
) -> [DashboardReviewCheckGroup] {
  var buckets: [String: [ReviewCheck]] = [:]
  var titlesByID: [String: String] = [:]

  for check in checks {
    let title = dashboardReviewCheckWorkflowTitle(for: check)
    let id = dashboardReviewCheckGroupID(for: check, title: title)
    buckets[id, default: []].append(check)
    titlesByID[id] = titlesByID[id] ?? title
  }

  return buckets.map { id, groupedChecks in
    DashboardReviewCheckGroup(
      id: id,
      title: titlesByID[id] ?? "Other checks",
      checks: dashboardReviewSortedChecks(groupedChecks)
    )
  }
  .sorted { lhs, rhs in
    if lhs.displayPriority != rhs.displayPriority {
      return lhs.displayPriority < rhs.displayPriority
    }
    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
  }
}

func dashboardReviewSortedChecks(
  _ checks: [ReviewCheck]
) -> [ReviewCheck] {
  checks.sorted { lhs, rhs in
    if lhs.displayPriority != rhs.displayPriority {
      return lhs.displayPriority < rhs.displayPriority
    }
    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
  }
}

func dashboardReviewCheckWorkflowTitle(for check: ReviewCheck) -> String {
  let name = check.name.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !name.isEmpty else {
    return check.checkSuiteID.map { "Suite \($0.suffix(6))" } ?? "Other checks"
  }
  let raw: String
  if let slashRange = name.range(of: " / ") {
    raw = String(name[..<slashRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
  } else if let parentheticalRange = name.range(of: " (", options: .backwards),
    name.hasSuffix(")") {
    let prefix = String(name[..<parentheticalRange.lowerBound])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    raw = prefix.isEmpty ? name : prefix
  } else {
    raw = name
  }
  return dashboardReviewCheckTitleCapitalizingFirstLetter(raw)
}

func dashboardReviewCheckTitleCapitalizingFirstLetter(_ title: String) -> String {
  guard let first = title.first else { return title }
  if first.isUppercase || !first.isLetter { return title }
  return String(first).uppercased() + title.dropFirst()
}

private func dashboardReviewCheckGroupID(
  for check: ReviewCheck,
  title: String
) -> String {
  if let checkSuiteID = check.checkSuiteID, !checkSuiteID.isEmpty {
    return "suite:\(checkSuiteID)"
  }
  return "workflow:\(title.lowercased())"
}
