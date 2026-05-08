import Foundation
import HarnessMonitorKit
import Observation

public enum SessionDecisionBulkActionCopy {
  public static let dismissVisibleHelp =
    "Dismiss All Visible applies to decisions matching the current filter and search."
}

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

public struct SessionDecisionUndoToastState: Equatable, Identifiable, Sendable {
  public static let commitBarrierCopy = "Closing window confirms dismissal."
  public let id: String
  public let decisionIDs: [String]
  public let expiresAt: Date

  public init(decisionIDs: [String], now: Date = Date()) {
    self.decisionIDs = decisionIDs
    expiresAt = now.addingTimeInterval(8)
    id = "\(decisionIDs.joined(separator: ","))-\(expiresAt.timeIntervalSinceReferenceDate)"
  }

  public var count: Int {
    decisionIDs.count
  }

  public var dismissedCopy: String {
    "Dismissed \(count) decision\(count == 1 ? "" : "s")"
  }

  public var accessibilityCopy: String {
    "\(dismissedCopy). Undo available. \(Self.commitBarrierCopy)"
  }
}

@MainActor
@Observable
public final class SessionDecisionFilterState {
  public var query = ""
  public var severities: Set<DecisionSeverity> = []
  public var scope: DecisionsSidebarSearchScope = .summary

  public init() {}

  public func matches(_ decision: Decision) -> Bool {
    let severity = DecisionSeverity(rawValue: decision.severityRaw)
    if let severity, !severities.isEmpty, !severities.contains(severity) {
      return false
    }
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return true }
    return scope.matches(decision, trimmedQuery: trimmedQuery)
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
    scope = .summary
  }
}

@MainActor
@Observable
public final class SessionDecisionBulkActionState {
  public var lastDismissedBatch: [String] = []
  public var reopenRequestedBatch: [String]?
  public var undoToast: SessionDecisionUndoToastState?

  public init() {}

  public func recordDismissedBatch(
    _ ids: [String],
    undoManager: UndoManager?,
    now: Date = Date()
  ) {
    guard !ids.isEmpty else { return }
    lastDismissedBatch = ids
    undoToast = SessionDecisionUndoToastState(decisionIDs: ids, now: now)
    undoManager?.registerUndo(withTarget: self) { target in
      target.requestReopen(ids)
    }
    undoManager?.setActionName("Dismiss Decisions")
  }

  public func requestReopen(_ ids: [String]) {
    reopenRequestedBatch = ids
    undoToast = nil
  }

  public func requestUndoToastReopen() {
    guard let undoToast else { return }
    requestReopen(undoToast.decisionIDs)
  }

  public func clearExpiredUndoToast(now: Date = Date()) {
    guard let undoToast, now >= undoToast.expiresAt else { return }
    self.undoToast = nil
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
    let liveIDs = agents.map(\.agentId)
    let liveSet = Set(liveIDs)
    let retained = agentIDs.filter { liveSet.contains($0) }
    let retainedSet = Set(retained)
    let effectiveOrder = retained + liveIDs.filter { !retainedSet.contains($0) }
    let order = Dictionary(
      uniqueKeysWithValues: effectiveOrder.enumerated().map { ($1, $0) }
    )
    return agents.sorted { left, right in
      (order[left.agentId] ?? Int.max, left.agentId)
        < (order[right.agentId] ?? Int.max, right.agentId)
    }
  }

  /// Reconcile the persisted agent ordering against the live agent list.
  /// Call from `.onChange(of: agents.map(\.agentId))` or a similar lifecycle
  /// hook — never from a view body, since this mutates an `@Observable`
  /// property and would feed back into the next render.
  public func reconcileAgentOrder(with agents: [AgentRegistration]) {
    reconcileAgentIDs(with: agents.map(\.agentId))
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
    let next = retained + liveIDs.filter { !retainedSet.contains($0) }
    guard next != agentIDs else { return }
    agentIDs = next
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
