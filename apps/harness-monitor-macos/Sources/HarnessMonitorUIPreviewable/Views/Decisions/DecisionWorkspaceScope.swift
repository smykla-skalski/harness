import Foundation
import HarnessMonitorKit

public struct DecisionWorkspaceScope: Equatable {
  let decisions: [Decision]
  let filters: DecisionsSidebarViewModel.FilterState
  let visibleSnapshot: DecisionsSidebarViewModel.VisibleSnapshot
  let selectedDecisionID: String?

  public init(
    decisions: [Decision],
    filters: DecisionsSidebarViewModel.FilterState,
    selectedDecisionID: String? = nil
  ) {
    self.decisions = decisions
    self.filters = filters
    self.visibleSnapshot = DecisionsSidebarViewModel.visibleSnapshot(
      decisions: decisions,
      filters: filters
    )
    self.selectedDecisionID = selectedDecisionID
  }

  var groups: [DecisionsSidebarViewModel.SessionGroup] {
    visibleSnapshot.groups
  }

  var visibleDecisionIDs: [String] {
    visibleSnapshot.decisionIDs
  }

  var visibleDecisions: [Decision] {
    groups.flatMap(\.decisions)
  }

  var selectedDecision: Decision? {
    guard let selectedDecisionID else {
      return nil
    }
    return decisions.first { $0.id == selectedDecisionID }
  }

  var totalCount: Int {
    decisions.count
  }

  var visibleCount: Int {
    visibleDecisionIDs.count
  }

  var criticalCount: Int {
    visibleDecisions.count(whereSeverityIs: .critical)
  }

  var needsUserCount: Int {
    visibleDecisions.count(whereSeverityIs: .needsUser)
  }

  var visibleCriticalDecisionIDs: [String] {
    visibleDecisions.ids(whereSeverityIs: .critical)
  }

  var visibleInfoDecisionIDs: [String] {
    visibleDecisions.ids(whereSeverityIs: .info)
  }

  var hasActiveFilters: Bool {
    hasSearchQuery || hasSeverityFilters
  }

  var countLabel: String {
    hasActiveFilters ? "\(visibleCount)/\(totalCount)" : "\(totalCount)"
  }

  var resultSummary: String {
    guard totalCount > 0 else {
      return "Decisions and related activity"
    }
    if hasActiveFilters {
      return "\(visibleCount) of \(totalCount) in view"
    }
    guard criticalCount > 0 else {
      return "\(totalCount) open decisions"
    }
    return "\(totalCount) open · \(criticalCount) critical"
  }

  var scopeDescription: String {
    var segments: [String] = []
    if hasSearchQuery {
      segments.append("\(filters.scope.label) matching \"\(trimmedQuery)\"")
    }
    if hasSeverityFilters {
      let severities = DecisionSeverity.sidebarOrdering
        .filter { filters.severities.contains($0) }
        .map(\.chipLabel)
        .joined(separator: ", ")
      segments.append("Severity: \(severities)")
    }
    return segments.isEmpty ? "All open decisions" : segments.joined(separator: " · ")
  }

  var emptyStateTitle: String {
    totalCount == 0 ? "No active decisions" : "No matching decisions"
  }

  var emptyStateDescription: String {
    if totalCount == 0 {
      return "This area fills in when the workspace needs attention."
    }
    if hasActiveFilters {
      return "Clear filters or broaden the search scope to bring decisions back into view."
    }
    return "Broaden the search scope to bring decisions back into view."
  }

  private var trimmedQuery: String {
    filters.query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var hasSearchQuery: Bool {
    !trimmedQuery.isEmpty
  }

  private var hasSeverityFilters: Bool {
    !filters.severities.isEmpty
  }
}

extension Array where Element == Decision {
  fileprivate func count(whereSeverityIs severity: DecisionSeverity) -> Int {
    reduce(into: 0) { count, decision in
      if decision.severityRaw == severity.rawValue {
        count += 1
      }
    }
  }

  fileprivate func ids(whereSeverityIs severity: DecisionSeverity) -> [String] {
    filter { $0.severityRaw == severity.rawValue }.map(\.id)
  }
}
