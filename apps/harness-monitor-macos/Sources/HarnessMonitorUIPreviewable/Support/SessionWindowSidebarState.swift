import Foundation
import HarnessMonitorKit
import Observation

public struct SessionTaskDecisionLink: Equatable, Sendable {
  public let sessionID: String
  public let taskID: String
  public let decisionID: String

  public init(sessionID: String, taskID: String, decisionID: String) {
    self.sessionID = sessionID
    self.taskID = taskID
    self.decisionID = decisionID
  }
}

@MainActor
@Observable
public final class SessionDecisionFilterState {
  public var query = ""
  public var severities: Set<DecisionSeverity> = []

  public init() {}

  public func matches(_ decision: Decision) -> Bool {
    let severity = DecisionSeverity(rawValue: decision.severityRaw)
    if let severity, !severities.isEmpty, !severities.contains(severity) {
      return false
    }
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return true }
    return decision.summary.localizedCaseInsensitiveContains(trimmedQuery)
      || decision.ruleID.localizedCaseInsensitiveContains(trimmedQuery)
      || (decision.agentID?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
      || (decision.taskID?.localizedCaseInsensitiveContains(trimmedQuery) ?? false)
  }

  public func toggle(_ severity: DecisionSeverity) {
    if severities.contains(severity) {
      severities.remove(severity)
    } else {
      severities.insert(severity)
    }
  }

  public func clear() {
    query = ""
    severities.removeAll()
  }
}

@MainActor
@Observable
public final class SessionDecisionBulkActionState {
  public var lastDismissedBatch: [String] = []
  public var reopenRequestedBatch: [String]?

  public init() {}

  public func recordDismissedBatch(_ ids: [String], undoManager: UndoManager?) {
    guard !ids.isEmpty else { return }
    lastDismissedBatch = ids
    undoManager?.registerUndo(withTarget: self) { target in
      target.reopenRequestedBatch = ids
    }
    undoManager?.setActionName("Dismiss Decisions")
  }
}

@MainActor
@Observable
public final class SessionSidebarSelectionState {
  public var isDecisionMultiSelectEnabled = false
  public var selectedDecisionIDs: Set<String> = []
  public var decisionSelectionAnchorID: String?

  public init() {}

  public func toggleDecisionMultiSelect() {
    isDecisionMultiSelectEnabled.toggle()
    if !isDecisionMultiSelectEnabled {
      selectedDecisionIDs.removeAll()
      decisionSelectionAnchorID = nil
    }
  }

  public func toggleDecision(_ decisionID: String) {
    if selectedDecisionIDs.contains(decisionID) {
      selectedDecisionIDs.remove(decisionID)
    } else {
      selectedDecisionIDs.insert(decisionID)
    }
    decisionSelectionAnchorID = decisionID
  }

  public func pruneDecisionSelection(to visibleDecisionIDs: Set<String>) {
    selectedDecisionIDs.formIntersection(visibleDecisionIDs)
    if let decisionSelectionAnchorID, !visibleDecisionIDs.contains(decisionSelectionAnchorID) {
      self.decisionSelectionAnchorID = selectedDecisionIDs.first
    }
  }
}

@MainActor
@Observable
public final class SessionSidebarOrderingState {
  public var agentIDs: [String] = []

  public init() {}

  public func orderedAgents(_ agents: [AgentRegistration]) -> [AgentRegistration] {
    reconcileAgentIDs(with: agents.map(\.agentId))
    let order = Dictionary(uniqueKeysWithValues: agentIDs.enumerated().map { ($1, $0) })
    return agents.sorted { left, right in
      (order[left.agentId] ?? Int.max, left.agentId)
        < (order[right.agentId] ?? Int.max, right.agentId)
    }
  }

  public func moveAgent(_ agentID: String, before targetID: String?, undoManager: UndoManager?) {
    let previous = agentIDs
    applyAgentMove(agentID, before: targetID)
    guard previous != agentIDs else { return }
    undoManager?.registerUndo(withTarget: self) { target in
      target.agentIDs = previous
    }
    undoManager?.setActionName("Move Agent")
  }

  private func reconcileAgentIDs(with liveIDs: [String]) {
    let liveSet = Set(liveIDs)
    let retained = agentIDs.filter { liveSet.contains($0) }
    let retainedSet = Set(retained)
    agentIDs = retained + liveIDs.filter { !retainedSet.contains($0) }
  }

  private func applyAgentMove(_ agentID: String, before targetID: String?) {
    agentIDs.removeAll { $0 == agentID }
    guard let targetID, let targetIndex = agentIDs.firstIndex(of: targetID) else {
      agentIDs.append(agentID)
      return
    }
    agentIDs.insert(agentID, at: targetIndex)
  }
}
