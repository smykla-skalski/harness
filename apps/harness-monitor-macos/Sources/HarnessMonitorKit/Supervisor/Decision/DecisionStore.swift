import Foundation
import SwiftData

/// SwiftData-backed store for Monitor supervisor decisions. Phase 1 signature freeze: every
/// public method surface below is fixed. Bodies return empty/no-op so the project compiles and
/// Phase 2 worker 2 can fill them without touching call sites.
///
/// Implementation note: per the memory entry `project_background_persistence.md`, Phase 2
/// should keep this as a plain `actor` with short-lived `ModelContext`s, not a `@ModelActor`.
public actor DecisionStore {
  public struct DecisionEvent: Sendable {
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

  /// Never-yielding stream in Phase 1. Phase 2 worker 2 wires the continuation into insert /
  /// snooze / resolve / expire / dismiss.
  nonisolated public let events: AsyncStream<DecisionEvent>
  private let eventsContinuation: AsyncStream<DecisionEvent>.Continuation

  private let container: ModelContainer?

  public init(container: ModelContainer) {
    self.container = container
    (events, eventsContinuation) = AsyncStream<DecisionEvent>.makeStream()
  }

  private init() {
    self.container = nil
    (events, eventsContinuation) = AsyncStream<DecisionEvent>.makeStream()
  }

  /// Phase 1 placeholder — Phase 2 creates an in-memory `ModelContainer` with the supervisor
  /// schema subset.
  public static func makeInMemory() throws -> DecisionStore {
    DecisionStore()
  }

  public func insert(_ draft: DecisionDraft) async throws {
    _ = draft
  }

  public func openDecisions() async throws -> [Decision] {
    []
  }

  public func decision(id: String) async throws -> Decision? {
    _ = id
    return nil
  }

  public func snooze(id: String, until: Date) async throws {
    _ = (id, until)
  }

  public func resolve(id: String, outcome: DecisionOutcome) async throws {
    _ = (id, outcome)
  }

  public func expire(beforeAge: TimeInterval) async throws -> Int {
    _ = beforeAge
    return 0
  }

  public func dismiss(id: String) async throws {
    _ = id
  }

  public func openCountBySeverity() async throws -> [DecisionSeverity: Int] {
    [:]
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
