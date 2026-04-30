import SwiftData
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

    let store = try await selectedActionStoreWithPersistence(client: client)
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

  func test_timeoutRemovalAutoResolvesDecisionOnceAndWritesAuditEntry() async throws {
    let client = RecordingHarnessClient()
    let sessionID = PreviewFixtures.summary.sessionId
    let batch = AcpPermissionBatch(
      batchId: "batch-deadline-timeout",
      acpId: "acp-1",
      sessionId: sessionID,
      requests: [
        AcpPermissionItem(
          requestId: "request-timeout",
          sessionId: sessionID,
          toolCall: .object([
            "kind": .string("write"),
            "path": .string("README.md"),
          ]),
          options: [.string("allow"), .string("deny")]
        )
      ],
      createdAt: "2026-04-28T00:00:01Z",
      expiresAt: "2026-04-28T00:05:00Z"
    )

    let store = try await selectedActionStoreWithPersistence(client: client)
    store.applyAcpAgent(
      makeAcpSnapshot(
        acpID: "acp-1",
        sessionID: sessionID,
        pendingBatches: [batch]
      )
    )

    let decisionID = AcpPermissionDecisionPayload.decisionID(for: batch.batchId)
    let payload = try XCTUnwrap(store.acpPermissionDecisionPayload(for: decisionID))
    try await store.insertDecisionForTesting(payload.decisionDraft)
    await settleObservation()

    store.removeAcpPermissionBatch(batch, reason: .timeout)
    store.removeAcpPermissionBatch(batch, reason: .timeout)

    await waitUntil {
      store.pendingAcpPermissionBatches.isEmpty
    } failureMessage: {
      "timed-out ACP batch stayed pending: \(store.pendingAcpPermissionBatches.map(\.batchId))"
    }
    await waitUntil {
      !store.acpPermissionPendingTimeoutDecisionIDs.contains(decisionID)
    } failureMessage: {
      let pendingIDs = store.acpPermissionPendingTimeoutDecisionIDs
      let payloadPresent = store.acpPermissionDecisionPayload(for: decisionID) != nil
      return """
        deadline auto-resolution stayed pending for \(decisionID); pending=\(pendingIDs); \
        payloadPresent=\(payloadPresent); \
        failure=\(store.currentFailureFeedbackMessage ?? "none")
        """
    }

    let decisionStore = try XCTUnwrap(store.supervisorDecisionStore)
    let resolvedDecision = try await waitForDecision(
      id: decisionID,
      in: decisionStore
    ) { decision in
      decision.statusRaw == "resolved"
    }
    XCTAssertEqual(resolvedDecision.statusRaw, "resolved")
    XCTAssertEqual(
      decodeOutcome(resolvedDecision.resolutionJSON),
      DecisionOutcome(
        chosenActionID: nil,
        note: "client_deadline_exceeded"
      )
    )
    let container = try XCTUnwrap(store.modelContext?.container)
    let timeoutEvent = try await waitForSupervisorEvent(in: container) { event in
      event.kind == "acp_permission_deadline_expired"
        && event.ruleID == AcpPermissionDecisionPayload.ruleID
        && event.payloadJSON.contains(#""decisionID":"acp-permission:batch-deadline-timeout""#)
        && event.payloadJSON.contains(#""reason":"client_deadline_exceeded""#)
    }
    XCTAssertEqual(timeoutEvent.kind, "acp_permission_deadline_expired")

    let auditContext = ModelContext(container)
    let timeoutEvents = try auditContext.fetch(FetchDescriptor<SupervisorEvent>())
      .filter { event in
        event.kind == "acp_permission_deadline_expired"
          && event.payloadJSON.contains(#""decisionID":"acp-permission:batch-deadline-timeout""#)
      }
    XCTAssertEqual(timeoutEvents.count, 1)
  }

  func test_timeoutResolutionPreventsStaleBatchReopen() async throws {
    let client = RecordingHarnessClient()
    let sessionID = PreviewFixtures.summary.sessionId
    let batch = AcpPermissionBatch(
      batchId: "batch-timeout-no-reopen",
      acpId: "acp-1",
      sessionId: sessionID,
      requests: [
        AcpPermissionItem(
          requestId: "request-timeout",
          sessionId: sessionID,
          toolCall: .object(["kind": .string("write"), "path": .string("README.md")]),
          options: [.string("allow"), .string("deny")]
        )
      ],
      createdAt: "2026-04-28T00:00:01Z",
      expiresAt: "2026-04-28T00:05:00Z"
    )
    let store = try await selectedActionStoreWithPersistence(client: client)
    store.applyAcpAgent(
      makeAcpSnapshot(acpID: "acp-1", sessionID: sessionID, pendingBatches: [batch])
    )
    let decisionID = AcpPermissionDecisionPayload.decisionID(for: batch.batchId)
    let payload = try XCTUnwrap(store.acpPermissionDecisionPayload(for: decisionID))
    try await store.insertDecisionForTesting(payload.decisionDraft)
    await settleObservation()
    store.removeAcpPermissionBatch(batch, reason: .timeout)
    let decisionStore = try XCTUnwrap(store.supervisorDecisionStore)
    _ = try await waitForDecision(
      id: decisionID,
      in: decisionStore
    ) { decision in
      decision.statusRaw == "resolved"
    }

    store.applyAcpPermissionBatch(batch)

    XCTAssertTrue(store.pendingAcpPermissionBatches.isEmpty)
  }

  func test_shutdownRemovalResolvesCancelledDecisionWithAuditAnnotation() async throws {
    let client = RecordingHarnessClient()
    let sessionID = PreviewFixtures.summary.sessionId
    let batch = AcpPermissionBatch(
      batchId: "batch-daemon-shutdown",
      acpId: "acp-1",
      sessionId: sessionID,
      requests: [
        AcpPermissionItem(
          requestId: "request-1",
          sessionId: sessionID,
          toolCall: .object(["kind": .string("write"), "path": .string("README.md")]),
          options: [.string("allow"), .string("deny")]
        )
      ],
      createdAt: "2026-04-28T00:00:01Z"
    )
    let store = try await selectedActionStoreWithPersistence(client: client)
    store.applyAcpAgent(
      makeAcpSnapshot(acpID: "acp-1", sessionID: sessionID, pendingBatches: [batch])
    )
    let decisionID = AcpPermissionDecisionPayload.decisionID(for: batch.batchId)
    let payload = try XCTUnwrap(store.acpPermissionDecisionPayload(for: decisionID))
    try await store.insertDecisionForTesting(payload.decisionDraft)
    await settleObservation()

    store.removeAcpPermissionBatch(batch, reason: .shutdown)

    let decisionStore = try XCTUnwrap(store.supervisorDecisionStore)
    let resolvedDecision = try await waitForDecision(
      id: decisionID,
      in: decisionStore
    ) { decision in
      decision.statusRaw == "resolved"
    }
    XCTAssertEqual(
      decodeOutcome(resolvedDecision.resolutionJSON),
      DecisionOutcome(chosenActionID: nil, note: "daemon_shutdown")
    )

    let container = try XCTUnwrap(store.modelContext?.container)
    let shutdownEvent = try await waitForSupervisorEvent(in: container) { event in
      event.kind == "acp_permission_daemon_shutdown"
        && event.payloadJSON.contains(#""reason":"daemon_shutdown""#)
        && event.payloadJSON.contains(#""uiAnnotation":"removed_after_daemon_shutdown""#)
    }
    XCTAssertEqual(shutdownEvent.kind, "acp_permission_daemon_shutdown")
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

  private func waitForDecision(
    id: String,
    in decisionStore: DecisionStore,
    timeout: Duration = .seconds(3),
    poll: Duration = .milliseconds(50),
    predicate: @escaping (Decision) -> Bool
  ) async throws -> Decision {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if let decision = try await decisionStore.decision(id: id), predicate(decision) {
        return decision
      }
      try? await Task.sleep(for: poll)
    }

    guard let decision = try await decisionStore.decision(id: id) else {
      XCTFail("Timed out waiting for decision \(id)")
      throw CancellationError()
    }
    XCTAssertTrue(predicate(decision), "Timed out waiting for decision \(id)")
    return decision
  }

  private func waitForSupervisorEvent(
    in container: ModelContainer,
    timeout: Duration = .seconds(3),
    poll: Duration = .milliseconds(50),
    predicate: @escaping (SupervisorEvent) -> Bool
  ) async throws -> SupervisorEvent {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      let context = ModelContext(container)
      let events = try context.fetch(FetchDescriptor<SupervisorEvent>())
      if let match = events.first(where: predicate) {
        return match
      }
      try? await Task.sleep(for: poll)
    }

    let context = ModelContext(container)
    let events = try context.fetch(FetchDescriptor<SupervisorEvent>())
    let match = try XCTUnwrap(events.first(where: predicate))
    return match
  }

  private func decodeOutcome(_ json: String?) -> DecisionOutcome? {
    guard let json else {
      return nil
    }
    return try? JSONDecoder().decode(DecisionOutcome.self, from: Data(json.utf8))
  }

  private func selectedActionStoreWithPersistence(
    client: RecordingHarnessClient
  ) async throws -> HarnessMonitorStore {
    let container = try ModelContainer(
      for: SupervisorEvent.self,
      Decision.self,
      PolicyConfigRow.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let daemon = RecordingDaemonController(client: client)
    let store = HarnessMonitorStore(
      daemonController: daemon,
      modelContainer: container
    )
    await store.bootstrap()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.stopAllStreams(resetSubscriptions: false)
    return store
  }
}
