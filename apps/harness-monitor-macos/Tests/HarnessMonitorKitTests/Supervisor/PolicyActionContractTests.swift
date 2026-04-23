import XCTest

@testable import HarnessMonitorKit

final class PolicyActionContractTests: XCTestCase {
  func test_actionKeyContractIsStableForEveryCase() {
    XCTAssertEqual(
      makeActions().map(\.actionKey),
      [
        "nudge:rule-1:agent-1:snapshot-hash",
        "assign:rule-1:task-1:snapshot-hash",
        "drop:rule-1:task-2:snapshot-hash",
        "decision:rule-1:decision-1",
        "notify:rule-1:snapshot-hash",
        "log:rule-1:log-1",
        "suggest:suggestion-1",
      ]
    )
  }

  func test_policyActionCodableRoundTripsEveryCase() throws {
    let actions = makeActions()
    let data = try JSONEncoder().encode(actions)
    let decoded = try JSONDecoder().decode([PolicyAction].self, from: data)
    XCTAssertEqual(decoded, actions)
  }

  private func makeActions() -> [PolicyAction] {
    [
      .nudgeAgent(
        .init(
          agentID: "agent-1",
          prompt: "wake up",
          ruleID: "rule-1",
          snapshotID: "snapshot-1",
          snapshotHash: "snapshot-hash"
        )
      ),
      .assignTask(
        .init(
          taskID: "task-1",
          agentID: "agent-1",
          ruleID: "rule-1",
          snapshotID: "snapshot-1",
          snapshotHash: "snapshot-hash"
        )
      ),
      .dropTask(
        .init(
          taskID: "task-2",
          reason: "stale",
          ruleID: "rule-1",
          snapshotID: "snapshot-1",
          snapshotHash: "snapshot-hash"
        )
      ),
      .queueDecision(
        .init(
          id: "decision-1",
          severity: .warn,
          ruleID: "rule-1",
          sessionID: "session-1",
          agentID: "agent-1",
          taskID: "task-1",
          summary: "Need attention",
          contextJSON: "{}",
          suggestedActionsJSON: "[]"
        )
      ),
      .notifyOnly(
        .init(
          ruleID: "rule-1",
          snapshotID: "snapshot-1",
          snapshotHash: "snapshot-hash",
          severity: .warn,
          summary: "daemon down"
        )
      ),
      .logEvent(
        .init(
          id: "log-1",
          ruleID: "rule-1",
          snapshotID: "snapshot-1",
          message: "observed"
        )
      ),
      .suggestConfigChange(
        .init(
          id: "suggestion-1",
          ruleID: "rule-1",
          proposalJSON: "{}",
          rationale: "needs config"
        )
      ),
    ]
  }
}
