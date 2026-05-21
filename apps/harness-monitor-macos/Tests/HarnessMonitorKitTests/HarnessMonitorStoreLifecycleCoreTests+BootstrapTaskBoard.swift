import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreLifecycleCoreTests {
  @Test("Bootstrap keeps cached task-board items until confirmation loads the live board")
  func bootstrapKeepsCachedTaskBoardItemsUntilConfirmationLoadsLiveBoard() async throws {
    let cachedItem = makeBootstrapTaskBoardItem(
      id: "board-cached-confirmation",
      provider: .gitHub,
      externalId: "234"
    )
    let liveItem = makeBootstrapTaskBoardItem(
      id: "board-cached-confirmation",
      provider: .todoist,
      externalId: "345"
    )
    let container = try HarnessMonitorModelContainer.preview()
    let seedingStore = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
    await seedingStore.cacheTaskBoardSnapshot(items: [cachedItem], orchestratorStatus: nil)

    let client = RecordingHarnessClient()
    client.configureTaskBoardItemSnapshots([[], [liveItem]])
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      modelContainer: container
    )
    store.initialTaskBoardConfirmationGracePeriod = .milliseconds(200)
    store.taskBoardConfirmationRetryInterval = .milliseconds(50)

    await store.bootstrap()

    #expect(store.connectionState == .online)
    #expect(store.globalTaskBoardItems.map(\.id) == ["board-cached-confirmation"])

    for _ in 0..<40 where store.globalTaskBoardItems.first?.externalRefs.first?.provider != .todoist
    {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(store.globalTaskBoardItems.map(\.id) == ["board-cached-confirmation"])
    #expect(store.globalTaskBoardItems.first?.externalRefs.first?.provider == .todoist)
  }

  @Test(
    "Bootstrap merges cached external task-board items when the first live board snapshot is partial"
  )
  func bootstrapMergesCachedExternalTaskBoardItemsWhenInitialLiveBoardSnapshotIsPartial()
    async throws
  {
    let cachedExternalItem = makeBootstrapTaskBoardItem(
      id: "board-cached-external",
      provider: .gitHub,
      externalId: "567"
    )
    let localLiveItem = TaskBoardItem(
      schemaVersion: 1,
      id: "board-live-local",
      title: "Local board task",
      body: "Arrives in the first live snapshot",
      status: .todo,
      priority: .medium,
      tags: ["local"],
      projectId: "proj-bootstrap",
      agentMode: .interactive,
      externalRefs: [],
      planning: TaskBoardPlanningState(summary: "Local board task"),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-05-19T10:10:00Z",
      updatedAt: "2026-05-19T10:11:00Z",
      deletedAt: nil
    )
    let liveExternalItem = makeBootstrapTaskBoardItem(
      id: "board-cached-external",
      provider: .gitHub,
      externalId: "567"
    )
    let container = try HarnessMonitorModelContainer.preview()
    let seedingStore = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
    await seedingStore.cacheTaskBoardSnapshot(items: [cachedExternalItem], orchestratorStatus: nil)

    let client = RecordingHarnessClient()
    client.configureTaskBoardItemSnapshots([
      [localLiveItem],
      [localLiveItem, liveExternalItem],
    ])
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      modelContainer: container
    )
    store.initialTaskBoardConfirmationGracePeriod = .milliseconds(200)
    store.taskBoardConfirmationRetryInterval = .milliseconds(50)

    await store.bootstrap()

    #expect(store.connectionState == .online)
    #expect(
      Set(store.globalTaskBoardItems.map(\.id))
        == Set(["board-live-local", "board-cached-external"]))

    for _ in 0..<40 {
      let liveIDs = store.globalTaskBoardItems.map(\.id)
      if liveIDs.count == 2, liveIDs.contains("board-live-local"),
        liveIDs.contains("board-cached-external")
      {
        let externalProviders = store.globalTaskBoardItems
          .first(where: { $0.id == "board-cached-external" })?
          .externalRefs.map(\.provider)
        if externalProviders == [.gitHub] {
          break
        }
      }
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(
      Set(store.globalTaskBoardItems.map(\.id))
        == Set(["board-live-local", "board-cached-external"]))
  }

  @Test("Bootstrap eventually clears cached task-board items when the live board stays empty")
  func bootstrapEventuallyClearsCachedTaskBoardItemsWhenLiveBoardStaysEmpty() async throws {
    let cachedItem = makeBootstrapTaskBoardItem(
      id: "board-cached-empty",
      provider: .gitHub,
      externalId: "456"
    )
    let container = try HarnessMonitorModelContainer.preview()
    let seedingStore = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
    await seedingStore.cacheTaskBoardSnapshot(items: [cachedItem], orchestratorStatus: nil)

    let client = RecordingHarnessClient()
    client.configureTaskBoardItemSnapshots([[]])
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      modelContainer: container
    )
    store.initialTaskBoardConfirmationGracePeriod = .milliseconds(40)
    store.taskBoardConfirmationRetryInterval = .milliseconds(10)

    await store.bootstrap()

    #expect(store.connectionState == .online)
    #expect(store.globalTaskBoardItems.map(\.id) == ["board-cached-empty"])

    for _ in 0..<40 where !store.globalTaskBoardItems.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(store.globalTaskBoardItems.isEmpty)
  }

  private func makeBootstrapTaskBoardItem(
    id: String,
    provider: TaskBoardExternalRefProvider,
    externalId: String
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Bootstrap \(id)",
      body: "Keep cached task-board items visible during startup",
      status: .todo,
      priority: .high,
      tags: ["bootstrap"],
      projectId: "proj-bootstrap",
      agentMode: .interactive,
      externalRefs: [
        TaskBoardExternalRef(
          provider: provider,
          externalId: externalId,
          url: "https://example.invalid/\(externalId)"
        )
      ],
      planning: TaskBoardPlanningState(summary: "Restore from cache first"),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-05-19T10:00:00Z",
      updatedAt: "2026-05-19T10:05:00Z",
      deletedAt: nil
    )
  }
}

private struct SnapshotCodingKey: CodingKey, Sendable {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}
