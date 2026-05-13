import Foundation
import HarnessMonitorKit

public struct SessionDecisionFilterSnapshot: Hashable, Sendable {
  public let query: String
  public let trimmedQuery: String
  public let severityRawValues: Set<String>
  public let scopeRawValue: String

  @MainActor
  public init(filters: SessionDecisionFilterState) {
    query = filters.query
    trimmedQuery = filters.query.trimmingCharacters(in: .whitespacesAndNewlines)
    severityRawValues = Set(filters.severities.map(\.rawValue))
    scopeRawValue = filters.scope.rawValue
  }

  fileprivate func matches(_ item: SessionDecisionFilterItem) -> Bool {
    if !severityRawValues.isEmpty, !severityRawValues.contains(item.severityRaw) {
      return false
    }
    guard !trimmedQuery.isEmpty else { return true }
    guard let haystack = item.searchValue(scopeRawValue: scopeRawValue) else { return false }
    return haystack.range(of: trimmedQuery, options: .caseInsensitive) != nil
  }
}

public struct SessionDecisionFilterItem: Hashable, Sendable {
  public let id: String
  public let severityRaw: String
  public let summary: String
  public let ruleID: String
  public let agentID: String?
  public let taskID: String?

  public init(decision: Decision) {
    id = decision.id
    severityRaw = decision.severityRaw
    summary = decision.summary
    ruleID = decision.ruleID
    agentID = decision.agentID
    taskID = decision.taskID
  }

  fileprivate func searchValue(scopeRawValue: String) -> String? {
    switch scopeRawValue {
    case DecisionsSidebarSearchScope.summary.rawValue:
      summary
    case DecisionsSidebarSearchScope.ruleID.rawValue:
      ruleID
    case DecisionsSidebarSearchScope.agent.rawValue:
      agentID
    case DecisionsSidebarSearchScope.task.rawValue:
      taskID
    default:
      summary
    }
  }
}

public struct SessionDecisionFilterInput: Equatable, Sendable {
  public let sessionID: String
  public let items: [SessionDecisionFilterItem]
  public let filters: SessionDecisionFilterSnapshot

  @MainActor
  public init(sessionID: String, decisions: [Decision], filters: SessionDecisionFilterState) {
    self.sessionID = sessionID
    items = decisions.map(SessionDecisionFilterItem.init)
    self.filters = SessionDecisionFilterSnapshot(filters: filters)
  }
}

public struct SessionDecisionFilterKey: Hashable, Sendable {
  public let sessionID: String
  public let decisionFingerprint: Int
  public let filters: SessionDecisionFilterSnapshot

  @MainActor
  public init(sessionID: String, decisions: [Decision], filters: SessionDecisionFilterState) {
    self.sessionID = sessionID
    decisionFingerprint = SessionDecisionFingerprint.hash(decisions: decisions)
    self.filters = SessionDecisionFilterSnapshot(filters: filters)
  }
}

public struct SessionDecisionDataKey: Hashable, Sendable {
  public let sessionID: String
  public let decisionFingerprint: Int

  public init(sessionID: String, decisions: [Decision]) {
    self.sessionID = sessionID
    decisionFingerprint = SessionDecisionFingerprint.hash(decisions: decisions)
  }
}

private enum SessionDecisionFingerprint {
  static func hash(decisions: [Decision]) -> Int {
    var hasher = Hasher()
    hasher.combine(decisions.count)
    for decision in decisions {
      hasher.combine(decision.id)
      hasher.combine(decision.severityRaw)
      hasher.combine(decision.summary)
      hasher.combine(decision.ruleID)
      hasher.combine(decision.agentID)
      hasher.combine(decision.taskID)
    }
    return hasher.finalize()
  }
}

let sessionDecisionFilterWorker = SessionDecisionFilterWorker()

actor SessionDecisionFilterWorker {
  func filteredIDs(input: SessionDecisionFilterInput) -> [String] {
    input.items.lazy.filter { input.filters.matches($0) }.map(\.id)
  }
}
