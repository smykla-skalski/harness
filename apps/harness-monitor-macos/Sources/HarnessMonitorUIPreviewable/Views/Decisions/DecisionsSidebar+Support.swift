import HarnessMonitorKit
import SwiftUI

extension DecisionSeverity {
  public var sortKey: Int {
    switch self {
    case .critical: 4
    case .needsUser: 3
    case .warn: 2
    case .info: 1
    }
  }

  public var chipLabel: String {
    switch self {
    case .critical: "Critical"
    case .needsUser: "Needs user"
    case .warn: "Warn"
    case .info: "Info"
    }
  }

  var chipColor: Color {
    switch self {
    case .critical: HarnessMonitorTheme.danger
    case .needsUser: HarnessMonitorTheme.warmAccent
    case .warn: HarnessMonitorTheme.caution
    case .info: HarnessMonitorTheme.accent
    }
  }

  static var sidebarOrdering: [DecisionSeverity] {
    allCases.sorted { $0.sortKey > $1.sortKey }
  }
}

public enum DecisionsSidebarViewModel {
  public struct FilterState: Equatable {
    public let query: String
    public let severities: Set<DecisionSeverity>
    public let scope: DecisionsSidebarSearchScope

    public init(
      query: String,
      severities: Set<DecisionSeverity>,
      scope: DecisionsSidebarSearchScope
    ) {
      self.query = query
      self.severities = severities
      self.scope = scope
    }
  }

  public struct VisibleSnapshot: Equatable {
    public let groups: [SessionGroup]
    public let decisionIDs: [String]
    public let signature: String
  }

  public struct SessionGroup: Equatable {
    public let sessionID: String?
    public let decisions: [Decision]

    public init(sessionID: String?, decisions: [Decision]) {
      self.sessionID = sessionID
      self.decisions = decisions
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.sessionID == rhs.sessionID && lhs.decisions.map(\.id) == rhs.decisions.map(\.id)
    }
  }

  public static func grouped(
    decisions: [Decision],
    query: String,
    severities: Set<DecisionSeverity>
  ) -> [SessionGroup] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = decisions.filter { decision in
      guard let severity = DecisionSeverity(rawValue: decision.severityRaw) else { return false }
      if !severities.isEmpty, !severities.contains(severity) { return false }
      if trimmedQuery.isEmpty { return true }
      return decision.summary.range(of: trimmedQuery, options: .caseInsensitive) != nil
    }

    let buckets = Dictionary(grouping: filtered) { $0.sessionID }
    return buckets.map { key, rows in
      SessionGroup(sessionID: key, decisions: sortedBySeverity(rows))
    }.sorted(by: sessionGroupOrdering)
  }

  public static func visibleSnapshot(
    decisions: [Decision],
    filters: FilterState
  ) -> VisibleSnapshot {
    let trimmed = filters.query.trimmingCharacters(in: .whitespacesAndNewlines)
    let scoped: [Decision]
    if trimmed.isEmpty {
      scoped = decisions
    } else {
      scoped = decisions.filter { filters.scope.matches($0, trimmedQuery: trimmed) }
    }
    let summaryQuery = filters.scope == .summary ? trimmed : ""
    let groups = grouped(
      decisions: scoped,
      query: summaryQuery,
      severities: filters.severities
    )
    let ids = groups.flatMap(\.decisions).map(\.id)
    let severitySignature = filters.severities.map(\.rawValue).sorted().joined(separator: ",")
    let signature = "scope=\(filters.scope.rawValue);query=\(trimmed);sev=\(severitySignature)"
    return VisibleSnapshot(groups: groups, decisionIDs: ids, signature: signature)
  }

  private static func sortedBySeverity(_ decisions: [Decision]) -> [Decision] {
    decisions.sorted { lhs, rhs in
      let leftKey = DecisionSeverity(rawValue: lhs.severityRaw)?.sortKey ?? 0
      let rightKey = DecisionSeverity(rawValue: rhs.severityRaw)?.sortKey ?? 0
      if leftKey != rightKey { return leftKey > rightKey }
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
      return lhs.id < rhs.id
    }
  }

  private static func sessionGroupOrdering(_ lhs: SessionGroup, _ rhs: SessionGroup) -> Bool {
    switch (lhs.sessionID, rhs.sessionID) {
    case (nil, nil):
      return false
    case (nil, _):
      return false
    case (_, nil):
      return true
    case (let left?, let right?):
      let leftEarliest = lhs.decisions.map(\.createdAt).min() ?? Date.distantFuture
      let rightEarliest = rhs.decisions.map(\.createdAt).min() ?? Date.distantFuture
      if leftEarliest != rightEarliest {
        return leftEarliest < rightEarliest
      }
      return left < right
    }
  }
}

extension HarnessMonitorAccessibility {
  public static let decisionsSidebarSearch = "harness.decisions.sidebar.search"
  public static let decisionsSidebarSearchScopeMenu = "harness.decisions.sidebar.search.scope"
  public static let decisionsSidebarFilterToggle = "harness.decisions.sidebar.filter.toggle"
  public static let decisionsSidebarAllChip = "harness.decisions.sidebar.chip.all"

  public static func decisionsSidebarSeverityChip(_ raw: String) -> String {
    "harness.decisions.sidebar.chip.\(slug(raw))"
  }
}
