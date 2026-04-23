import Foundation
import XCTest

@testable import HarnessMonitorKit

final class StuckAgentRuleTests: XCTestCase {
  func test_parameterSchemaDeclaresThresholdRetryCountAndInterval() {
    let rule = StuckAgentRule()
    let fields = Dictionary(uniqueKeysWithValues: rule.parameters.fields.map { ($0.key, $0) })

    XCTAssertEqual(fields["stuckThreshold"]?.default, "120")
    XCTAssertEqual(fields["stuckThreshold"]?.kind, .duration)
    XCTAssertEqual(fields["nudgeMaxRetries"]?.default, "3")
    XCTAssertEqual(fields["nudgeMaxRetries"]?.kind, .integer)
    XCTAssertEqual(fields["nudgeRetryInterval"]?.default, "120")
    XCTAssertEqual(fields["nudgeRetryInterval"]?.kind, .duration)
  }

  func test_defaultBehaviorIsAggressiveForNudgeAndCautiousForDecision() {
    let rule = StuckAgentRule()

    XCTAssertEqual(
      rule.defaultBehavior(for: "nudge:stuck-agent:agent-1:snap-1"),
      .aggressive
    )
    XCTAssertEqual(
      rule.defaultBehavior(for: "decision:stuck-agent:session-1:agent-1:task-1"),
      .cautious
    )
  }

  func test_noActionWhenIdleSecondsDoNotExceedThreshold() async {
    let rule = StuckAgentRule()
    let snapshot = Fixtures.snapshot(
      sessions: [
        Fixtures.session(
          id: "session-1",
          agents: [
            Fixtures.agent(
              id: "agent-1",
              statusRaw: "active",
              idleSeconds: 120,
              currentTaskID: "task-1"
            )
          ],
          tasks: [Fixtures.task(id: "task-1", statusRaw: "in_progress", createdAt: .fixed)]
        )
      ]
    )

    let actions = await rule.evaluate(snapshot: snapshot, context: context())

    XCTAssertTrue(actions.isEmpty)
  }

  func test_emitsNudgeWhenAgentIsStuckWithInProgressTask() async {
    let rule = StuckAgentRule()
    let snapshot = Fixtures.snapshot(
      id: "snap-1",
      hash: "hash-1",
      sessions: [
        Fixtures.session(
          id: "session-1",
          agents: [
            Fixtures.agent(
              id: "agent-1",
              statusRaw: "active",
              idleSeconds: 300,
              currentTaskID: "task-1"
            )
          ],
          tasks: [Fixtures.task(id: "task-1", statusRaw: "in_progress", createdAt: .fixed)]
        )
      ]
    )

    let actions = await rule.evaluate(snapshot: snapshot, context: context())

    XCTAssertEqual(actions.count, 1)
    guard case .nudgeAgent(let payload) = actions.first else {
      XCTFail("Expected nudge action, got \(String(describing: actions.first))")
      return
    }
    XCTAssertEqual(payload.agentID, "agent-1")
    XCTAssertEqual(payload.ruleID, "stuck-agent")
    XCTAssertEqual(payload.snapshotID, "snap-1")
    XCTAssertEqual(payload.snapshotHash, "hash-1")
    XCTAssertTrue(payload.prompt.contains("task-1"))
  }

  func test_respectsRetryIntervalFromHistory() async {
    let rule = StuckAgentRule()
    let now = Date.fixed
    let snapshot = stuckSnapshot(idleSeconds: 300)
    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: context(
        now: now,
        history: [
          event(
            actionKey: "nudge:stuck-agent:agent-1:hash-old",
            kind: "actionDispatched",
            createdAt: now.addingTimeInterval(-30)
          )
        ]
      )
    )

    XCTAssertTrue(actions.isEmpty)
  }

  func test_escalatesToDecisionAfterMaxRetries() async throws {
    let rule = StuckAgentRule()
    let now = Date.fixed
    let snapshot = stuckSnapshot(idleSeconds: 300)
    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: context(
        now: now,
        history: [
          event(
            actionKey: "nudge:stuck-agent:agent-1:hash-1",
            kind: "actionDispatched",
            createdAt: now.addingTimeInterval(-500)
          ),
          event(
            actionKey: "nudge:stuck-agent:agent-1:hash-2",
            kind: "actionDispatched",
            createdAt: now.addingTimeInterval(-300)
          ),
          event(
            actionKey: "nudge:stuck-agent:agent-1:hash-3",
            kind: "actionDispatched",
            createdAt: now.addingTimeInterval(-150)
          ),
        ]
      )
    )

    XCTAssertEqual(actions.count, 1)
    guard case .queueDecision(let payload) = actions.first else {
      XCTFail("Expected decision action, got \(String(describing: actions.first))")
      return
    }
    XCTAssertEqual(payload.ruleID, "stuck-agent")
    XCTAssertEqual(payload.sessionID, "session-1")
    XCTAssertEqual(payload.agentID, "agent-1")
    XCTAssertEqual(payload.taskID, "task-1")
    XCTAssertEqual(payload.severity, .needsUser)

    let suggestions = try JSONDecoder().decode(
      [SuggestedAction].self,
      from: Data(payload.suggestedActionsJSON.utf8)
    )
    XCTAssertEqual(suggestions.last?.kind, .dismiss)
  }

  func test_parameterOverridesCanForceImmediateEscalation() async {
    let rule = StuckAgentRule()
    let now = Date.fixed
    let snapshot = stuckSnapshot(idleSeconds: 45)
    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: context(
        now: now,
        parameters: [
          "stuckThreshold": "30",
          "nudgeMaxRetries": "1",
          "nudgeRetryInterval": "10",
        ],
        history: [
          event(
            actionKey: "nudge:stuck-agent:agent-1:hash-1",
            kind: "actionDispatched",
            createdAt: now.addingTimeInterval(-100)
          )
        ]
      )
    )

    XCTAssertEqual(actions.count, 1)
    guard case .queueDecision = actions.first else {
      XCTFail("Expected escalation decision")
      return
    }
  }

  func test_recentActionKeySkipsDuplicateNudge() async {
    let rule = StuckAgentRule()
    let snapshot = stuckSnapshot(idleSeconds: 300)
    let actionKey = "nudge:stuck-agent:agent-1:hash-1"
    let actions = await rule.evaluate(
      snapshot: snapshot,
      context: context(recentActionKeys: [actionKey])
    )

    XCTAssertTrue(actions.isEmpty)
  }

  private func stuckSnapshot(idleSeconds: Int?) -> SessionsSnapshot {
    Fixtures.snapshot(
      id: "snap-1",
      hash: "hash-1",
      sessions: [
        Fixtures.session(
          id: "session-1",
          agents: [
            Fixtures.agent(
              id: "agent-1",
              statusRaw: "active",
              idleSeconds: idleSeconds,
              currentTaskID: "task-1"
            )
          ],
          tasks: [Fixtures.task(id: "task-1", statusRaw: "in_progress", createdAt: .fixed)]
        )
      ]
    )
  }

  private func context(
    now: Date = .fixed,
    recentActionKeys: Set<String> = [],
    parameters: [String: String] = [:],
    history: [SupervisorEventSummary] = []
  ) -> PolicyContext {
    PolicyContext(
      now: now,
      lastFiredAt: nil,
      recentActionKeys: recentActionKeys,
      parameters: PolicyParameterValues(raw: parameters),
      history: PolicyHistoryWindow(recentEvents: history, recentDecisions: [])
    )
  }

  private func event(
    actionKey: String,
    kind: String,
    createdAt: Date
  ) -> SupervisorEventSummary {
    SupervisorEventSummary(
      id: actionKey,
      kind: kind,
      ruleID: "stuck-agent",
      createdAt: createdAt
    )
  }
}
