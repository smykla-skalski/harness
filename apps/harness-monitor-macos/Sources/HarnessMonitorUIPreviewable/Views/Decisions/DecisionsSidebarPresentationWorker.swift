import Foundation
import HarnessMonitorKit
import OSLog

typealias DecisionPresentationItem = DecisionPresentationSnapshot

public struct DecisionsSidebarPresentationGroup: Equatable, Sendable, Identifiable {
  public let sessionID: String?
  public let decisionIDs: [String]
  fileprivate let earliestCreatedAt: Date

  public var id: String { sessionID ?? "__shared_context__" }
}

public struct DecisionsSidebarPresentation: Equatable, Sendable {
  static let empty = Self(
    groups: [],
    decisionIDs: [],
    signature: DecisionsSidebarViewModel.filterSignature(
      filters: .init(query: "", severities: [], scope: .summary)
    ),
    totalCount: 0,
    visibleCount: 0,
    criticalCount: 0,
    needsUserCount: 0,
    visibleCriticalDecisionIDs: [],
    visibleInfoDecisionIDs: [],
    hasActiveFilters: false,
    countLabel: "0",
    resultSummary: "Decisions and related activity",
    scopeDescription: "All open decisions",
    emptyStateTitle: "No active decisions",
    emptyStateDescription: "This area fills in when the workspace needs attention."
  )

  public let groups: [DecisionsSidebarPresentationGroup]
  public let decisionIDs: [String]
  public let signature: String
  public let totalCount: Int
  public let visibleCount: Int
  public let criticalCount: Int
  public let needsUserCount: Int
  public let visibleCriticalDecisionIDs: [String]
  public let visibleInfoDecisionIDs: [String]
  public let hasActiveFilters: Bool
  public let countLabel: String
  public let resultSummary: String
  public let scopeDescription: String
  public let emptyStateTitle: String
  public let emptyStateDescription: String
}

struct DecisionsSidebarPresentationInput: Equatable, Sendable {
  let items: [DecisionPresentationItem]
  let filters: DecisionsSidebarViewModel.FilterState
}

struct DecisionsSidebarPresentationTaskKey: Equatable {
  let decisionsRevision: UInt64
  let fallbackCount: Int
  let fallbackFirstID: String?
  let fallbackLastID: String?
  let filters: DecisionsSidebarViewModel.FilterState

  init(
    decisionsRevision: UInt64,
    decisions: [Decision],
    filters: DecisionsSidebarViewModel.FilterState
  ) {
    self.decisionsRevision = decisionsRevision
    fallbackCount = decisions.count
    fallbackFirstID = decisions.first?.id
    fallbackLastID = decisions.last?.id
    self.filters = filters
  }
}

actor DecisionsSidebarPresentationWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )

  private var cachedInput: DecisionsSidebarPresentationInput?
  private var cachedOutput = DecisionsSidebarPresentation.empty

  func compute(input: DecisionsSidebarPresentationInput) -> DecisionsSidebarPresentation {
    guard input != cachedInput else {
      return cachedOutput
    }

    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(
      "decisions_sidebar.presentation.compute",
      id: signpostID,
      "decisions=\(input.items.count, privacy: .public)"
    )
    defer {
      Self.signposter.endInterval(
        "decisions_sidebar.presentation.compute",
        interval,
        "visible=\(self.cachedOutput.visibleCount, privacy: .public)"
      )
    }

    cachedInput = input
    cachedOutput = Self.presentation(from: input)
    return cachedOutput
  }

  func waitForIdle() async {}

  private static func presentation(
    from input: DecisionsSidebarPresentationInput
  ) -> DecisionsSidebarPresentation {
    let trimmed = input.filters.query.trimmingCharacters(in: .whitespacesAndNewlines)
    let scoped: [DecisionPresentationItem]
    if trimmed.isEmpty {
      scoped = input.items
    } else {
      scoped = input.items.filter { item in
        searchMatches(item, scope: input.filters.scope, trimmedQuery: trimmed)
      }
    }

    let summaryQuery = input.filters.scope == .summary ? trimmed : ""
    let filtered = filteredItems(
      scoped,
      summaryQuery: summaryQuery,
      severities: input.filters.severities
    )
    let groups = grouped(filtered)
    let decisionIDs = groups.flatMap(\.decisionIDs)
    let criticalIDs = filtered.ids(whereSeverityIs: .critical)
    let infoIDs = filtered.ids(whereSeverityIs: .info)
    let criticalCount = criticalIDs.count
    let hasSearchQuery = !trimmed.isEmpty
    let hasSeverityFilters = !input.filters.severities.isEmpty
    let hasActiveFilters = hasSearchQuery || hasSeverityFilters
    let visibleCount = decisionIDs.count
    let totalCount = input.items.count

    return DecisionsSidebarPresentation(
      groups: groups,
      decisionIDs: decisionIDs,
      signature: DecisionsSidebarViewModel.filterSignature(filters: input.filters),
      totalCount: totalCount,
      visibleCount: visibleCount,
      criticalCount: criticalCount,
      needsUserCount: filtered.count(whereSeverityIs: .needsUser),
      visibleCriticalDecisionIDs: criticalIDs,
      visibleInfoDecisionIDs: infoIDs,
      hasActiveFilters: hasActiveFilters,
      countLabel: hasActiveFilters ? "\(visibleCount)/\(totalCount)" : "\(totalCount)",
      resultSummary: resultSummary(
        totalCount: totalCount,
        visibleCount: visibleCount,
        criticalCount: criticalCount,
        hasActiveFilters: hasActiveFilters
      ),
      scopeDescription: scopeDescription(
        filters: input.filters,
        trimmedQuery: trimmed,
        hasSearchQuery: hasSearchQuery,
        hasSeverityFilters: hasSeverityFilters
      ),
      emptyStateTitle: totalCount == 0 ? "No active decisions" : "No matching decisions",
      emptyStateDescription: emptyStateDescription(
        totalCount: totalCount,
        hasActiveFilters: hasActiveFilters
      )
    )
  }

  private static func filteredItems(
    _ items: [DecisionPresentationItem],
    summaryQuery: String,
    severities: Set<DecisionSeverity>
  ) -> [DecisionPresentationItem] {
    items.filter { item in
      guard let severity = DecisionSeverity(rawValue: item.severityRaw) else { return false }
      if !severities.isEmpty, !severities.contains(severity) { return false }
      if summaryQuery.isEmpty { return true }
      return item.summary.range(of: summaryQuery, options: .caseInsensitive) != nil
    }
  }

  private static func grouped(
    _ items: [DecisionPresentationItem]
  ) -> [DecisionsSidebarPresentationGroup] {
    let buckets = Dictionary(grouping: items) { $0.sessionID }
    return buckets.map { key, rows in
      DecisionsSidebarPresentationGroup(
        sessionID: key,
        decisionIDs: sortedBySeverity(rows).map(\.id),
        earliestCreatedAt: rows.map(\.createdAt).min() ?? Date.distantFuture
      )
    }.sorted(by: sessionGroupOrdering)
  }

  private static func sortedBySeverity(
    _ items: [DecisionPresentationItem]
  ) -> [DecisionPresentationItem] {
    items.sorted { lhs, rhs in
      let leftKey = DecisionSeverity(rawValue: lhs.severityRaw)?.sortKey ?? 0
      let rightKey = DecisionSeverity(rawValue: rhs.severityRaw)?.sortKey ?? 0
      if leftKey != rightKey { return leftKey > rightKey }
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
      return lhs.id < rhs.id
    }
  }

  private static func sessionGroupOrdering(
    _ lhs: DecisionsSidebarPresentationGroup,
    _ rhs: DecisionsSidebarPresentationGroup
  ) -> Bool {
    switch (lhs.sessionID, rhs.sessionID) {
    case (nil, nil):
      return false
    case (nil, _):
      return false
    case (_, nil):
      return true
    case (let left?, let right?):
      if lhs.earliestCreatedAt != rhs.earliestCreatedAt {
        return lhs.earliestCreatedAt < rhs.earliestCreatedAt
      }
      return left < right
    }
  }

  private static func searchMatches(
    _ item: DecisionPresentationItem,
    scope: DecisionsSidebarSearchScope,
    trimmedQuery: String
  ) -> Bool {
    guard !trimmedQuery.isEmpty else { return true }
    let haystack: String?
    switch scope {
    case .summary:
      haystack = item.summary
    case .ruleID:
      haystack = item.ruleID
    case .agent:
      haystack = item.agentID
    case .task:
      haystack = item.taskID
    }
    guard let haystack else { return false }
    return haystack.range(of: trimmedQuery, options: .caseInsensitive) != nil
  }

  private static func resultSummary(
    totalCount: Int,
    visibleCount: Int,
    criticalCount: Int,
    hasActiveFilters: Bool
  ) -> String {
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

  private static func scopeDescription(
    filters: DecisionsSidebarViewModel.FilterState,
    trimmedQuery: String,
    hasSearchQuery: Bool,
    hasSeverityFilters: Bool
  ) -> String {
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

  private static func emptyStateDescription(
    totalCount: Int,
    hasActiveFilters: Bool
  ) -> String {
    if totalCount == 0 {
      return "This area fills in when the workspace needs attention."
    }
    if hasActiveFilters {
      return "Clear filters or broaden the search scope to bring decisions back into view."
    }
    return "Broaden the search scope to bring decisions back into view."
  }
}

extension Array where Element == DecisionPresentationItem {
  fileprivate func count(whereSeverityIs severity: DecisionSeverity) -> Int {
    reduce(into: 0) { count, item in
      if item.severityRaw == severity.rawValue {
        count += 1
      }
    }
  }

  fileprivate func ids(whereSeverityIs severity: DecisionSeverity) -> [String] {
    filter { $0.severityRaw == severity.rawValue }.map(\.id)
  }
}
