import XCTest

@testable import HarnessMonitorKit

@MainActor
final class DecisionDetailViewModelTests: XCTestCase {
  private func makeDecision(
    id: String = "d1",
    severity: DecisionSeverity = .needsUser,
    ruleID: String = "stuck-agent",
    sessionID: String? = "sess-1",
    agentID: String? = "agent-1",
    taskID: String? = nil,
    summary: String = "Agent idle for 12 minutes",
    contextJSON: String = "{}",
    suggestedActionsJSON: String = "[]"
  ) -> Decision {
    Decision(
      id: id,
      severity: severity,
      ruleID: ruleID,
      sessionID: sessionID,
      agentID: agentID,
      taskID: taskID,
      summary: summary,
      contextJSON: contextJSON,
      suggestedActionsJSON: suggestedActionsJSON
    )
  }

  private func encodedActions(_ actions: [SuggestedAction]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(actions)) ?? Data("[]".utf8)
    return String(data: data, encoding: .utf8) ?? "[]"
  }

  func test_parsesSuggestedActionsFromJSON() {
    let actions = [
      SuggestedAction(id: "accept", title: "Accept", kind: .custom, payloadJSON: "{}"),
      SuggestedAction(id: "decline", title: "Decline", kind: .custom, payloadJSON: "{}"),
    ]
    let decision = makeDecision(suggestedActionsJSON: encodedActions(actions))

    let handler = RecordingDecisionActionHandler()
    let viewModel = DecisionDetailViewModel(decision: decision, handler: handler)

    XCTAssertEqual(viewModel.suggestedActions.count, 2)
    XCTAssertEqual(viewModel.suggestedActions.first?.id, "accept")
    XCTAssertEqual(viewModel.suggestedActions.last?.title, "Decline")
  }

  func test_parsesContextSectionsFromJSON() {
    let contextJSON = """
      {
        "snapshotExcerpt": "agent=agent-1 idle=720s",
        "relatedTimeline": ["signal.sent: 12:01", "reply: 12:05"],
        "observerIssues": ["observer_idle_gap"],
        "recentActions": ["nudge.sent"]
      }
      """
    let decision = makeDecision(contextJSON: contextJSON)

    let viewModel = DecisionDetailViewModel(
      decision: decision,
      handler: RecordingDecisionActionHandler()
    )

    XCTAssertEqual(viewModel.contextSections.count, 4)
    let titles = viewModel.contextSections.map(\.title)
    XCTAssertEqual(
      titles,
      ["Snapshot", "Related timeline", "Observer issues", "Recent supervisor actions"]
    )
    XCTAssertEqual(viewModel.contextSections[0].lines, ["agent=agent-1 idle=720s"])
    XCTAssertEqual(viewModel.contextSections[1].lines.count, 2)
  }

  func test_missingContextSectionsAreOmitted() {
    let decision = makeDecision(contextJSON: "{\"snapshotExcerpt\":\"partial only\"}")

    let viewModel = DecisionDetailViewModel(
      decision: decision,
      handler: RecordingDecisionActionHandler()
    )

    XCTAssertEqual(viewModel.contextSections.count, 1)
    XCTAssertEqual(viewModel.contextSections.first?.title, "Snapshot")
  }

  func test_malformedContextJSONYieldsRawFallback() {
    let decision = makeDecision(contextJSON: "not json")

    let viewModel = DecisionDetailViewModel(
      decision: decision,
      handler: RecordingDecisionActionHandler()
    )

    XCTAssertEqual(viewModel.contextSections.count, 1)
    XCTAssertEqual(viewModel.contextSections.first?.title, "Raw context")
    XCTAssertEqual(viewModel.contextSections.first?.lines, ["not json"])
  }

  func test_acceptInvokesResolveWithChosenAction() async {
    let action = SuggestedAction(
      id: "accept",
      title: "Accept",
      kind: .custom,
      payloadJSON: "{\"approvalID\":\"ap-1\"}"
    )
    let decision = makeDecision(suggestedActionsJSON: encodedActions([action]))
    let handler = RecordingDecisionActionHandler()
    let viewModel = DecisionDetailViewModel(decision: decision, handler: handler)

    await viewModel.invoke(action: action)

    XCTAssertEqual(handler.resolvedCalls.count, 1)
    XCTAssertEqual(handler.resolvedCalls.first?.decisionID, "d1")
    XCTAssertEqual(handler.resolvedCalls.first?.outcome.chosenActionID, "accept")
  }

  func test_snoozeActionOpensSnoozeSheet() async {
    let snooze = SuggestedAction(
      id: "snooze-1h",
      title: "Snooze 1h",
      kind: .snooze,
      payloadJSON: "{\"duration\":3600}"
    )
    let decision = makeDecision(suggestedActionsJSON: encodedActions([snooze]))
    let handler = RecordingDecisionActionHandler()
    let viewModel = DecisionDetailViewModel(decision: decision, handler: handler)

    await viewModel.invoke(action: snooze)

    XCTAssertNotNil(viewModel.snoozeRequest)
    XCTAssertEqual(viewModel.snoozeRequest?.decisionID, "d1")
    XCTAssertTrue(handler.resolvedCalls.isEmpty, "Snooze opens sheet, does not resolve directly")
  }

  func test_confirmSnoozeInvokesHandlerAndClearsSheet() async {
    let decision = makeDecision()
    let handler = RecordingDecisionActionHandler()
    let viewModel = DecisionDetailViewModel(decision: decision, handler: handler)
    viewModel.snoozeRequest = DecisionDetailViewModel.SnoozeRequest(decisionID: "d1")

    await viewModel.confirmSnooze(duration: 3600)

    XCTAssertNil(viewModel.snoozeRequest)
    XCTAssertEqual(handler.snoozeCalls.count, 1)
    XCTAssertEqual(handler.snoozeCalls.first?.decisionID, "d1")
    XCTAssertEqual(handler.snoozeCalls.first?.duration, 3600)
  }

  func test_dismissActionInvokesHandler() async {
    let dismiss = SuggestedAction(
      id: "dismiss",
      title: "Dismiss",
      kind: .dismiss,
      payloadJSON: "{}"
    )
    let decision = makeDecision(suggestedActionsJSON: encodedActions([dismiss]))
    let handler = RecordingDecisionActionHandler()
    let viewModel = DecisionDetailViewModel(decision: decision, handler: handler)

    await viewModel.invoke(action: dismiss)

    XCTAssertEqual(handler.dismissCalls, ["d1"])
  }

  func test_primaryActionIsFirstNonTerminal() {
    let actions = [
      SuggestedAction(id: "accept", title: "Accept", kind: .custom, payloadJSON: "{}"),
      SuggestedAction(id: "decline", title: "Decline", kind: .custom, payloadJSON: "{}"),
      SuggestedAction(id: "snooze", title: "Snooze", kind: .snooze, payloadJSON: "{}"),
      SuggestedAction(id: "dismiss", title: "Dismiss", kind: .dismiss, payloadJSON: "{}"),
    ]
    let decision = makeDecision(suggestedActionsJSON: encodedActions(actions))
    let viewModel = DecisionDetailViewModel(
      decision: decision,
      handler: RecordingDecisionActionHandler()
    )

    XCTAssertEqual(viewModel.primaryActionID, "accept")
  }

  func test_primaryActionSkipsTerminalKindsAtFrontOfList() {
    let actions = [
      SuggestedAction(id: "dismiss", title: "Dismiss", kind: .dismiss, payloadJSON: "{}"),
      SuggestedAction(id: "snooze", title: "Snooze", kind: .snooze, payloadJSON: "{}"),
      SuggestedAction(id: "accept", title: "Accept", kind: .custom, payloadJSON: "{}"),
    ]
    let decision = makeDecision(suggestedActionsJSON: encodedActions(actions))
    let viewModel = DecisionDetailViewModel(
      decision: decision,
      handler: RecordingDecisionActionHandler()
    )

    XCTAssertEqual(viewModel.primaryActionID, "accept")
  }

  func test_isPrimaryActionUsesFirstActionOnly() {
    let actions = [
      SuggestedAction(id: "decline", title: "Decline", kind: .custom, payloadJSON: "{}"),
      SuggestedAction(id: "accept", title: "Accept", kind: .custom, payloadJSON: "{}"),
    ]
    let decision = makeDecision(suggestedActionsJSON: encodedActions(actions))
    let viewModel = DecisionDetailViewModel(
      decision: decision,
      handler: RecordingDecisionActionHandler()
    )

    XCTAssertTrue(viewModel.isPrimary(actions[0]))
    XCTAssertFalse(viewModel.isPrimary(actions[1]))
  }

  func test_deeplinksBuiltFromIDs() {
    let decision = makeDecision(
      sessionID: "sess-12",
      agentID: "agent-7",
      taskID: "task-99"
    )
    let viewModel = DecisionDetailViewModel(
      decision: decision,
      handler: RecordingDecisionActionHandler()
    )

    XCTAssertEqual(viewModel.deeplinks.count, 3)
    XCTAssertEqual(viewModel.deeplinks[0].kind, .session)
    XCTAssertEqual(viewModel.deeplinks[0].id, "sess-12")
    XCTAssertEqual(viewModel.deeplinks[1].kind, .agent)
    XCTAssertEqual(viewModel.deeplinks[2].kind, .task)
  }

  func test_deeplinksSkipNilFields() {
    let decision = makeDecision(sessionID: "sess-12", agentID: nil, taskID: nil)
    let viewModel = DecisionDetailViewModel(
      decision: decision,
      handler: RecordingDecisionActionHandler()
    )

    XCTAssertEqual(viewModel.deeplinks.count, 1)
    XCTAssertEqual(viewModel.deeplinks.first?.kind, .session)
  }

  func test_formatsAgeAsRelativeDuration() {
    let decision = makeDecision()
    decision.createdAt = Date().addingTimeInterval(-90)
    let viewModel = DecisionDetailViewModel(
      decision: decision,
      handler: RecordingDecisionActionHandler()
    )

    let age = viewModel.formattedAge(reference: Date())
    XCTAssertTrue(age.contains("1") && (age.contains("min") || age.contains("m")))
  }

  func test_scopedAuditTrailFiltersByRuleAndPayloadScopeAndSortsChronologically() {
    let decision = makeDecision(
      ruleID: "stuck-agent",
      sessionID: "sess-1",
      agentID: "agent-1",
      taskID: "task-1"
    )
    let viewModel = DecisionDetailViewModel(
      decision: decision,
      handler: RecordingDecisionActionHandler()
    )
    let oldest = SupervisorEvent(
      id: "evt-older",
      tickID: "tick-1",
      kind: "observe",
      ruleID: "stuck-agent",
      severity: nil,
      payloadJSON: "{\"summary\":\"phase 1 payload without scope\"}"
    )
    oldest.createdAt = Date(timeIntervalSince1970: 10)
    let nestedMatch = SupervisorEvent(
      id: "evt-match",
      tickID: "tick-2",
      kind: "dispatch",
      ruleID: "stuck-agent",
      severity: .warn,
      payloadJSON:
        "{\"target\":{\"sessionID\":\"sess-1\",\"agentID\":\"agent-1\",\"taskID\":\"task-1\"}}"
    )
    nestedMatch.createdAt = Date(timeIntervalSince1970: 20)
    let wrongAgent = SupervisorEvent(
      id: "evt-other-agent",
      tickID: "tick-3",
      kind: "dispatch",
      ruleID: "stuck-agent",
      severity: .warn,
      payloadJSON:
        "{\"target\":{\"sessionID\":\"sess-1\",\"agentID\":\"agent-9\",\"taskID\":\"task-1\"}}"
    )
    wrongAgent.createdAt = Date(timeIntervalSince1970: 15)
    let wrongRule = SupervisorEvent(
      id: "evt-other-rule",
      tickID: "tick-4",
      kind: "dispatch",
      ruleID: "other-rule",
      severity: .warn,
      payloadJSON: "{\"sessionID\":\"sess-1\",\"agentID\":\"agent-1\",\"taskID\":\"task-1\"}"
    )
    wrongRule.createdAt = Date(timeIntervalSince1970: 5)

    let scoped = viewModel.scopedAuditTrail(from: [nestedMatch, wrongAgent, wrongRule, oldest])

    XCTAssertEqual(scoped.map(\.id), ["evt-older", "evt-match"])
  }
}

final class RecordingDecisionActionHandler: DecisionActionHandler, @unchecked Sendable {
  struct ResolveCall: Sendable {
    let decisionID: String
    let outcome: DecisionOutcome
  }

  struct SnoozeCall: Sendable {
    let decisionID: String
    let duration: TimeInterval
  }

  var resolvedCalls: [ResolveCall] = []
  var snoozeCalls: [SnoozeCall] = []
  var dismissCalls: [String] = []

  func resolve(decisionID: String, outcome: DecisionOutcome) async {
    resolvedCalls.append(ResolveCall(decisionID: decisionID, outcome: outcome))
  }

  func snooze(decisionID: String, duration: TimeInterval) async {
    snoozeCalls.append(SnoozeCall(decisionID: decisionID, duration: duration))
  }

  func dismiss(decisionID: String) async {
    dismissCalls.append(decisionID)
  }
}
