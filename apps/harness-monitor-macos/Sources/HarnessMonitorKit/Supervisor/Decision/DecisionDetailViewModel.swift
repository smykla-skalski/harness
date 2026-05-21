import Foundation
import Observation

/// View model that drives `DecisionDetailView`. Owns parsing of the persisted JSON blobs
/// (`suggestedActionsJSON`, `contextJSON`) into typed structures and routes user interactions
/// through a `DecisionActionHandler`.
///
/// The view model is independent of SwiftData — callers pass an already-fetched `Decision`.
/// Phase 2 worker 20 uses it from the workspace window; Phase 2 worker 27 (Codex unification)
/// reuses it in the Workspace window so both surfaces resolve through a single code path.
@MainActor
@Observable
public final class DecisionDetailViewModel {
  /// Parsed context section rendered by `DecisionContextPanel`.
  public struct ContextSection: Sendable, Hashable, Identifiable {
    public var id: String { title }
    public let title: String
    public let lines: [String]

    public init(title: String, lines: [String]) {
      self.title = title
      self.lines = lines
    }
  }

  /// Deeplink badge rendered in the header when the decision scopes to a session / agent / task.
  public struct Deeplink: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
      case session
      case agent
      case task
    }

    public let kind: Kind
    public let id: String

    public init(kind: Kind, id: String) {
      self.kind = kind
      self.id = id
    }

    /// Stable key suitable for SwiftUI `ForEach` where two deeplinks might share the raw id.
    public var stableKey: String { "\(kind.rawValue):\(id)" }
  }

  /// Marker sent to the snooze sub-sheet via `.sheet(item:)`.
  public struct SnoozeRequest: Sendable, Hashable, Identifiable {
    public let decisionID: String
    public var id: String { decisionID }

    public init(decisionID: String) {
      self.decisionID = decisionID
    }
  }

  public struct PreparationInput: Equatable, Sendable {
    public let id: String
    public let ruleID: String
    public let sessionID: String?
    public let agentID: String?
    public let taskID: String?
    public let contextJSON: String
    public let suggestedActionsJSON: String

    @MainActor
    public init(decision: Decision) {
      id = decision.id
      ruleID = decision.ruleID
      sessionID = decision.sessionID
      agentID = decision.agentID
      taskID = decision.taskID
      contextJSON = decision.contextJSON
      suggestedActionsJSON = decision.suggestedActionsJSON
    }
  }

  public struct PreparedContent: Equatable, Sendable {
    public let suggestedActions: [SuggestedAction]
    public let contextSections: [ContextSection]
    public let deeplinks: [Deeplink]

    public init(
      suggestedActions: [SuggestedAction],
      contextSections: [ContextSection],
      deeplinks: [Deeplink]
    ) {
      self.suggestedActions = suggestedActions
      self.contextSections = contextSections
      self.deeplinks = deeplinks
    }
  }

  public struct AuditScope: Equatable, Sendable {
    public let decisionID: String
    public let ruleID: String
    public let sessionID: String?
    public let agentID: String?
    public let taskID: String?

    @MainActor
    public init(decision: Decision) {
      decisionID = decision.id
      ruleID = decision.ruleID
      sessionID = decision.sessionID
      agentID = decision.agentID
      taskID = decision.taskID
    }
  }

  public struct AuditScopeInput: Equatable, Sendable {
    public let scope: AuditScope
    public let events: [SupervisorEventSnapshot]

    @MainActor
    public init(decision: Decision, events: [SupervisorEventSnapshot]) {
      scope = AuditScope(decision: decision)
      self.events = events
    }
  }

  public let decision: Decision
  public private(set) var suggestedActions: [SuggestedAction]
  public private(set) var contextSections: [ContextSection]
  public private(set) var deeplinks: [Deeplink]
  public var snoozeRequest: SnoozeRequest?

  @ObservationIgnored let handler: any DecisionActionHandler

  public convenience init(decision: Decision, handler: any DecisionActionHandler) {
    self.init(
      decision: decision,
      handler: handler,
      preparedContent: Self.prepareContent(input: PreparationInput(decision: decision))
    )
  }

  public init(
    decision: Decision,
    handler: any DecisionActionHandler,
    preparedContent: PreparedContent
  ) {
    self.decision = decision
    self.handler = handler
    self.suggestedActions = preparedContent.suggestedActions
    self.contextSections = preparedContent.contextSections
    self.deeplinks = preparedContent.deeplinks
  }

  public var severity: DecisionSeverity {
    DecisionSeverity(rawValue: decision.severityRaw) ?? .info
  }

  /// Identifier of the action rendered with `.glassProminent`. All other actions render with
  /// `.glass`.
  public var primaryActionID: String? {
    suggestedActions.first(where: Self.isProminentActionCandidate)?.id ?? suggestedActions.first?.id
  }

  public func isPrimary(_ action: SuggestedAction) -> Bool {
    primaryActionID == action.id
  }

  /// Chronological audit trail scoped to this decision's rule and optional session / agent /
  /// task identifiers. Payloads that do not carry scope identifiers still match when the rule
  /// matches because phase-1 audit rows do not persist full target metadata yet.
  public func scopedAuditTrail(
    from events: [SupervisorEventSnapshot]
  ) -> [SupervisorEventSnapshot] {
    Self.scopedAuditTrail(
      events: events,
      scope: AuditScope(decision: decision)
    )
  }

  /// Invoke the user-selected action. Terminal kinds (`.dismiss`) and `.snooze` route through
  /// their dedicated handlers; everything else resolves the decision with the chosen action id.
  public func invoke(action: SuggestedAction) async {
    switch action.kind {
    case .snooze:
      snoozeRequest = SnoozeRequest(decisionID: decision.id)
    case .dismiss:
      await handler.dismiss(decisionID: decision.id)
    default:
      let outcome = DecisionOutcome(chosenActionID: action.id, note: nil)
      await handler.resolve(decisionID: decision.id, outcome: outcome)
    }
  }

  /// Confirm the snooze sub-sheet with the chosen duration.
  public func confirmSnooze(duration: TimeInterval) async {
    let decisionID = snoozeRequest?.decisionID ?? decision.id
    snoozeRequest = nil
    await handler.snooze(decisionID: decisionID, duration: duration)
  }

  public func cancelSnooze() {
    snoozeRequest = nil
  }

  public func formattedAge(reference: Date) -> String {
    let interval = reference.timeIntervalSince(decision.createdAt)
    let formatter = Self.ageFormatter
    return formatter.localizedString(fromTimeInterval: -interval)
  }

  public static func explicitlySessionScopedAuditEvents(
    from events: [SupervisorEventSnapshot],
    sessionID: String,
    decisions: [Decision]
  ) -> [SupervisorEventSnapshot] {
    let decisionIDs = Set(decisions.map(\.id))
    let agentIDs = Set(decisions.compactMap(\.agentID))
    let taskIDs = Set(decisions.compactMap(\.taskID))
    return events.filter { event in
      AuditPayloadScope(payloadJSON: event.payloadJSON).matchesExplicitSessionScope(
        sessionID: sessionID,
        decisionIDs: decisionIDs,
        agentIDs: agentIDs,
        taskIDs: taskIDs
      )
    }
  }

}
