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

  fileprivate func matches(_ item: DecisionPresentationSnapshot) -> Bool {
    if !severityRawValues.isEmpty, !severityRawValues.contains(item.severityRaw) {
      return false
    }
    guard !trimmedQuery.isEmpty else { return true }
    guard let haystack = item.searchValue(scopeRawValue: scopeRawValue) else { return false }
    return haystack.range(of: trimmedQuery, options: .caseInsensitive) != nil
  }
}

extension DecisionPresentationSnapshot {
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
  public let items: [DecisionPresentationSnapshot]
  public let filters: SessionDecisionFilterSnapshot

  @MainActor
  public init(sessionID: String, decisions: [Decision], filters: SessionDecisionFilterState) {
    self.sessionID = sessionID
    items = decisions.map(DecisionPresentationSnapshot.init)
    self.filters = SessionDecisionFilterSnapshot(filters: filters)
  }

  @MainActor
  public init(
    sessionID: String,
    items: [DecisionPresentationSnapshot],
    filters: SessionDecisionFilterState
  ) {
    self.sessionID = sessionID
    self.items = items
    self.filters = SessionDecisionFilterSnapshot(filters: filters)
  }
}

public struct SessionDecisionFilterOutput: Equatable, Sendable {
  public static let empty = Self(decisionIDs: [], decisionItems: [])

  public let decisionIDs: [String]
  public let decisionItems: [DecisionPresentationSnapshot]
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
  public let decisionIDs: [String]

  public init(sessionID: String, decisionIDs: [String]) {
    self.sessionID = sessionID
    self.decisionIDs = decisionIDs
  }

  public init(sessionID: String, decisions: [Decision]) {
    self.init(sessionID: sessionID, decisionIDs: decisions.map(\.id))
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
  func filteredOutput(input: SessionDecisionFilterInput) -> SessionDecisionFilterOutput {
    let items = input.items.filter { input.filters.matches($0) }
    return SessionDecisionFilterOutput(
      decisionIDs: items.map(\.id),
      decisionItems: items
    )
  }
}
