import SwiftData
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class HarnessMonitorStoreAcpDecisionLifecycleTests: XCTestCase {
  func test_invalidatingDecisionSyncCancelsQueuedSyncBeforeItPersistsDecision() async throws {
    let client = RecordingHarnessClient()
    let sessionID = PreviewFixtures.summary.sessionId
    let batch = AcpPermissionBatch(
      batchId: "batch-sync-cancel",
      acpId: "acp-1",
      sessionId: sessionID,
      requests: [
        AcpPermissionItem(
          requestId: "request-sync-cancel",
          sessionId: sessionID,
          toolCall: .object(["kind": .string("write"), "path": .string("README.md")]),
          options: [.string("allow"), .string("deny")]
        )
      ],
      createdAt: "2026-04-28T00:00:01Z"
    )
    let store = try await lifecycleStoreWithPersistence(client: client)
    let decisionID = AcpPermissionDecisionPayload.decisionID(for: batch.batchId)
    let decisionStore = try XCTUnwrap(store.supervisorDecisionStore)

    store.applyAcpAgent(
      makeAcpSnapshot(acpID: "acp-1", sessionID: sessionID, pendingBatches: [batch])
    )
    store.invalidateAcpPermissionDecisionSync()
    await settleObservation()
    try? await Task.sleep(for: .milliseconds(150))

    let persistedDecision = try await decisionStore.decision(id: decisionID)
    XCTAssertNil(persistedDecision)
    XCTAssertNil(store.acpPermissionDecisionSyncTask)
  }

  func test_stoppingSupervisorCancelsQueuedSyncBeforeItPersistsDecision() async throws {
    let client = RecordingHarnessClient()
    let sessionID = PreviewFixtures.summary.sessionId
    let batch = AcpPermissionBatch(
      batchId: "batch-sync-stop",
      acpId: "acp-1",
      sessionId: sessionID,
      requests: [
        AcpPermissionItem(
          requestId: "request-sync-stop",
          sessionId: sessionID,
          toolCall: .object(["kind": .string("write"), "path": .string("README.md")]),
          options: [.string("allow"), .string("deny")]
        )
      ],
      createdAt: "2026-04-28T00:00:01Z"
    )
    let store = try await lifecycleStoreWithPersistence(client: client)
    let decisionID = AcpPermissionDecisionPayload.decisionID(for: batch.batchId)
    let decisionStore = try XCTUnwrap(store.supervisorDecisionStore)

    store.applyAcpAgent(
      makeAcpSnapshot(acpID: "acp-1", sessionID: sessionID, pendingBatches: [batch])
    )
    await store.stopSupervisor()
    await settleObservation()
    try? await Task.sleep(for: .milliseconds(150))

    let persistedDecision = try await decisionStore.decision(id: decisionID)
    XCTAssertNil(persistedDecision)
    XCTAssertNil(store.supervisorDecisionStore)
    XCTAssertNil(store.acpPermissionDecisionSyncTask)
  }

  func test_startingSupervisorResyncsQueuedAcpDecisionsIntoFreshDecisionStore() async throws {
    let client = RecordingHarnessClient()
    let sessionID = PreviewFixtures.summary.sessionId
    let batch = AcpPermissionBatch(
      batchId: "batch-sync-start",
      acpId: "acp-1",
      sessionId: sessionID,
      requests: [
        AcpPermissionItem(
          requestId: "request-sync-start",
          sessionId: sessionID,
          toolCall: .object(["kind": .string("write"), "path": .string("README.md")]),
          options: [.string("allow"), .string("deny")]
        )
      ],
      createdAt: "2026-04-28T00:00:01Z"
    )
    let store = try await lifecycleStoreWithPersistence(client: client)
    await store.stopSupervisor()

    let decisionID = AcpPermissionDecisionPayload.decisionID(for: batch.batchId)
    store.applyAcpAgent(
      makeAcpSnapshot(acpID: "acp-1", sessionID: sessionID, pendingBatches: [batch])
    )
    XCTAssertNil(store.supervisorDecisionStore)

    await store.startSupervisor()
    await settleObservation()
    try? await Task.sleep(for: .milliseconds(150))

    let decisionStore = try XCTUnwrap(store.supervisorDecisionStore)
    let persistedDecision = try await decisionStore.decision(id: decisionID)
    XCTAssertEqual(persistedDecision?.id, decisionID)
  }

  func test_stoppingSupervisorPreventsPendingTimeoutResolutionMutation() async throws {
    try await assertPendingTerminalResolutionStopsWithoutMutatingDecisionStore(reason: .timeout)
  }

  func test_stoppingSupervisorPreventsPendingShutdownResolutionMutation() async throws {
    try await assertPendingTerminalResolutionStopsWithoutMutatingDecisionStore(reason: .shutdown)
  }

  private func settleObservation() async {
    await Task.yield()
    await Task.yield()
  }

  private func assertPendingTerminalResolutionStopsWithoutMutatingDecisionStore(
    reason: AcpPermissionBatchRemovalReason
  ) async throws {
    let client = RecordingHarnessClient()
    let sessionID = PreviewFixtures.summary.sessionId
    let batchID: String
    switch reason {
    case .timeout:
      batchID = "batch-timeout-supervisor-stop"
    case .shutdown:
      batchID = "batch-shutdown-supervisor-stop"
    case .resolved:
      XCTFail("resolved removals do not schedule terminal resolution tasks")
      return
    }
    let batch = AcpPermissionBatch(
      batchId: batchID,
      acpId: "acp-1",
      sessionId: sessionID,
      requests: [
        AcpPermissionItem(
          requestId: "request-\(batchID)",
          sessionId: sessionID,
          toolCall: .object(["kind": .string("write"), "path": .string("README.md")]),
          options: [.string("allow"), .string("deny")]
        )
      ],
      createdAt: "2026-04-28T00:00:01Z",
      expiresAt: reason == .timeout ? "2026-04-28T00:05:00Z" : nil
    )

    let store = try await lifecycleStoreWithPersistence(client: client)
    let decisionID = AcpPermissionDecisionPayload.decisionID(for: batch.batchId)
    store.applyAcpAgent(
      makeAcpSnapshot(acpID: "acp-1", sessionID: sessionID, pendingBatches: [batch])
    )
    let payload = try XCTUnwrap(store.acpPermissionDecisionPayload(for: decisionID))
    try await store.insertDecisionForTesting(payload.decisionDraft)
    await settleObservation()

    let decisionStore = try XCTUnwrap(store.supervisorDecisionStore)
    let container = try XCTUnwrap(store.modelContext?.container)
    store.removeAcpPermissionBatch(batch, reason: reason)
    await store.stopSupervisor()

    await settleObservation()
    try? await Task.sleep(for: .milliseconds(150))

    let decision = try await decisionStore.decision(id: decisionID)
    XCTAssertNotEqual(decision?.statusRaw, "resolved")
    XCTAssertNil(decision?.resolutionJSON)
    XCTAssertNil(store.supervisorDecisionStore)
    XCTAssertTrue(store.acpPermissionPendingTimeoutDecisionIDs.isEmpty)
    XCTAssertTrue(store.acpPermissionPendingShutdownDecisionIDs.isEmpty)
    XCTAssertTrue(store.acpPermissionDeadlineResolutionTasks.isEmpty)
    XCTAssertTrue(store.acpPermissionShutdownResolutionTasks.isEmpty)
    XCTAssertTrue(store.acpPermissionTerminalOutcomesByID.isEmpty)

    let auditContext = ModelContext(container)
    let auditEvents = try auditContext.fetch(FetchDescriptor<SupervisorEvent>())
    XCTAssertTrue(auditEvents.isEmpty)
  }

  private func lifecycleStoreWithPersistence(
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
