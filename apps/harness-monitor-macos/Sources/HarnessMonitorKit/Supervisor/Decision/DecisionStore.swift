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
  public struct DecisionEvent: Sendable, Hashable {
    public enum Kind: String, Sendable {
      case inserted
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

  private enum Status {
    static let open = "open"
    static let snoozed = "snoozed"
    static let resolved = "resolved"
    static let dismissed = "dismissed"
  }

  /// Broadcast channel of decision lifecycle events. Buffered so slow consumers do not block
  /// mutations — the most recent events survive under `.bufferingNewest`.
  nonisolated public let events: AsyncStream<DecisionEvent>
  private let eventsContinuation: AsyncStream<DecisionEvent>.Continuation

  private let container: ModelContainer

  public init(container: ModelContainer) {
    self.container = container
    (events, eventsContinuation) = AsyncStream<DecisionEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(64)
    )
  }

  /// In-memory container scoped to the supervisor entity trio. Used by tests and ephemeral
  /// previews; production callers pass the shared `HarnessMonitorSchemaV7` container.
  public static func makeInMemory() throws -> DecisionStore {
    let container = try ModelContainer(
      for: Decision.self,
      SupervisorEvent.self,
      PolicyConfigRow.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return DecisionStore(container: container)
  }

  deinit {
    eventsContinuation.finish()
  }

  public func insert(_ draft: DecisionDraft) async throws {
    let context = ModelContext(container)
    context.autosaveEnabled = false
    if try fetchDecision(id: draft.id, context: context) != nil {
      // Duplicate id: treat as no-op. Snapshot-driven rule evaluation re-emits the same
      // `queueDecision` action every tick until resolution, so swallowing duplicates here keeps
      // the store deduped without pushing the burden onto every rule.
      return
    }
    let model = Decision(
      id: draft.id,
      severity: draft.severity,
      ruleID: draft.ruleID,
      sessionID: draft.sessionID,
      agentID: draft.agentID,
      taskID: draft.taskID,
      summary: draft.summary,
      contextJSON: draft.contextJSON,
      suggestedActionsJSON: draft.suggestedActionsJSON
    )
    context.insert(model)
    try context.save()
    yield(.init(kind: .inserted, decisionID: draft.id))
  }

  public nonisolated func openDecisions() async throws -> [Decision] {
    let context = ModelContext(container)
    let now = Date()
    let descriptor = FetchDescriptor<Decision>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    let rows = try context.fetch(descriptor)
    return rows.filter { isOpen($0, now: now) }
  }

  public nonisolated func decision(id: String) async throws -> Decision? {
    let context = ModelContext(container)
    return try fetchDecision(id: id, context: context)
  }

  public func snooze(id: String, until: Date) async throws {
    let context = ModelContext(container)
    context.autosaveEnabled = false
    guard let decision = try fetchDecision(id: id, context: context) else { return }
    decision.snoozedUntil = until
    decision.statusRaw = Status.snoozed
    try context.save()
    yield(.init(kind: .snoozed, decisionID: id))
  }

  public func resolve(id: String, outcome: DecisionOutcome) async throws {
    let context = ModelContext(container)
    context.autosaveEnabled = false
    guard let decision = try fetchDecision(id: id, context: context) else { return }
    decision.statusRaw = Status.resolved
    decision.resolutionJSON = try encodeOutcome(outcome)
    try context.save()
    yield(.init(kind: .resolved, decisionID: id))
  }

  public func expire(beforeAge: TimeInterval) async throws -> Int {
    let context = ModelContext(container)
    context.autosaveEnabled = false
    let cutoff = Date().addingTimeInterval(-beforeAge)
    let descriptor = FetchDescriptor<Decision>(
      predicate: #Predicate<Decision> { $0.createdAt < cutoff }
    )
    let rows = try context.fetch(descriptor)
    guard !rows.isEmpty else { return 0 }
    let ids = rows.map(\.id)
    for row in rows { context.delete(row) }
    try context.save()
    for id in ids { yield(.init(kind: .expired, decisionID: id)) }
    return ids.count
  }

  public func dismiss(id: String) async throws {
    let context = ModelContext(container)
    context.autosaveEnabled = false
    guard let decision = try fetchDecision(id: id, context: context) else { return }
    decision.statusRaw = Status.dismissed
    try context.save()
    yield(.init(kind: .dismissed, decisionID: id))
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

  private nonisolated func fetchDecision(id: String, context: ModelContext) throws -> Decision? {
    var descriptor = FetchDescriptor<Decision>(
      predicate: #Predicate<Decision> { $0.id == id }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  private nonisolated func isOpen(_ decision: Decision, now: Date) -> Bool {
    guard decision.statusRaw == Status.open || decision.statusRaw == Status.snoozed else {
      return false
    }
    if decision.statusRaw == Status.snoozed {
      guard let until = decision.snoozedUntil else { return true }
      return until <= now
    }
    return true
  }

  private func encodeOutcome(_ outcome: DecisionOutcome) throws -> String {
    let data = try JSONEncoder().encode(outcome)
    return String(decoding: data, as: UTF8.self)
  }

  private func yield(_ event: DecisionEvent) {
    eventsContinuation.yield(event)
  }
}

public struct DecisionDraft: Sendable, Hashable {
  public let id: String
  public let severity: DecisionSeverity
  public let ruleID: String
  public let sessionID: String?
  public let agentID: String?
  public let taskID: String?
  public let summary: String
  public let contextJSON: String
  public let suggestedActionsJSON: String

  public init(
    id: String,
    severity: DecisionSeverity,
    ruleID: String,
    sessionID: String?,
    agentID: String?,
    taskID: String?,
    summary: String,
    contextJSON: String,
    suggestedActionsJSON: String
  ) {
    self.id = id
    self.severity = severity
    self.ruleID = ruleID
    self.sessionID = sessionID
    self.agentID = agentID
    self.taskID = taskID
    self.summary = summary
    self.contextJSON = contextJSON
    self.suggestedActionsJSON = suggestedActionsJSON
  }
}

public struct DecisionOutcome: Codable, Sendable, Hashable {
  public let chosenActionID: String?
  public let note: String?

  public init(chosenActionID: String?, note: String?) {
    self.chosenActionID = chosenActionID
    self.note = note
  }
}
