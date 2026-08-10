import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreTaskBoardSettingsTests {
  @Test("A revoked Task Board read cannot report its stale failure")
  func revokedTaskBoardReadCannotReportStaleFailure() async throws {
    let client = RecordingHarnessClient()
    let store = connectedTaskBoardStore(client: client)
    store.adoptDatabaseBackedTaskBoard(client.taskBoardCapabilitiesValue)
    let gate = RecordingTaskBoardItemsReadGate()
    await gate.blockNextRead()
    let read = Task<String?, Never> { @MainActor in
      await store.readTaskBoard { _ -> String in
        await gate.suspendIfConfigured()
        throw HarnessMonitorAPIError.server(code: 503, message: "stale read failure")
      }
    }

    await gate.waitUntilBlocked()
    _ = try await store.invalidateTaskBoardDatabaseAccess(using: client)
    await gate.release()

    #expect(await read.value == nil)
    #expect(store.currentFailureFeedbackMessage?.contains("stale read failure") != true)
    await store.prepareForTermination()
  }

  @Test("Cancelled daemon-started source recovery restores idle controls")
  func cancelledDaemonStartedSourceRecoveryRestoresIdleControls() async throws {
    let client = RecordingHarnessClient()
    client.taskBoardSyncStatusResponse = TaskBoardSyncStatusResponse(
      active: true,
      cancellationRequested: true
    )
    let store = connectedTaskBoardStore(client: client)
    let invalidation = Task { @MainActor in
      try await store.invalidateTaskBoardDatabaseAccess(using: client)
    }

    #expect(await waitUntil { store.taskBoardSyncPhase == .stopping })
    invalidation.cancel()
    await #expect(throws: CancellationError.self) {
      _ = try await invalidation.value
    }

    #expect(store.taskBoardSyncPhase == .idle)
    await store.prepareForTermination()
  }
}
