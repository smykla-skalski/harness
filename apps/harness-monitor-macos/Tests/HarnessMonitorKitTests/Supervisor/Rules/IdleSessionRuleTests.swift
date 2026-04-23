import Foundation
import XCTest

@testable import HarnessMonitorKit

final class IdleSessionRuleTests: XCTestCase {
  // MARK: - Trigger boundary

  func test_doesNotTrigger_whenTimelineDensityAboveZero() async {
    let rule = IdleSessionRule()
    let now = Date.fixed
    let snapshot = snapshot(
      sessions: [
        session(
          id: "s1",
          agents: [agent(id: "a1", lastActivityAt: now.addingTimeInterval(-3_600))],
          timelineDensityLastMinute: 1
        )
      ]
    )
    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: context(now: now, parameters: ["sessionIdleThreshold": "600"])
    )
    XCTAssertTrue(actions.isEmpty)
  }

  func test_doesNotTrigger_whenIdleDurationAtThresholdBoundary() async {
    // Idle duration exactly equal to threshold must not fire; trigger is strict `> threshold`.
    let rule = IdleSessionRule()
    let now = Date.fixed
    let snapshot = snapshot(
      sessions: [
        session(
          id: "s1",
          agents: [agent(id: "a1", lastActivityAt: now.addingTimeInterval(-600))],
          timelineDensityLastMinute: 0
        )
      ]
    )
    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: context(now: now, parameters: ["sessionIdleThreshold": "600"])
    )
    XCTAssertTrue(actions.isEmpty)
  }

  func test_triggers_whenIdleDurationJustAboveThreshold() async {
    let rule = IdleSessionRule()
    let now = Date.fixed
    let snapshot = snapshot(
      sessions: [
        session(
          id: "s1",
          agents: [agent(id: "a1", lastActivityAt: now.addingTimeInterval(-601))],
          timelineDensityLastMinute: 0
        )
      ]
    )
    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: context(now: now, parameters: ["sessionIdleThreshold": "600"])
    )
    XCTAssertEqual(actions.count, 1)
    guard case .queueDecision(let payload) = actions[0] else {
      XCTFail("expected queueDecision, got \(actions[0])")
      return
    }
    XCTAssertEqual(payload.ruleID, "idle-session")
    XCTAssertEqual(payload.sessionID, "s1")
    XCTAssertEqual(payload.severity, .warn)
  }

  func test_triggers_whenAllAgentsHaveNilLastActivity() async {
    // No agent activity ever recorded is treated as infinite idleness.
    let rule = IdleSessionRule()
    let now = Date.fixed
    let snapshot = snapshot(
      sessions: [
        session(
          id: "s1",
          agents: [agent(id: "a1", lastActivityAt: nil)],
          timelineDensityLastMinute: 0
        )
      ]
    )
    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: context(now: now, parameters: ["sessionIdleThreshold": "600"])
    )
    XCTAssertEqual(actions.count, 1)
  }

  func test_doesNotTrigger_forSessionWithoutAgents() async {
    let rule = IdleSessionRule()
    let now = Date.fixed
    let snapshot = snapshot(
      sessions: [
        session(id: "s1", agents: [], timelineDensityLastMinute: 0)
      ]
    )
    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: context(now: now, parameters: ["sessionIdleThreshold": "600"])
    )
    XCTAssertTrue(actions.isEmpty)
  }

  // MARK: - Suggested actions

  func test_queueDecisionCarriesCheckInAndCloseActions() async throws {
    let rule = IdleSessionRule()
    let now = Date.fixed
    let snapshot = snapshot(
      sessions: [
        session(
          id: "session-abc",
          agents: [agent(id: "a1", lastActivityAt: now.addingTimeInterval(-1_800))],
          timelineDensityLastMinute: 0
        )
      ]
    )
    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: context(now: now, parameters: ["sessionIdleThreshold": "600"])
    )
    guard case .queueDecision(let payload) = actions.first else {
      XCTFail("expected queueDecision")
      return
    }

    let decoder = JSONDecoder()
    let suggested = try decoder.decode(
      [SuggestedAction].self,
      from: Data(payload.suggestedActionsJSON.utf8)
    )
    XCTAssertEqual(suggested.count, 2)
    XCTAssertEqual(suggested[0].title, "Send check-in nudge")
    XCTAssertEqual(suggested[0].kind, .nudge)
    XCTAssertEqual(suggested[1].title, "Close session")
    XCTAssertEqual(suggested[1].kind, .custom)

    // contextJSON round-trips canonical data for the Decisions UI.
    let contextData = Data(payload.contextJSON.utf8)
    let parsed = try JSONSerialization.jsonObject(with: contextData) as? [String: Any]
    XCTAssertEqual(parsed?["sessionID"] as? String, "session-abc")
  }

  // MARK: - Idempotency via stable action key

  func test_actionKeyIsStableAcrossTicks() async {
    let rule = IdleSessionRule()
    let now = Date.fixed
    let snapshot1 = snapshot(
      id: "snap-1",
      sessions: [
        session(
          id: "s1",
          agents: [agent(id: "a1", lastActivityAt: now.addingTimeInterval(-1_800))],
          timelineDensityLastMinute: 0
        )
      ]
    )
    let snapshot2 = snapshot(
      id: "snap-2",
      sessions: [
        session(
          id: "s1",
          agents: [agent(id: "a1", lastActivityAt: now.addingTimeInterval(-2_400))],
          timelineDensityLastMinute: 0
        )
      ]
    )
    let actions1 = await rule.evaluate(snapshot: snapshot1, context: context(now: now))
    let actions2 = await rule.evaluate(snapshot: snapshot2, context: context(now: now))
    XCTAssertEqual(actions1.first?.actionKey, actions2.first?.actionKey)
    XCTAssertEqual(actions1.first?.actionKey, "decision:idle-session:s1")
  }

  // MARK: - Parameter overrides

  func test_respectsSessionIdleThresholdOverride() async {
    let rule = IdleSessionRule()
    let now = Date.fixed
    let snapshot = snapshot(
      sessions: [
        session(
          id: "s1",
          agents: [agent(id: "a1", lastActivityAt: now.addingTimeInterval(-120))],
          timelineDensityLastMinute: 0
        )
      ]
    )
    let noOverride = await rule.evaluate(
      snapshot: snapshot,
      context: context(now: now, parameters: [:])
    )
    XCTAssertTrue(noOverride.isEmpty, "default threshold 600 should not trigger at 120s idle")

    let overridden = await rule.evaluate(
      snapshot: snapshot,
      context: context(now: now, parameters: ["sessionIdleThreshold": "60"])
    )
    XCTAssertEqual(overridden.count, 1, "override to 60s must trigger at 120s idle")
  }

  // MARK: - Rule metadata

  func test_defaultBehaviorIsCautiousForAllActionKeys() {
    let rule = IdleSessionRule()
    XCTAssertEqual(rule.defaultBehavior(for: "decision:idle-session:idle-session:s1"), .cautious)
    XCTAssertEqual(rule.defaultBehavior(for: "anything-else"), .cautious)
  }

  func test_parameterSchemaExposesSessionIdleThreshold() {
    let rule = IdleSessionRule()
    let keys = rule.parameters.fields.map(\.key)
    XCTAssertTrue(keys.contains("sessionIdleThreshold"))
    if let field = rule.parameters.fields.first(where: { $0.key == "sessionIdleThreshold" }) {
      XCTAssertEqual(field.kind, .duration)
      XCTAssertEqual(field.default, "600")
    }
  }

  // MARK: - Helpers

  private func snapshot(
    id: String = "snap",
    sessions: [SessionSnapshot],
    connectionKind: String = "connected"
  ) -> SessionsSnapshot {
    SessionsSnapshot(
      id: id,
      createdAt: Date.fixed,
      hash: "hash-\(id)",
      sessions: sessions,
      connection: ConnectionSnapshot(
        kind: connectionKind,
        lastMessageAt: Date.fixed,
        reconnectAttempt: 0
      )
    )
  }

  private func session(
    id: String,
    agents: [AgentSnapshot],
    timelineDensityLastMinute: Int
  ) -> SessionSnapshot {
    SessionSnapshot(
      id: id,
      title: nil,
      agents: agents,
      tasks: [],
      timelineDensityLastMinute: timelineDensityLastMinute,
      observerIssues: [],
      pendingCodexApprovals: []
    )
  }

  private func agent(id: String, lastActivityAt: Date?) -> AgentSnapshot {
    AgentSnapshot(
      id: id,
      runtime: "claude",
      statusRaw: "idle",
      lastActivityAt: lastActivityAt,
      idleSeconds: nil,
      currentTaskID: nil
    )
  }

  private func context(now: Date, parameters: [String: String] = [:]) -> PolicyContext {
    PolicyContext(
      now: now,
      lastFiredAt: nil,
      recentActionKeys: [],
      parameters: PolicyParameterValues(raw: parameters),
      history: PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
    )
  }
}
