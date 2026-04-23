import XCTest

@testable import HarnessMonitorKit

/// Phase 2 worker 12 — FailedNudgeLoopRule.
///
/// Trigger: three consecutive `.actionFailed` events for the same agent emitted by
/// `StuckAgentRule`. The rule reads history from `PolicyContext.history.recentEvents`
/// and keys agent identity off the stored `actionKey` inside each summary's `id`.
/// Every fire emits a `.queueDecision` with severity `needsUser`; the decision id is
/// derived from the (ruleID, agentID) pair so the executor's idempotency cache
/// treats the same unresolved loop as a duplicate until a new decision is warranted.
final class FailedNudgeLoopRuleTests: XCTestCase {
  func test_firesAtConsecutiveFailureThreshold() async {
    let rule = FailedNudgeLoopRule()
    let snapshot = FailedNudgeLoopRuleFixtures.snapshot()
    let context = FailedNudgeLoopRuleFixtures.context(
      events: FailedNudgeLoopRuleFixtures.failures(
        agentID: "agent-a",
        count: 3
      )
    )

    let actions = await rule.evaluate(snapshot: snapshot, context: context)

    XCTAssertEqual(actions.count, 1)
    guard case .queueDecision(let payload) = actions.first else {
      XCTFail("expected .queueDecision, got \(String(describing: actions.first))")
      return
    }
    XCTAssertEqual(payload.severity, .needsUser)
    XCTAssertEqual(payload.ruleID, "failed-nudge-loop")
    XCTAssertEqual(payload.agentID, "agent-a")
    XCTAssertTrue(payload.summary.contains("agent-a"))
    XCTAssertTrue(payload.suggestedActionsJSON.contains("Restart agent"))
    XCTAssertTrue(payload.suggestedActionsJSON.contains("Stop nudging this agent"))
    XCTAssertTrue(payload.suggestedActionsJSON.contains("Investigate manually"))
  }

  func test_doesNotFireBelowThreshold() async {
    let rule = FailedNudgeLoopRule()
    let snapshot = FailedNudgeLoopRuleFixtures.snapshot()
    let context = FailedNudgeLoopRuleFixtures.context(
      events: FailedNudgeLoopRuleFixtures.failures(
        agentID: "agent-a",
        count: 2
      )
    )

    let actions = await rule.evaluate(snapshot: snapshot, context: context)

    XCTAssertTrue(actions.isEmpty)
  }

  func test_ignoresFailuresFromOtherRules() async {
    let rule = FailedNudgeLoopRule()
    let snapshot = FailedNudgeLoopRuleFixtures.snapshot()
    let foreign = (0..<3).map { index in
      SupervisorEventSummary(
        id: "nudge:other-rule:agent-a:snap-\(index)",
        kind: "actionFailed",
        ruleID: "other-rule",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
      )
    }
    let context = FailedNudgeLoopRuleFixtures.context(events: foreign)

    let actions = await rule.evaluate(snapshot: snapshot, context: context)

    XCTAssertTrue(actions.isEmpty)
  }

  func test_ignoresNonFailureKinds() async {
    let rule = FailedNudgeLoopRule()
    let snapshot = FailedNudgeLoopRuleFixtures.snapshot()
    let dispatched = (0..<3).map { index in
      SupervisorEventSummary(
        id: "nudge:stuck-agent:agent-a:snap-\(index)",
        kind: "actionDispatched",
        ruleID: "stuck-agent",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
      )
    }
    let context = FailedNudgeLoopRuleFixtures.context(events: dispatched)

    let actions = await rule.evaluate(snapshot: snapshot, context: context)

    XCTAssertTrue(actions.isEmpty)
  }

  func test_countsPerAgentIndependently() async {
    let rule = FailedNudgeLoopRule()
    let snapshot = FailedNudgeLoopRuleFixtures.snapshot()
    let events =
      FailedNudgeLoopRuleFixtures.failures(agentID: "agent-a", count: 2)
      + FailedNudgeLoopRuleFixtures.failures(
        agentID: "agent-b",
        count: 3,
        startingAt: 1_700_000_010
      )
    let context = FailedNudgeLoopRuleFixtures.context(events: events)

    let actions = await rule.evaluate(snapshot: snapshot, context: context)

    XCTAssertEqual(actions.count, 1)
    if case .queueDecision(let payload) = actions.first {
      XCTAssertEqual(payload.agentID, "agent-b")
    } else {
      XCTFail("expected .queueDecision for agent-b")
    }
  }

  func test_isIdempotentAcrossEvaluations() async {
    let rule = FailedNudgeLoopRule()
    let snapshot = FailedNudgeLoopRuleFixtures.snapshot()
    let events = FailedNudgeLoopRuleFixtures.failures(agentID: "agent-a", count: 3)
    let context = FailedNudgeLoopRuleFixtures.context(events: events)

    let first = await rule.evaluate(snapshot: snapshot, context: context)
    let second = await rule.evaluate(snapshot: snapshot, context: context)

    XCTAssertEqual(first.count, 1)
    XCTAssertEqual(second.count, 1)
    if case .queueDecision(let lhs) = first.first,
      case .queueDecision(let rhs) = second.first
    {
      XCTAssertEqual(lhs.id, rhs.id)
      XCTAssertEqual(
        PolicyAction.queueDecision(lhs).actionKey,
        PolicyAction.queueDecision(rhs).actionKey
      )
    } else {
      XCTFail("expected two .queueDecision actions")
    }
  }

  func test_respectsConsecutiveFailureThresholdOverride() async {
    let rule = FailedNudgeLoopRule()
    let snapshot = FailedNudgeLoopRuleFixtures.snapshot()
    let context = FailedNudgeLoopRuleFixtures.context(
      events: FailedNudgeLoopRuleFixtures.failures(agentID: "agent-a", count: 2),
      parameters: ["consecutiveFailureThreshold": "2"]
    )

    let actions = await rule.evaluate(snapshot: snapshot, context: context)

    XCTAssertEqual(actions.count, 1)
  }

  func test_defaultBehaviorIsCautious() {
    let rule = FailedNudgeLoopRule()
    XCTAssertEqual(rule.defaultBehavior(for: "queueDecision"), .cautious)
  }

  func test_parametersSchemaExposesThreshold() {
    let rule = FailedNudgeLoopRule()
    let keys = rule.parameters.fields.map(\.key)
    XCTAssertTrue(keys.contains("consecutiveFailureThreshold"))
  }
}

private enum FailedNudgeLoopRuleFixtures {
  static func snapshot() -> SessionsSnapshot {
    SessionsSnapshot(
      id: "snap-1",
      createdAt: .fixed,
      hash: "",
      sessions: [],
      connection: .init(kind: "connected", lastMessageAt: .fixed, reconnectAttempt: 0)
    )
  }

  static func context(
    events: [SupervisorEventSummary],
    parameters: [String: String] = [:]
  ) -> PolicyContext {
    PolicyContext(
      now: .fixed,
      lastFiredAt: nil,
      recentActionKeys: [],
      parameters: PolicyParameterValues(raw: parameters),
      history: PolicyHistoryWindow(recentEvents: events, recentDecisions: [])
    )
  }

  static func failures(
    agentID: String,
    count: Int,
    startingAt baseSeconds: Double = 1_700_000_000
  ) -> [SupervisorEventSummary] {
    (0..<count).map { index in
      SupervisorEventSummary(
        id: "nudge:stuck-agent:\(agentID):snap-\(index)",
        kind: "actionFailed",
        ruleID: "stuck-agent",
        createdAt: Date(timeIntervalSince1970: baseSeconds + Double(index))
      )
    }
  }
}
