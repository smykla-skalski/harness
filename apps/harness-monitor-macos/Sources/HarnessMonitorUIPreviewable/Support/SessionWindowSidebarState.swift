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

  public var decisionWorkspaceFilters: DecisionsSidebarViewModel.FilterState {
    DecisionsSidebarViewModel.FilterState(
      query: query,
      severities: severities,
      scope: scope
    )
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

public enum SessionSidebarSelectionKind: Hashable, Sendable {
  case agent
  case task
  case decision

  public var pluralNoun: String {
    switch self {
    case .agent: "agents"
    case .task: "tasks"
    case .decision: "decisions"
    }
  }

  public var singularNoun: String {
    switch self {
    case .agent: "agent"
    case .task: "task"
    case .decision: "decision"
    }
  }

  /// Default kind for select-all when no anchor is set. Policy: agents take
  /// priority, then tasks, then decisions — first non-empty wins. Lives next
  /// to the selection state because that's where the rule belongs, not in a
  /// view file.
  public static func inferredAnchorKind(
    agentCount: Int,
    taskCount: Int,
    decisionCount: Int
  ) -> SessionSidebarSelectionKind? {
    if agentCount > 0 { return .agent }
    if taskCount > 0 { return .task }
    if decisionCount > 0 { return .decision }
    return nil
  }
}

public struct SessionSidebarAnchor: Equatable, Sendable {
  public let kind: SessionSidebarSelectionKind
  public let id: String

  public init(kind: SessionSidebarSelectionKind, id: String) {
    self.kind = kind
    self.id = id
  }
}

@MainActor
@Observable
public final class SessionSidebarSelectionState {
  /// User-toggled "show checkboxes" mode for decisions only. Gesture-driven multi-select
  /// works regardless; this flag forces the checkbox affordance on for accessibility.
  public var isDecisionMultiSelectEnabled = false

  /// At most one kind has a non-empty multi-selection at a time. Mutations
  /// must go through `applyChange`, `prune`, or `clear` so the invariant holds.
  public private(set) var selectedAgentIDs: Set<String> = []
  public private(set) var selectedTaskIDs: Set<String> = []
  public private(set) var selectedDecisionIDs: Set<String> = []
  public private(set) var anchor: SessionSidebarAnchor?
  public private(set) var renderedSelectionCount = 1

  /// Bumped on every selection mutation. Forward-looking primitive — keep
  /// it stable so a future watcher (e.g. a per-window analytics probe, or
  /// a virtualized row that wants a coarser invalidation key than four
  /// `@Observable` fields) can subscribe via `.onChange(of: state.sidebarSelection.revision)`
  /// without hashing ID arrays. Bumps on no-op writes too — treat as an
  /// "edit happened" signal, not a content hash.
  public private(set) var revision: Int = 0

  public init() {}

  public func count(of kind: SessionSidebarSelectionKind) -> Int {
    selectedIDs(of: kind).count
  }

  public func selectedIDs(of kind: SessionSidebarSelectionKind) -> Set<String> {
    switch kind {
    case .agent: selectedAgentIDs
    case .task: selectedTaskIDs
    case .decision: selectedDecisionIDs
    }
  }

  public var hasActiveMultiSelection: Bool {
    selectedAgentIDs.count > 1
      || selectedTaskIDs.count > 1
      || selectedDecisionIDs.count > 1
      || renderedSelectionCount > 1
  }

  public func syncRenderedSelectionCount(_ count: Int) {
    renderedSelectionCount = max(0, count)
  }

  public func clear() {
    selectedAgentIDs.removeAll()
    selectedTaskIDs.removeAll()
    selectedDecisionIDs.removeAll()
    anchor = nil
    revision &+= 1
  }

  public func toggleDecisionMultiSelect() {
    isDecisionMultiSelectEnabled.toggle()
    if !isDecisionMultiSelectEnabled {
      selectedDecisionIDs.removeAll()
      if anchor?.kind == .decision {
        anchor = nil
      }
      revision &+= 1
    }
  }

  /// Convenience for the existing decision-row checkbox path.
  public func toggleDecision(_ decisionID: String) {
    var next = selectedDecisionIDs
    if next.contains(decisionID) {
      next.remove(decisionID)
    } else {
      next.insert(decisionID)
    }
    applyChange(kind: .decision, selectedIDs: next, anchorID: decisionID)
  }

  /// Apply a click-resolver outcome under the anchor-locked cross-type rule:
  /// switching kinds first clears the other kinds via `switchActiveKind(to:)`,
  /// then writes the new selection. Single chokepoint for the invariant.
  public func applyChange(
    kind: SessionSidebarSelectionKind,
    selectedIDs: Set<String>,
    anchorID: String?
  ) {
    if let existing = anchor, existing.kind != kind {
      switchActiveKind(to: kind)
    }
    write(ids: selectedIDs, of: kind)
    if let anchorID {
      anchor = SessionSidebarAnchor(kind: kind, id: anchorID)
    } else if anchor?.kind == kind {
      anchor = nil
    }
    revision &+= 1
  }

  public func prune(
    kind: SessionSidebarSelectionKind,
    visibleIDs: Set<String>
  ) {
    let pruned = selectedIDs(of: kind).intersection(visibleIDs)
    write(ids: pruned, of: kind)
    if let current = anchor, current.kind == kind, !visibleIDs.contains(current.id) {
      anchor = pruned.first.map { SessionSidebarAnchor(kind: kind, id: $0) }
    }
    revision &+= 1
  }

  /// Drops every per-kind set when the active anchor kind is about to change.
  /// Caller asserts the new kind differs from the current anchor; that's the
  /// invariant this method enforces — at most one kind active at a time.
  private func switchActiveKind(to newKind: SessionSidebarSelectionKind) {
    assert(anchor?.kind != newKind, "switchActiveKind only valid on a kind change")
    selectedAgentIDs.removeAll()
    selectedTaskIDs.removeAll()
    selectedDecisionIDs.removeAll()
  }

  private func write(ids: Set<String>, of kind: SessionSidebarSelectionKind) {
    switch kind {
    case .agent: selectedAgentIDs = ids
    case .task: selectedTaskIDs = ids
    case .decision: selectedDecisionIDs = ids
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
