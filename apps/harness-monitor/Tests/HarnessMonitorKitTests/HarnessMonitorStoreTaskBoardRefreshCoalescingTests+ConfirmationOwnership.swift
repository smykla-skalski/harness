import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreTaskBoardRefreshCoalescingTests {
  @Test("A cancelled confirmation task cannot erase its replacement handle")
  func cancelledConfirmationCannotEraseReplacementHandle() async throws {
    let client = RecordingHarnessClient()
    let moving = confirmationTaskBoardItem(id: "moving")
    client.configureTaskBoardItems([moving])
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()
    store.initialTaskBoardConfirmationGracePeriod = .seconds(5)
    store.taskBoardConfirmationRetryInterval = .milliseconds(1)
    client.configureTaskBoardItemSnapshots(Array(repeating: [], count: 20))
    await client.blockNextTaskBoardItemsRead()

    store.scheduleInitialTaskBoardConfirmationRefresh(
      using: client,
      preservedItemIDs: ["moving"],
      preservedStatus: false
    )
    let cancelledTask = try #require(store.initialTaskBoardConfirmationTask)
    await client.waitUntilTaskBoardItemsReadIsBlocked()
    store.scheduleInitialTaskBoardConfirmationRefresh(
      using: client,
      preservedItemIDs: ["moving"],
      preservedStatus: false
    )
    let replacementTask = try #require(store.initialTaskBoardConfirmationTask)

    await client.releaseTaskBoardItemsRead()
    await cancelledTask.value
    #expect(store.initialTaskBoardConfirmationTask != nil)

    store.cancelInitialTaskBoardConfirmationRefresh()
    await replacementTask.value
    #expect(store.initialTaskBoardConfirmationTask == nil)
  }

  private func confirmationTaskBoardItem(id: String) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Board item \(id)",
      body: "",
      status: .todo,
      priority: .medium,
      tags: [],
      projectId: "project-1",
      agentMode: .interactive,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-08-10T08:00:00Z",
      updatedAt: "2026-08-10T08:00:00Z",
      deletedAt: nil
    )
  }
}
