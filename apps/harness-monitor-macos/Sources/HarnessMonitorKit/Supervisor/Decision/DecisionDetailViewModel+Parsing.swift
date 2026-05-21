import Foundation

extension DecisionDetailViewModel {
  // MARK: Parsing

  nonisolated public static func prepareContent(input: PreparationInput) -> PreparedContent {
    let parsedActions = parseActions(from: input.suggestedActionsJSON)
    return PreparedContent(
      suggestedActions: effectiveActions(for: input, parsedActions: parsedActions),
      contextSections: parseContext(from: input.contextJSON),
      deeplinks: buildDeeplinks(from: input)
    )
  }

  nonisolated private static func parseActions(from json: String) -> [SuggestedAction] {
    guard let data = json.data(using: .utf8),
      let actions = try? JSONDecoder().decode([SuggestedAction].self, from: data)
    else {
      return []
    }
    return actions
  }

  nonisolated private static func effectiveActions(
    for input: PreparationInput,
    parsedActions: [SuggestedAction]
  ) -> [SuggestedAction] {
    guard input.ruleID != AcpPermissionDecisionPayload.ruleID else {
      return parsedActions
    }
    if parsedActions.contains(where: { $0.kind == .dismiss }) {
      return parsedActions
    }
    return parsedActions + [
      SuggestedAction(
        id: "dismiss-\(input.id)",
        title: "Dismiss",
        kind: .dismiss,
        payloadJSON: "{}"
      )
    ]
  }

  nonisolated private static func parseContext(from json: String) -> [ContextSection] {
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

  nonisolated private static func buildDeeplinks(from input: PreparationInput) -> [Deeplink] {
    var links: [Deeplink] = []
    if let sessionID = input.sessionID {
      links.append(Deeplink(kind: .session, id: sessionID))
    }
    if let agentID = input.agentID {
      links.append(Deeplink(kind: .agent, id: agentID))
    }
    if let taskID = input.taskID {
      links.append(Deeplink(kind: .task, id: taskID))
    }
    return links
  }

  nonisolated private static func isProminentActionCandidate(_ action: SuggestedAction) -> Bool {
    switch action.kind {
    case .dismiss, .snooze:
      false
    default:
      true
    }
  }

  nonisolated static func scopedAuditTrail(
    events: [SupervisorEventSnapshot],
    scope: AuditScope
  ) -> [SupervisorEventSnapshot] {
    events
      .filter { event in
        matchesAuditEvent(event, scope: scope)
      }
      .sorted { lhs, rhs in
        lhs.createdAt < rhs.createdAt
      }
  }

  nonisolated private static func matchesAuditEvent(
    _ event: SupervisorEventSnapshot,
    scope: AuditScope
  ) -> Bool {
    guard event.ruleID == nil || event.ruleID == scope.ruleID else {
      return false
    }
    let payloadScope = AuditPayloadScope(payloadJSON: event.payloadJSON)
    return payloadScope.matches(decision: scope)
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

public actor DecisionDetailPreparationWorker {
  public init() {}

  public func prepare(
    input: DecisionDetailViewModel.PreparationInput
  ) -> DecisionDetailViewModel.PreparedContent {
    DecisionDetailViewModel.prepareContent(input: input)
  }

  public func waitForIdle() async {}
}

public actor DecisionAuditScopeWorker {
  public init() {}

  public func scopedAuditTrail(
    input: DecisionDetailViewModel.AuditScopeInput
  ) -> [SupervisorEventSnapshot] {
    DecisionDetailViewModel.scopedAuditTrail(events: input.events, scope: input.scope)
  }

  public func waitForIdle() async {}
}

private struct AuditPayloadScope {
  let sessionID: String?
  let agentID: String?
  let taskID: String?
  let decisionID: String?

  init(payloadJSON: String) {
    guard let data = payloadJSON.data(using: .utf8) else {
      sessionID = nil
      agentID = nil
      taskID = nil
      decisionID = nil
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
    decisionID = Self.firstString(
      forKeys: ["decisionID", "decisionId", "decision_id"],
      in: object
    )
  }

  func matches(decision: DecisionDetailViewModel.AuditScope) -> Bool {
    matches(expected: decision.decisionID, actual: decisionID)
      && matches(expected: decision.sessionID, actual: sessionID)
      && matches(expected: decision.agentID, actual: agentID)
      && matches(expected: decision.taskID, actual: taskID)
  }

  func matchesExplicitSessionScope(
    sessionID expectedSessionID: String,
    decisionIDs: Set<String>,
    agentIDs: Set<String>,
    taskIDs: Set<String>
  ) -> Bool {
    let sessionMatches = self.sessionID.map { $0 == expectedSessionID }
    if sessionMatches == false {
      return false
    }

    let decisionMatches = decisionID.map { decisionIDs.contains($0) }
    if decisionMatches == false {
      return false
    }

    let taskMatches = taskID.map { taskIDs.contains($0) }
    if taskMatches == false {
      return false
    }

    let agentMatches = agentID.map { agentIDs.contains($0) }
    if agentMatches == false {
      return false
    }

    return decisionMatches == true
      || taskMatches == true
      || agentMatches == true
      || sessionMatches == true
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
