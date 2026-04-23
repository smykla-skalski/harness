import Foundation
import Observation

/// View model that drives `DecisionDetailView`. Owns parsing of the persisted JSON blobs
/// (`suggestedActionsJSON`, `contextJSON`) into typed structures and routes user interactions
/// through a `DecisionActionHandler`.
///
/// The view model is independent of SwiftData — callers pass an already-fetched `Decision`.
/// Phase 2 worker 20 uses it from the Decisions window; Phase 2 worker 27 (Codex unification)
/// reuses it in the Agents window so both surfaces resolve through a single code path.
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

  public let decision: Decision
  public private(set) var suggestedActions: [SuggestedAction]
  public private(set) var contextSections: [ContextSection]
  public private(set) var deeplinks: [Deeplink]
  public var snoozeRequest: SnoozeRequest?

  @ObservationIgnored private let handler: any DecisionActionHandler

  public init(decision: Decision, handler: any DecisionActionHandler) {
    self.decision = decision
    self.handler = handler
    self.suggestedActions = Self.parseActions(from: decision.suggestedActionsJSON)
    self.contextSections = Self.parseContext(from: decision.contextJSON)
    self.deeplinks = Self.buildDeeplinks(from: decision)
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
  public func scopedAuditTrail(from events: [SupervisorEvent]) -> [SupervisorEvent] {
    events
      .filter { event in
        Self.matchesAuditEvent(event, decision: decision)
      }
      .sorted { lhs, rhs in
        lhs.createdAt < rhs.createdAt
      }
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

  // MARK: Parsing

  private static func parseActions(from json: String) -> [SuggestedAction] {
    guard let data = json.data(using: .utf8),
      let actions = try? JSONDecoder().decode([SuggestedAction].self, from: data)
    else {
      return []
    }
    return actions
  }

  private static func parseContext(from json: String) -> [ContextSection] {
    guard let data = json.data(using: .utf8) else {
      return [ContextSection(title: "Raw context", lines: [json])]
    }
    let decoder = JSONDecoder()
    if let parsed = try? decoder.decode(ContextBlob.self, from: data) {
      return parsed.sections()
    }
    let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "{}", trimmed != "[]" else {
      return []
    }
    return [ContextSection(title: "Raw context", lines: [trimmed])]
  }

  private static func buildDeeplinks(from decision: Decision) -> [Deeplink] {
    var links: [Deeplink] = []
    if let sessionID = decision.sessionID {
      links.append(Deeplink(kind: .session, id: sessionID))
    }
    if let agentID = decision.agentID {
      links.append(Deeplink(kind: .agent, id: agentID))
    }
    if let taskID = decision.taskID {
      links.append(Deeplink(kind: .task, id: taskID))
    }
    return links
  }

  private static func isProminentActionCandidate(_ action: SuggestedAction) -> Bool {
    switch action.kind {
    case .dismiss, .snooze:
      false
    default:
      true
    }
  }

  private static func matchesAuditEvent(_ event: SupervisorEvent, decision: Decision) -> Bool {
    guard event.ruleID == nil || event.ruleID == decision.ruleID else {
      return false
    }
    let payloadScope = AuditPayloadScope(payloadJSON: event.payloadJSON)
    return payloadScope.matches(decision: decision)
  }

  @MainActor private static let ageFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()
}

// MARK: - Parsed context blob

private struct ContextBlob: Decodable {
  let snapshotExcerpt: String?
  let relatedTimeline: [String]?
  let observerIssues: [String]?
  let recentActions: [String]?

  func sections() -> [DecisionDetailViewModel.ContextSection] {
    var sections: [DecisionDetailViewModel.ContextSection] = []
    if let snapshotExcerpt, !snapshotExcerpt.isEmpty {
      sections.append(
        .init(title: "Snapshot", lines: [snapshotExcerpt])
      )
    }
    if let relatedTimeline, !relatedTimeline.isEmpty {
      sections.append(.init(title: "Related timeline", lines: relatedTimeline))
    }
    if let observerIssues, !observerIssues.isEmpty {
      sections.append(.init(title: "Observer issues", lines: observerIssues))
    }
    if let recentActions, !recentActions.isEmpty {
      sections.append(.init(title: "Recent supervisor actions", lines: recentActions))
    }
    return sections
  }
}

private struct AuditPayloadScope {
  let sessionID: String?
  let agentID: String?
  let taskID: String?

  init(payloadJSON: String) {
    guard let data = payloadJSON.data(using: .utf8) else {
      sessionID = nil
      agentID = nil
      taskID = nil
      return
    }
    let object = try? JSONSerialization.jsonObject(with: data)
    sessionID = Self.firstString(
      forKeys: ["sessionID", "sessionId", "session_id"],
      in: object
    )
    agentID = Self.firstString(
      forKeys: ["agentID", "agentId", "agent_id"],
      in: object
    )
    taskID = Self.firstString(
      forKeys: ["taskID", "taskId", "task_id"],
      in: object
    )
  }

  func matches(decision: Decision) -> Bool {
    matches(expected: decision.sessionID, actual: sessionID)
      && matches(expected: decision.agentID, actual: agentID)
      && matches(expected: decision.taskID, actual: taskID)
  }

  private func matches(expected: String?, actual: String?) -> Bool {
    guard let expected else {
      return true
    }
    guard let actual else {
      return true
    }
    return expected == actual
  }

  private static func firstString(forKeys keys: [String], in object: Any?) -> String? {
    if let dictionary = object as? [String: Any] {
      for key in keys {
        if let value = stringValue(dictionary[key]) {
          return value
        }
      }
      for value in dictionary.values {
        if let nested = firstString(forKeys: keys, in: value) {
          return nested
        }
      }
    }
    if let array = object as? [Any] {
      for value in array {
        if let nested = firstString(forKeys: keys, in: value) {
          return nested
        }
      }
    }
    return nil
  }

  private static func stringValue(_ value: Any?) -> String? {
    guard let value = value as? String, !value.isEmpty else {
      return nil
    }
    return value
  }
}
