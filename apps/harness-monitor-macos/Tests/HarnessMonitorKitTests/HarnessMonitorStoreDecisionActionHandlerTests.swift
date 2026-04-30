import XCTest

@testable import HarnessMonitorKit

@MainActor
final class HarnessMonitorStoreDecisionActionHandlerTests: XCTestCase {
  func test_assignTaskSuggestedActionFailsClosedWhenPayloadMalformed() async throws {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)
    await store.startSupervisor()
    let decisionID = "decision-assign-malformed"
    try await store.insertDecisionForTesting(
      DecisionDraft.fixture(
        id: decisionID,
        severity: .needsUser,
        ruleID: "unassigned-task",
        sessionID: PreviewFixtures.summary.sessionId,
        taskID: "task-1",
        suggestedActionsJSON: encodedActions([
          SuggestedAction(
            id: "assign",
            title: "Assign",
            kind: .assignTask,
            payloadJSON: #"{"agentID":"agent-1"}"#
          )
        ])
      )
    )

    let handler = store.supervisorDecisionActionHandler()
    await handler.resolve(
      decisionID: decisionID,
      outcome: DecisionOutcome(chosenActionID: "assign", note: nil)
    )

    let decisionStore = try XCTUnwrap(store.supervisorDecisionStore)
    let fetchedDecision = try await decisionStore.decision(id: decisionID)
    let decision = try XCTUnwrap(fetchedDecision)
    XCTAssertEqual(decision.statusRaw, "open")
    XCTAssertEqual(client.recordedCalls().count, 0)
    XCTAssertTrue((store.currentFailureFeedbackMessage ?? "").contains("missing target metadata"))
  }

  func test_nudgeSuggestedActionResolvesOnlyAfterDaemonActionSuccess() async throws {
    let client = RecordingHarnessClient()
    client.agentTuiInputErrorsByID["agent-1"] = HarnessMonitorAPIError.server(
      code: 500,
      message: "rejected"
    )
    let store = await selectedActionStore(client: client)
    await store.startSupervisor()
    let decisionID = "decision-nudge-rejected"
    try await store.insertDecisionForTesting(
      DecisionDraft.fixture(
        id: decisionID,
        severity: .needsUser,
        ruleID: "stuck-agent",
        sessionID: PreviewFixtures.summary.sessionId,
        agentID: "agent-1",
        contextJSON: #"{"agentID":"agent-1"}"#,
        suggestedActionsJSON: encodedActions([
          SuggestedAction(
            id: "nudge",
            title: "Nudge",
            kind: .nudge,
            payloadJSON: #"{"agentID":"agent-1","input":"check in"}"#
          )
        ])
      )
    )

    let handler = store.supervisorDecisionActionHandler()
    await handler.resolve(
      decisionID: decisionID,
      outcome: DecisionOutcome(chosenActionID: "nudge", note: nil)
    )

    let decisionStore = try XCTUnwrap(store.supervisorDecisionStore)
    let fetchedDecision = try await decisionStore.decision(id: decisionID)
    let decision = try XCTUnwrap(fetchedDecision)
    XCTAssertEqual(decision.statusRaw, "open")
    XCTAssertTrue((store.currentFailureFeedbackMessage ?? "").contains("daemon"))
  }

  private func encodedActions(_ actions: [SuggestedAction]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(actions)) ?? Data("[]".utf8)
    return String(data: data, encoding: .utf8) ?? "[]"
  }
}
