import Foundation
import SwiftData

/// SwiftData-backed store for Monitor supervisor decisions.
///
/// Phase 1 froze the public surface; Phase 2 fills the body. Per memory guidance in
/// `project_background_persistence.md`, this is a plain `actor` that opens a short-lived
/// `ModelContext` per operation so SwiftData's identity map does not accumulate. The actor
/// serialises access so only one context exists at a time.
///
/// Mutations fan out through `events` (an `AsyncStream<DecisionEvent>`) so downstream consumers
/// (toolbar slice, notification controller) can react without repolling SwiftData.
public actor DecisionStore {
  static let outcomeEncoder = JSONEncoder()

  public struct DecisionEvent: Sendable, Hashable {
    public enum Kind: String, Sendable {
      case inserted
      case updated
      case snoozed
      case resolved
      case expired
      case dismissed
    }

    public let kind: Kind
    public let decisionID: String

    public init(kind: Kind, decisionID: String) {
      self.kind = kind
      self.decisionID = decisionID
    }
  }

  public struct OpenSurfaceSnapshot {
    public let decisions: [Decision]
    public let decisionsByID: [String: Decision]
    public let decisionsBySession: [String: [Decision]]
    public let presentationItems: [DecisionPresentationSnapshot]
    public let presentationItemsBySession: [String: [DecisionPresentationSnapshot]]
    public let searchProjections: [DecisionSearchProjection]
    public let searchProjectionsBySession: [String: [DecisionSearchProjection]]
    public let decisionIDsBySession: [String: [String]]
    public let countsBySeverity: [DecisionSeverity: Int]

    public static var empty: Self {
      Self(
        decisions: [],
        decisionsByID: [:],
        decisionsBySession: [:],
        presentationItems: [],
        presentationItemsBySession: [:],
        searchProjections: [],
        searchProjectionsBySession: [:],
        decisionIDsBySession: [:],
        countsBySeverity: [:]
      )
    }
  }

  enum Status {
    static let open = "open"
    static let snoozed = "snoozed"
    static let resolved = "resolved"
    static let dismissed = "dismissed"
  }

  public enum UpsertResult: Sendable, Hashable {
    case inserted
    case updated
    case reopened
    case unchanged
  }

  public enum ReopenResult: Sendable, Hashable {
    case reopened
    case missing
    case notDismissed(statusRaw: String)
  }

  /// Broadcast channel of decision lifecycle events. Buffered so slow consumers do not block
  /// mutations — the most recent events survive under `.bufferingNewest`.
  nonisolated public let events: AsyncStream<DecisionEvent>
  let eventsContinuation: AsyncStream<DecisionEvent>.Continuation

  let container: ModelContainer
  nonisolated private let now: @Sendable () -> Date
  nonisolated let readQueue: DispatchQueue

  public init(container: ModelContainer, now: @escaping @Sendable () -> Date = { Date() }) {
    self.container = container
    self.now = now
    readQueue = DispatchQueue(label: "io.harnessmonitor.decision-store.reads", qos: .userInitiated)
    (events, eventsContinuation) = AsyncStream<DecisionEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(64)
    )
  }

  /// In-memory container scoped to the supervisor entity trio. Used by tests and ephemeral
  /// previews; production callers pass the shared `HarnessMonitorSchemaV7` container.
  public static func makeInMemory(
    now: @escaping @Sendable () -> Date = { Date() }
  ) throws -> DecisionStore {
    let container = try ModelContainer(
      for: Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return DecisionStore(container: container, now: now)
  }

  deinit {
    eventsContinuation.finish()
  }

  public func insert(_ draft: DecisionDraft) async throws {
    let inserted = try withMutationContext { context in
      if try fetchDecision(id: draft.id, context: context) != nil {
        return false
      }
      let createdAt = now()
      let model = Decision(
        id: draft.id,
        severity: draft.severity,
        ruleID: draft.ruleID,
        sessionID: draft.sessionID,
        agentID: draft.agentID,
        taskID: draft.taskID,
        summary: draft.summary,
        contextJSON: draft.contextJSON,
        suggestedActionsJSON: draft.suggestedActionsJSON,
        createdAt: createdAt
      )
      context.insert(model)
      return true
    }
    guard inserted else { return }
    yield(.init(kind: .inserted, decisionID: draft.id))
  }

  @discardableResult
  public func upsertOpen(_ draft: DecisionDraft) async throws -> UpsertResult {
    let result: UpsertResult = try withMutationContext { context in
      if let decision = try fetchDecision(id: draft.id, context: context) {
        guard !hasTerminalResolutionOutcome(decision) else {
          return .unchanged
        }
        guard decision.statusRaw != Status.resolved else {
          return .unchanged
        }
        let now = now()
        return apply(
          draft,
          to: decision,
          reopen: shouldReopen(decision, now: now)
        )
      }
      let createdAt = now()
      let model = Decision(
        id: draft.id,
        severity: draft.severity,
        ruleID: draft.ruleID,
        sessionID: draft.sessionID,
        agentID: draft.agentID,
        taskID: draft.taskID,
        summary: draft.summary,
        contextJSON: draft.contextJSON,
        suggestedActionsJSON: draft.suggestedActionsJSON,
        createdAt: createdAt
      )
      context.insert(model)
      return .inserted
    }
    switch result {
    case .inserted:
      yield(.init(kind: .inserted, decisionID: draft.id))
    case .updated, .reopened:
      yield(.init(kind: .updated, decisionID: draft.id))
    case .unchanged:
      break
    }
    return result
  }

  func previewUpsertOpen(_ draft: DecisionDraft) async throws -> UpsertResult {
    try await withReadContext { context in
      if let decision = try self.fetchDecision(id: draft.id, context: context) {
        guard !self.hasTerminalResolutionOutcome(decision) else {
          return .unchanged
        }
        guard decision.statusRaw != Status.resolved else {
          return .unchanged
        }
        return self.upsertResult(
          draft,
          for: decision,
          reopen: self.shouldReopen(decision, now: self.now())
        )
      }
      return .inserted
    }
  }

  nonisolated public func decision(id: String) async throws -> Decision? {
    try await withReadContext { context in
      try self.fetchDecision(id: id, context: context)
    }
  }

  public func snooze(id: String, until: Date) async throws {
    let updated = try withMutationContext { context in
      guard let decision = try fetchDecision(id: id, context: context) else { return false }
      decision.snoozedUntil = until
      decision.statusRaw = Status.snoozed
      return true
    }
    guard updated else { return }
    yield(.init(kind: .snoozed, decisionID: id))
  }

  public func resolve(id: String, outcome: DecisionOutcome) async throws {
    let updated = try withMutationContext { context in
      guard let decision = try fetchDecision(id: id, context: context) else { return false }
      guard isUnresolved(decision) else { return false }
      let encodedOutcome = try encodeOutcome(outcome)
      decision.statusRaw = Status.resolved
      decision.resolutionJSON = encodedOutcome
      decision.snoozedUntil = nil
      return true
    }
    guard updated else { return }
    yield(.init(kind: .resolved, decisionID: id))
  }

  public func resolveTerminal(id: String, outcome: DecisionOutcome) async throws {
    guard isTerminalResolutionOutcome(outcome) else {
      return
    }
    let updated = try withMutationContext { context in
      guard let decision = try fetchDecision(id: id, context: context) else { return false }
      guard isUnresolved(decision) || decision.statusRaw == Status.dismissed else { return false }
      let encodedOutcome = try encodeOutcome(outcome)
      decision.statusRaw = Status.resolved
      decision.resolutionJSON = encodedOutcome
      decision.snoozedUntil = nil
      return true
    }
    guard updated else { return }
    yield(.init(kind: .resolved, decisionID: id))
  }

  public func expire(beforeAge: TimeInterval) async throws -> Int {
    let cutoff = now().addingTimeInterval(-beforeAge)
    let ids = try withMutationContext { context in
      let descriptor = FetchDescriptor<Decision>(
        predicate: #Predicate<Decision> { $0.createdAt < cutoff }
      )
      let rows = try context.fetch(descriptor).filter(isUnresolved)
      let ids = rows.map(\.id)
      rows.forEach(context.delete)
      return ids
    }
    guard !ids.isEmpty else { return 0 }
    for id in ids { yield(.init(kind: .expired, decisionID: id)) }
    return ids.count
  }

  public func dismiss(id: String) async throws {
    let updated = try withMutationContext { context in
      guard let decision = try fetchDecision(id: id, context: context) else { return false }
      guard isUnresolved(decision) else { return false }
      decision.statusRaw = Status.dismissed
      decision.snoozedUntil = nil
      return true
    }
    guard updated else { return }
    yield(.init(kind: .dismissed, decisionID: id))
  }

  @discardableResult
  public func reopen(id: String) async throws -> ReopenResult {
    let result = try withMutationContext { context in
      guard let decision = try fetchDecision(id: id, context: context) else {
        return ReopenResult.missing
      }
      guard decision.statusRaw == Status.dismissed else {
        return .notDismissed(statusRaw: decision.statusRaw)
      }
      decision.statusRaw = Status.open
      decision.snoozedUntil = nil
      decision.resolutionJSON = nil
      return .reopened
    }
    guard result == .reopened else { return result }
    yield(.init(kind: .updated, decisionID: id))
    return result
  }

  public func openCountBySeverity() async throws -> [DecisionSeverity: Int] {
    let open = try await openDecisions()
    var counts: [DecisionSeverity: Int] = [:]
    for decision in open {
      guard let severity = DecisionSeverity(rawValue: decision.severityRaw) else { continue }
      counts[severity, default: 0] += 1
    }
    return counts
  }

  // MARK: - Private

  nonisolated private func apply(
    _ draft: DecisionDraft,
    to decision: Decision,
    reopen: Bool
  ) -> UpsertResult {
    let result = upsertResult(draft, for: decision, reopen: reopen)
    guard result != .unchanged else {
      return .unchanged
    }
    if decision.severityRaw != draft.severity.rawValue {
      decision.severityRaw = draft.severity.rawValue
    }
    if decision.ruleID != draft.ruleID {
      decision.ruleID = draft.ruleID
    }
    if decision.sessionID != draft.sessionID {
      decision.sessionID = draft.sessionID
    }
    if decision.agentID != draft.agentID {
      decision.agentID = draft.agentID
    }
    if decision.taskID != draft.taskID {
      decision.taskID = draft.taskID
    }
    if decision.summary != draft.summary {
      decision.summary = draft.summary
    }
    if decision.contextJSON != draft.contextJSON {
      decision.contextJSON = draft.contextJSON
    }
    if decision.suggestedActionsJSON != draft.suggestedActionsJSON {
      decision.suggestedActionsJSON = draft.suggestedActionsJSON
    }
    if result == .reopened {
      decision.statusRaw = Status.open
      decision.snoozedUntil = nil
      decision.resolutionJSON = nil
    }
    return result
  }

  nonisolated private func upsertResult(
    _ draft: DecisionDraft,
    for decision: Decision,
    reopen: Bool
  ) -> UpsertResult {
    let changed =
      decision.severityRaw != draft.severity.rawValue
      || decision.ruleID != draft.ruleID
      || decision.sessionID != draft.sessionID
      || decision.agentID != draft.agentID
      || decision.taskID != draft.taskID
      || decision.summary != draft.summary
      || decision.contextJSON != draft.contextJSON
      || decision.suggestedActionsJSON != draft.suggestedActionsJSON
    if reopen && decision.statusRaw != Status.open {
      return .reopened
    }
    return changed ? .updated : .unchanged
  }

}
