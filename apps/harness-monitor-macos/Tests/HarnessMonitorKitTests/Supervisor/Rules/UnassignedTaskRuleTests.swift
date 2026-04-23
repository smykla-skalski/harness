import Foundation
import XCTest

@testable import HarnessMonitorKit

final class UnassignedTaskRuleTests: XCTestCase {
  // MARK: - Defaults and metadata

  func test_metadataIsStable() {
    let rule = UnassignedTaskRule()
    XCTAssertEqual(rule.id, "unassigned-task")
    XCTAssertEqual(rule.name, "Unassigned Task")
    XCTAssertEqual(rule.version, 1)
  }

  func test_parameterSchemaDeclaresUnassignedThreshold() {
    let rule = UnassignedTaskRule()
    let keys = rule.parameters.fields.map(\.key)
    XCTAssertTrue(
      keys.contains("unassignedThreshold"),
      "UnassignedTaskRule must expose `unassignedThreshold` parameter; found \(keys)"
    )
    let field = rule.parameters.fields.first { $0.key == "unassignedThreshold" }
    XCTAssertEqual(field?.default, "120")
    XCTAssertEqual(field?.kind, .duration)
  }

  func test_defaultBehaviorIsCautious() {
    let rule = UnassignedTaskRule()
    XCTAssertEqual(rule.defaultBehavior(for: "queueDecision"), .cautious)
  }

  // MARK: - Trigger boundary

  func test_noActionWhenTaskIsYoungerThanThreshold() async {
    let rule = UnassignedTaskRule()
    let now = Date.fixed
    let snapshot = Fixtures.snapshot(
      sessions: [
        Fixtures.session(
          id: "s1",
          agents: [Fixtures.agent(id: "agent-1", statusRaw: "active")],
          tasks: [
            Fixtures.task(id: "t1", statusRaw: "open", createdAt: now.addingTimeInterval(-30))
          ]
        )
      ]
    )
    let actions = await rule.evaluate(snapshot: snapshot, context: context(now: now))
    XCTAssertTrue(
      actions.isEmpty,
      "Task below 120s threshold must not trigger; got \(actions)"
    )
  }

  func test_noActionAtExactThreshold() async {
    let rule = UnassignedTaskRule()
    let now = Date.fixed
    let snapshot = Fixtures.snapshot(
      sessions: [
        Fixtures.session(
          id: "s1",
          agents: [Fixtures.agent(id: "agent-1", statusRaw: "active")],
          tasks: [
            Fixtures.task(id: "t1", statusRaw: "open", createdAt: now.addingTimeInterval(-120))
          ]
        )
      ]
    )
    let actions = await rule.evaluate(snapshot: snapshot, context: context(now: now))
    XCTAssertTrue(
      actions.isEmpty,
      "Trigger is strictly `>` threshold; exact boundary must not fire"
    )
  }

  func test_triggersJustPastThreshold() async {
    let rule = UnassignedTaskRule()
    let now = Date.fixed
    let snapshot = Fixtures.snapshot(
      sessions: [
        Fixtures.session(
          id: "s1",
          agents: [Fixtures.agent(id: "agent-1", statusRaw: "active")],
          tasks: [
            Fixtures.task(id: "t1", statusRaw: "open", createdAt: now.addingTimeInterval(-121))
          ]
        )
      ]
    )
    let actions = await rule.evaluate(snapshot: snapshot, context: context(now: now))
    XCTAssertEqual(actions.count, 1)
    guard case .queueDecision(let payload) = actions.first else {
      XCTFail("Expected queueDecision, got \(String(describing: actions.first))")
      return
    }
    XCTAssertEqual(payload.ruleID, "unassigned-task")
    XCTAssertEqual(payload.severity, .needsUser)
    XCTAssertEqual(payload.sessionID, "s1")
    XCTAssertEqual(payload.taskID, "t1")
  }

  // MARK: - Assigned tasks and non-open statuses

  func test_noActionWhenTaskAssigned() async {
    let rule = UnassignedTaskRule()
    let now = Date.fixed
    let snapshot = Fixtures.snapshot(
      sessions: [
        Fixtures.session(
          id: "s1",
          agents: [Fixtures.agent(id: "agent-1", statusRaw: "active")],
          tasks: [
            Fixtures.task(
              id: "t1",
              statusRaw: "open",
              assignedAgentID: "agent-1",
              createdAt: now.addingTimeInterval(-600)
            )
          ]
        )
      ]
    )
    let actions = await rule.evaluate(snapshot: snapshot, context: context(now: now))
    XCTAssertTrue(actions.isEmpty, "Assigned tasks must not be flagged as unassigned")
  }

  func test_noActionWhenTaskNotOpen() async {
    let rule = UnassignedTaskRule()
    let now = Date.fixed
    let snapshot = Fixtures.snapshot(
      sessions: [
        Fixtures.session(
          id: "s1",
          agents: [Fixtures.agent(id: "agent-1", statusRaw: "active")],
          tasks: [
            Fixtures.task(
              id: "t1",
              statusRaw: "in_progress",
              createdAt: now.addingTimeInterval(-600)
            )
          ]
        )
      ]
    )
    let actions = await rule.evaluate(snapshot: snapshot, context: context(now: now))
    XCTAssertTrue(actions.isEmpty, "Non-open tasks must not trigger the rule")
  }

  // MARK: - Suggested actions

  func test_suggestedActionsListEveryActiveAgent() async throws {
    let rule = UnassignedTaskRule()
    let now = Date.fixed
    let snapshot = Fixtures.snapshot(
      sessions: [
        Fixtures.session(
          id: "s1",
          agents: [
            Fixtures.agent(id: "agent-1", statusRaw: "active"),
            Fixtures.agent(id: "agent-2", statusRaw: "idle"),
            Fixtures.agent(id: "agent-3", statusRaw: "active"),
          ],
          tasks: [
            Fixtures.task(id: "t1", statusRaw: "open", createdAt: now.addingTimeInterval(-600))
          ]
        )
      ]
    )
    let actions = await rule.evaluate(snapshot: snapshot, context: context(now: now))
    XCTAssertEqual(actions.count, 1)
    guard case .queueDecision(let payload) = actions.first else {
      XCTFail("Expected queueDecision, got \(String(describing: actions.first))")
      return
    }
    let decoder = JSONDecoder()
    let suggestions = try decoder.decode(
      [SuggestedAction].self,
      from: Data(payload.suggestedActionsJSON.utf8)
    )
    XCTAssertEqual(
      suggestions.count,
      2,
      "Only active agents should be offered; got \(suggestions)"
    )
    XCTAssertEqual(suggestions.map(\.title), ["Assign to agent-1", "Assign to agent-3"])
    XCTAssertEqual(Set(suggestions.map(\.kind)), [.assignTask])
  }

  // MARK: - No active agents

  func test_noActionWhenNoActiveAgents() async {
    let rule = UnassignedTaskRule()
    let now = Date.fixed
    let snapshot = Fixtures.snapshot(
      sessions: [
        Fixtures.session(
          id: "s1",
          agents: [
            Fixtures.agent(id: "agent-1", statusRaw: "idle"),
            Fixtures.agent(id: "agent-2", statusRaw: "stopped"),
          ],
          tasks: [
            Fixtures.task(id: "t1", statusRaw: "open", createdAt: now.addingTimeInterval(-600))
          ]
        )
      ]
    )
    let actions = await rule.evaluate(snapshot: snapshot, context: context(now: now))
    XCTAssertTrue(
      actions.isEmpty,
      "With no active agents there is nobody to assign to, so the rule stays silent"
    )
  }

  // MARK: - Parameter override

  func test_customThresholdOverridesDefault() async {
    let rule = UnassignedTaskRule()
    let now = Date.fixed
    let snapshot = Fixtures.snapshot(
      sessions: [
        Fixtures.session(
          id: "s1",
          agents: [Fixtures.agent(id: "agent-1", statusRaw: "active")],
          tasks: [
            Fixtures.task(id: "t1", statusRaw: "open", createdAt: now.addingTimeInterval(-45))
          ]
        )
      ]
    )
    let overridden = PolicyContext(
      now: now,
      lastFiredAt: nil,
      recentActionKeys: [],
      parameters: PolicyParameterValues(raw: ["unassignedThreshold": "30"]),
      history: PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
    )
    let actions = await rule.evaluate(snapshot: snapshot, context: overridden)
    XCTAssertEqual(actions.count, 1, "30s threshold must trigger at 45s age")
  }

  // MARK: - Idempotency

  func test_recentActionKeyIsSkipped() async {
    let rule = UnassignedTaskRule()
    let now = Date.fixed
    let snapshot = Fixtures.snapshot(
      sessions: [
        Fixtures.session(
          id: "s1",
          agents: [Fixtures.agent(id: "agent-1", statusRaw: "active")],
          tasks: [
            Fixtures.task(id: "t1", statusRaw: "open", createdAt: now.addingTimeInterval(-600))
          ]
        )
      ]
    )
    // Evaluate once to learn the action key.
    let first = await rule.evaluate(snapshot: snapshot, context: context(now: now))
    XCTAssertEqual(first.count, 1)
    let actionKey = first.first?.actionKey ?? ""
    let replay = PolicyContext(
      now: now,
      lastFiredAt: nil,
      recentActionKeys: [actionKey],
      parameters: PolicyParameterValues(raw: [:]),
      history: PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
    )
    let second = await rule.evaluate(snapshot: snapshot, context: replay)
    XCTAssertTrue(second.isEmpty, "Once queued, the same decision must not fire again")
  }

  // MARK: - Helpers

  private func context(now: Date) -> PolicyContext {
    PolicyContext(
      now: now,
      lastFiredAt: nil,
      recentActionKeys: [],
      parameters: PolicyParameterValues(raw: [:]),
      history: PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
    )
  }
}
