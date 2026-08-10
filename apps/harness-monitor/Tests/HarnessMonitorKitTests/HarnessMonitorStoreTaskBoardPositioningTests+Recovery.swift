import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreTaskBoardPositioningTests {
  @Test("Repeated ready revokes a position mutation after its snapshot")
  func repeatedReadyRevokesPositionMutationAfterSnapshot() async throws {
    let client = RecordingHarnessClient()
    let item = taskBoardItem(id: "board-1", status: .todo)
    client.configureTaskBoardItems([item])
    let store = await makeBootstrappedStore(client: client)
    await client.blockNextTaskBoardItemsRead()
    let mutation = Task { @MainActor in
      await store.positionTaskBoardItem(
        id: item.id,
        sourceStatus: .todo,
        destinationStatus: .inProgress,
        placement: .first
      )
    }

    await client.waitUntilTaskBoardItemsReadIsBlocked()
    _ = try await store.invalidateTaskBoardDatabaseAccess(using: client)
    let recoveredItem = taskBoardItem(id: item.id, status: .blocked)
    store.applyTaskBoardDashboardSnapshot(
      HarnessMonitorStore.TaskBoardRefreshSnapshot(
        items: HarnessMonitorStore.TaskBoardSnapshotLoad(
          measured: HarnessMonitorStore.MeasuredOperation(
            value: [recoveredItem],
            latencyMs: 0
          )
        ),
        orchestratorStatus: HarnessMonitorStore.TaskBoardSnapshotLoad(measured: nil),
        projects: HarnessMonitorStore.TaskBoardSnapshotLoad(measured: nil),
        stepModeConfirmationRevision: 0
      ),
      positionMutationGeneration: store.taskBoardRuntimeState.positionMutation.generation
    )
    await client.releaseTaskBoardItemsRead()

    #expect(await mutation.value == false)
    #expect(store.globalTaskBoardItems.first?.status == .blocked)
    #expect(
      !client.recordedCalls().contains {
        if case .setTaskBoardItemPosition = $0 { return true }
        return false
      }
    )
  }
}
