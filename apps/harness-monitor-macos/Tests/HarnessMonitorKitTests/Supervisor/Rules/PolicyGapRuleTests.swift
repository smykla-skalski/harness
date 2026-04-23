import XCTest

@testable import HarnessMonitorKit

final class PolicyGapRuleTests: XCTestCase {
  func test_knownClassifierCodesIsSeededFromRustCatalog() {
    XCTAssertTrue(PolicyGapRule.knownClassifierCodes.contains("hook_denied_tool_call"))
    XCTAssertTrue(PolicyGapRule.knownClassifierCodes.contains("build_or_lint_failure"))
    XCTAssertTrue(PolicyGapRule.knownClassifierCodes.contains("agent_stalled_progress"))
    XCTAssertTrue(PolicyGapRule.knownClassifierCodes.contains("cross_agent_file_conflict"))
    XCTAssertEqual(PolicyGapRule.knownClassifierCodes.count, 62)
  }

  func test_knownClassifierCodeProducesNoAction() async {
    let rule = PolicyGapRule()
    let snapshot = makeSnapshot(issueCodes: ["build_or_lint_failure"])

    let actions = await rule.evaluate(snapshot: snapshot, context: .empty)

    XCTAssertTrue(actions.isEmpty)
  }

  func test_multipleKnownCodesProduceNoAction() async {
    let rule = PolicyGapRule()
    let snapshot = makeSnapshot(issueCodes: [
      "hook_denied_tool_call",
      "harness_cli_error_output",
      "agent_stalled_progress",
    ])

    let actions = await rule.evaluate(snapshot: snapshot, context: .empty)

    XCTAssertTrue(actions.isEmpty)
  }

  func test_unknownClassifierCodeProducesLogAndDecision() async {
    let rule = PolicyGapRule()
    let unknownCode = "some_future_classifier_code_never_seen_before"
    let snapshot = makeSnapshot(issueCodes: [unknownCode])

    let actions = await rule.evaluate(snapshot: snapshot, context: .empty)

    XCTAssertEqual(actions.count, 2)

    guard case .logEvent(let logPayload) = actions[0] else {
      XCTFail("First action must be .logEvent; got \(actions[0])")
      return
    }
    XCTAssertEqual(logPayload.ruleID, "policy-gap")
    XCTAssertTrue(logPayload.message.contains(unknownCode))

    guard case .queueDecision(let decisionPayload) = actions[1] else {
      XCTFail("Second action must be .queueDecision; got \(actions[1])")
      return
    }
    XCTAssertEqual(decisionPayload.ruleID, "policy-gap")
    XCTAssertEqual(decisionPayload.severity, .info)
    XCTAssertTrue(decisionPayload.summary.contains(unknownCode))
  }

  func test_mixedKnownAndUnknownCodesOnlyEmitsForUnknown() async {
    let rule = PolicyGapRule()
    let unknownCode = "brand_new_policy_gap_code"
    let snapshot = makeSnapshot(issueCodes: [
      "build_or_lint_failure",
      unknownCode,
      "agent_stalled_progress",
    ])

    let actions = await rule.evaluate(snapshot: snapshot, context: .empty)

    XCTAssertEqual(actions.count, 2)

    let logCount = actions.reduce(into: 0) { count, action in
      guard case .logEvent = action else { return }
      count += 1
    }
    let decisionCount = actions.reduce(into: 0) { count, action in
      guard case .queueDecision = action else { return }
      count += 1
    }
    XCTAssertEqual(logCount, 1)
    XCTAssertEqual(decisionCount, 1)
  }

  func test_unknownCodeIsIdempotentWithinSnapshot() async {
    let rule = PolicyGapRule()
    let unknownCode = "repeating_unknown_code"
    let snapshot = makeSnapshot(issueCodes: [unknownCode])

    let firstPass = await rule.evaluate(snapshot: snapshot, context: .empty)
    XCTAssertEqual(firstPass.count, 2)

    let context = PolicyContext(
      now: Date.fixed,
      lastFiredAt: nil,
      recentActionKeys: Set(firstPass.map(\.actionKey)),
      parameters: PolicyParameterValues(raw: [:]),
      history: PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
    )

    let secondPass = await rule.evaluate(snapshot: snapshot, context: context)
    XCTAssertTrue(secondPass.isEmpty)
  }

  func test_ruleMetadataIsStable() {
    let rule = PolicyGapRule()
    let logActionKey = PolicyAction.logEvent(
      .init(
        id: "log-1",
        ruleID: rule.id,
        snapshotID: "snapshot-1",
        message: "Unknown classifier code detected"
      )
    ).actionKey
    let decisionActionKey = PolicyAction.queueDecision(
      .init(
        id: "decision-1",
        severity: .info,
        ruleID: rule.id,
        sessionID: nil,
        agentID: nil,
        taskID: nil,
        summary: "Teach supervisor about unknown classifier code",
        contextJSON: "{}",
        suggestedActionsJSON: "[]"
      )
    ).actionKey

    XCTAssertEqual(rule.id, "policy-gap")
    XCTAssertEqual(rule.name, "Policy Gap")
    XCTAssertEqual(rule.version, 1)
    XCTAssertEqual(rule.defaultBehavior(for: logActionKey), .aggressive)
    XCTAssertEqual(rule.defaultBehavior(for: decisionActionKey), .cautious)
  }

  private func makeSnapshot(issueCodes: [String]) -> SessionsSnapshot {
    let issues = issueCodes.enumerated().map { index, code in
      ObserverIssueSnapshot(
        id: "issue-\(index)",
        severityRaw: "warn",
        code: code,
        firstSeen: Date.fixed,
        count: 1
      )
    }

    let session = SessionSnapshot(
      id: "session-1",
      title: "Test session",
      agents: [],
      tasks: [],
      timelineDensityLastMinute: 0,
      observerIssues: issues,
      pendingCodexApprovals: []
    )

    return SessionsSnapshot(
      id: "snapshot-1",
      createdAt: Date.fixed,
      hash: "test-hash",
      sessions: [session],
      connection: ConnectionSnapshot(kind: "connected", lastMessageAt: nil, reconnectAttempt: 0)
    )
  }
}
