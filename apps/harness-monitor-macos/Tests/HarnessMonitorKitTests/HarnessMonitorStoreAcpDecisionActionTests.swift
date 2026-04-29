import XCTest

@testable import HarnessMonitorKit

@MainActor
final class HarnessMonitorStoreAcpDecisionActionTests: XCTestCase {
  func test_supervisorAcpDecisionResolutionUsesSharedSelectionStateAndClosesDecision()
    async throws
  {
    let client = RecordingHarnessClient()
    let sessionID = PreviewFixtures.summary.sessionId
    let batch = AcpPermissionBatch(
      batchId: "batch-shared-selection",
      acpId: "acp-1",
      sessionId: sessionID,
      requests: [
        AcpPermissionItem(
          requestId: "request-write",
          sessionId: sessionID,
          toolCall: .object([
            "kind": .string("write"),
            "path": .string("README.md"),
          ]),
          options: [.string("allow"), .string("deny")]
        ),
        AcpPermissionItem(
          requestId: "request-shell",
          sessionId: sessionID,
          toolCall: .object([
            "kind": .string("terminal.create"),
            "command": .string("pwd"),
          ]),
          options: [.string("allow"), .string("deny")]
        ),
      ],
      createdAt: "2026-04-28T00:00:01Z"
    )
    client.configureResolvedAcpSnapshot(
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: sessionID,
        pendingBatches: []
      ),
      for: "acp-1"
    )

    let store = await selectedActionStore(client: client)
    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: sessionID,
        pendingBatches: [batch]
      )
    )

    let decisionID = AcpPermissionDecisionPayload.decisionID(for: batch.batchId)
    try await store.insertDecisionForTesting(
      store.acpPermissionDecisionPayload(for: batch).decisionDraft
    )
    await settleObservation()

    store.acpPermissionResolutionStateByDecisionID[decisionID] = BatchResolutionState(
      batchID: batch.batchId,
      perItem: [
        .init(itemID: "request-write", toggleState: .selected),
        .init(itemID: "request-shell", toggleState: .unselected),
      ]
    )

    let handler = store.supervisorDecisionActionHandler()
    await handler.resolve(
      decisionID: decisionID,
      outcome: DecisionOutcome(
        chosenActionID: AcpPermissionDecisionActionID.approveSelected,
        note: nil
      )
    )

    await waitUntil {
      store.pendingAcpPermissionBatches.isEmpty
    } failureMessage: {
      """
      pending ACP batches stayed open: \(store.pendingAcpPermissionBatches.map(\.batchId)); \
      calls=\(client.recordedCalls()); failure=\(store.currentFailureFeedbackMessage ?? "none")
      """
    }

    XCTAssertTrue(
      client.recordedCalls().contains(
        .resolveAcpPermission(
          agentID: "acp-1",
          batchID: batch.batchId,
          decision: .approveSome(["request-write"])
        )
      ),
      "unexpected ACP resolution calls: \(client.recordedCalls())"
    )
  }

  private func settleObservation() async {
    await Task.yield()
    await Task.yield()
  }

  private func waitUntil(
    timeout: Duration = .seconds(3),
    poll: Duration = .milliseconds(50),
    condition: @escaping @MainActor () -> Bool,
    failureMessage: @escaping @MainActor () -> String
  ) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if condition() {
        return
      }
      try? await Task.sleep(for: poll)
    }
    XCTAssertTrue(condition(), failureMessage())
  }
}
