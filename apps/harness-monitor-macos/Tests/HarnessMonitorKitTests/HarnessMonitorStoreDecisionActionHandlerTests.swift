import XCTest

@testable import HarnessMonitorKit

@MainActor
final class HarnessMonitorStoreDecisionActionHandlerTests: XCTestCase {
  func test_assignTaskSuggestedActionFailsClosedWhenPayloadMalformed() async throws {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }
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
    XCTAssertFalse((store.currentFailureFeedbackMessage ?? "").isEmpty)
  }

  func test_nudgeSuggestedActionResolvesOnlyAfterDaemonActionSuccess() async throws {
    let client = RecordingHarnessClient()
    client.recordAgentTui(client.agentTuiFixture(tuiID: "agent-1"))
    client.agentTuiInputErrorsByID["agent-1"] = HarnessMonitorAPIError.server(
      code: 500,
      message: "rejected"
    )
    let store = await selectedActionStore(client: client)
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }
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
    XCTAssertTrue(
      client.recordedCalls().contains { call in
        guard case .sendAgentTuiInput(let tuiID, _) = call else { return false }
        return tuiID == "agent-1"
      }
    )
  }

  func test_nudgeSuggestedActionRoutesAcpAgentsThroughSignals() async throws {
    let client = RecordingHarnessClient()
    let sessionID = PreviewFixtures.summary.sessionId
    let snapshot = makeAcpSnapshot(
      acpID: "acp-1",
      sessionID: sessionID,
      agentID: "agent-acp",
      displayName: "Gemini",
      pendingBatches: []
    )
    client.configureResolvedAcpSnapshot(snapshot, for: "acp-1")
    let store = await selectedActionStore(client: client)
    store.applyAcpAgent(snapshot)
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }
    let decisionID = "decision-nudge-acp"
    try await store.insertDecisionForTesting(
      DecisionDraft.fixture(
        id: decisionID,
        severity: .needsUser,
        ruleID: "stuck-agent",
        sessionID: sessionID,
        agentID: "agent-acp",
        contextJSON: #"{"agentID":"agent-acp","managedAgentID":"acp-1"}"#,
        suggestedActionsJSON: encodedActions([
          SuggestedAction(
            id: "nudge",
            title: "Nudge",
            kind: .nudge,
            payloadJSON: #"{"agentID":"agent-acp","managedAgentID":"acp-1","input":"check in"}"#
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
    XCTAssertEqual(decision.statusRaw, "resolved")
    XCTAssertTrue(
      client.recordedCalls().contains(
        .sendSignal(
          sessionID: sessionID,
          agentID: "agent-acp",
          command: "request_action",
          actor: "harness-supervisor"
        )
      )
    )
    XCTAssertFalse(
      client.recordedCalls().contains { call in
        guard case .sendAgentTuiInput(let tuiID, _) = call else { return false }
        return tuiID == "agent-acp"
      }
    )
  }

  func test_storeSupervisorApiRoutesAcpNudgesThroughSignals() async throws {
    let client = RecordingHarnessClient()
    let sessionID = PreviewFixtures.summary.sessionId
    let snapshot = makeAcpSnapshot(
      acpID: "acp-1",
      sessionID: sessionID,
      agentID: "agent-acp",
      displayName: "Gemini",
      pendingBatches: []
    )
    client.configureResolvedAcpSnapshot(snapshot, for: "acp-1")
    let store = await selectedActionStore(client: client)
    store.applyAcpAgent(snapshot)
    let api = StoreAPIClient(store: store)

    try await api.nudgeAgent(agentID: "agent-acp", input: "check in")

    XCTAssertTrue(
      client.recordedCalls().contains(
        .sendSignal(
          sessionID: sessionID,
          agentID: "agent-acp",
          command: "request_action",
          actor: "harness-supervisor"
        )
      )
    )
    XCTAssertFalse(
      client.recordedCalls().contains { call in
        guard case .sendAgentTuiInput(let tuiID, _) = call else { return false }
        return tuiID == "agent-acp"
      }
    )
  }

  func test_nudgeSuggestedActionRejectsMismatchedAcpTargetPair() async throws {
    let client = RecordingHarnessClient()
    let sessionID = PreviewFixtures.summary.sessionId
    let snapshot = makeAcpSnapshot(
      acpID: "acp-1",
      sessionID: sessionID,
      agentID: "agent-acp",
      displayName: "Gemini",
      pendingBatches: []
    )
    client.configureResolvedAcpSnapshot(snapshot, for: "acp-1")
    let store = await selectedActionStore(client: client)
    store.applyAcpAgent(snapshot)
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }
    let decisionID = "decision-nudge-acp-mismatch"
    try await store.insertDecisionForTesting(
      DecisionDraft.fixture(
        id: decisionID,
        severity: .needsUser,
        ruleID: "stuck-agent",
        sessionID: sessionID,
        agentID: "other-agent",
        contextJSON: #"{"agentID":"other-agent","managedAgentID":"acp-1"}"#,
        suggestedActionsJSON: encodedActions([
          SuggestedAction(
            id: "nudge",
            title: "Nudge",
            kind: .nudge,
            payloadJSON: #"{"agentID":"other-agent","managedAgentID":"acp-1","input":"check in"}"#
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
    XCTAssertFalse((store.currentFailureFeedbackMessage ?? "").isEmpty)
    XCTAssertFalse(
      client.recordedCalls().contains { call in
        switch call {
        case .sendSignal(_, _, _, _), .sendAgentTuiInput(_, _):
          true
        default:
          false
        }
      }
    )
  }

  func test_nudgeSuggestedActionRejectsManagedOnlyTargetWithoutSessionAgentLink() async throws {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }
    let decisionID = "decision-nudge-managed-only"
    try await store.insertDecisionForTesting(
      DecisionDraft.fixture(
        id: decisionID,
        severity: .needsUser,
        ruleID: "stuck-agent",
        sessionID: PreviewFixtures.summary.sessionId,
        contextJSON: #"{"managedAgentID":"acp-missing"}"#,
        suggestedActionsJSON: encodedActions([
          SuggestedAction(
            id: "nudge",
            title: "Nudge",
            kind: .nudge,
            payloadJSON: #"{"managedAgentID":"acp-missing","input":"check in"}"#
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
    XCTAssertFalse((store.currentFailureFeedbackMessage ?? "").isEmpty)
    XCTAssertFalse(
      client.recordedCalls().contains { call in
        switch call {
        case .sendSignal(_, _, _, _), .sendAgentTuiInput(_, _):
          true
        default:
          false
        }
      }
    )
  }

  private func encodedActions(_ actions: [SuggestedAction]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(actions)) ?? Data("[]".utf8)
    return String(data: data, encoding: .utf8) ?? "[]"
  }
}
