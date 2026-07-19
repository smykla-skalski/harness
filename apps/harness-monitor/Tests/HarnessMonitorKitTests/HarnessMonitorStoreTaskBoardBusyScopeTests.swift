import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board busy scope")
struct HarnessMonitorStoreTaskBoardBusyScopeTests {
  @Test("An unrelated daemon action does not flip isTaskBoardBusy")
  func unrelatedDaemonActionDoesNotFlipTaskBoardBusy() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()

    let action = Task { @MainActor in
      _ = await store.setHostBridgeCapability("mcp", enabled: true)
    }

    var observedBusy = false
    for _ in 0..<50 {
      if store.contentUI.dashboard.isTaskBoardBusy {
        observedBusy = true
        break
      }
      await Task.yield()
    }
    _ = await action.value

    #expect(observedBusy == false)
    #expect(store.contentUI.dashboard.isTaskBoardBusy == false)
  }

  @Test("A task-board mutation flips isTaskBoardBusy on then off")
  func taskBoardMutationFlipsTaskBoardBusy() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      TaskBoardItem(
        schemaVersion: 1,
        id: "board-1",
        title: "Board item",
        body: "Body",
        status: .todo,
        priority: .high,
        tags: [],
        projectId: "project-1",
        agentMode: .interactive,
        externalRefs: [],
        planning: TaskBoardPlanningState(),
        workflow: nil,
        sessionId: nil,
        workItemId: nil,
        usage: TaskBoardUsage(),
        createdAt: "2026-05-14T10:00:00Z",
        updatedAt: "2026-05-14T10:01:00Z",
        deletedAt: nil
      )
    ])
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()
    #expect(store.contentUI.dashboard.isTaskBoardBusy == false)

    let mutation = Task { @MainActor in
      await store.updateTaskBoardItemStatuses([
        TaskBoardItemStatusUpdate(id: "board-1", status: .inProgress)
      ])
    }

    var observedBusy = false
    for _ in 0..<50 {
      if store.contentUI.dashboard.isTaskBoardBusy {
        observedBusy = true
        break
      }
      await Task.yield()
    }
    _ = await mutation.value

    #expect(observedBusy)
    #expect(store.contentUI.dashboard.isTaskBoardBusy == false)
  }

  @Test("Deleting a task board item flips isTaskBoardBusy on then off")
  func taskBoardDeletionFlipsTaskBoardBusy() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      TaskBoardItem(
        schemaVersion: 1,
        id: "board-1",
        title: "Board item",
        body: "Body",
        status: .todo,
        priority: .high,
        tags: [],
        projectId: "project-1",
        agentMode: .interactive,
        externalRefs: [],
        planning: TaskBoardPlanningState(),
        workflow: nil,
        sessionId: nil,
        workItemId: nil,
        usage: TaskBoardUsage(),
        createdAt: "2026-05-14T10:00:00Z",
        updatedAt: "2026-05-14T10:01:00Z",
        deletedAt: nil
      )
    ])
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()
    #expect(store.contentUI.dashboard.isTaskBoardBusy == false)

    let deletion = Task { @MainActor in
      _ = await store.deleteTaskBoardItems(ids: ["board-1"])
    }

    var observedBusy = false
    for _ in 0..<50 {
      if store.contentUI.dashboard.isTaskBoardBusy {
        observedBusy = true
        break
      }
      await Task.yield()
    }
    _ = await deletion.value

    #expect(observedBusy)
    #expect(store.contentUI.dashboard.isTaskBoardBusy == false)
  }

  @Test("Scoped board UI permits a move that the global daemon guard drops")
  func scopedBoardUIPermitsMoveThatGlobalDaemonGuardDrops() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      TaskBoardItem(
        schemaVersion: 1,
        id: "board-1",
        title: "Board item",
        body: "Body",
        status: .todo,
        priority: .high,
        tags: [],
        projectId: "project-1",
        agentMode: .interactive,
        externalRefs: [],
        planning: TaskBoardPlanningState(),
        workflow: nil,
        sessionId: nil,
        workItemId: nil,
        usage: TaskBoardUsage(),
        createdAt: "2026-05-14T10:00:00Z",
        updatedAt: "2026-05-14T10:01:00Z",
        deletedAt: nil
      )
    ])
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()

    // An unrelated daemon action (e.g. a review or policy action) is
    // already in flight; the board is still enabled (isTaskBoardBusy is
    // false), so a click on it must not be silently dropped.
    store.beginDaemonAction()
    defer { store.endDaemonAction() }

    let success = await store.updateTaskBoardItemStatuses([
      TaskBoardItemStatusUpdate(id: "board-1", status: .inProgress)
    ])

    #expect(success)
    #expect(
      store.globalTaskBoardItems.first(where: { $0.id == "board-1" })?.status == .inProgress
    )
  }

  @Test("Unguarded board mutation clears an unrelated global daemon busy owner")
  func unguardedBoardMutationClearsUnrelatedGlobalDaemonBusyOwner() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      TaskBoardItem(
        schemaVersion: 1,
        id: "board-1",
        title: "Board item",
        body: "Body",
        status: .todo,
        priority: .high,
        tags: [],
        projectId: "project-1",
        agentMode: .interactive,
        externalRefs: [],
        planning: TaskBoardPlanningState(),
        workflow: nil,
        sessionId: nil,
        workItemId: nil,
        usage: TaskBoardUsage(),
        createdAt: "2026-05-14T10:00:00Z",
        updatedAt: "2026-05-14T10:01:00Z",
        deletedAt: nil
      )
    ])
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()

    store.beginDaemonAction()
    #expect(store.isDaemonActionInFlight)

    let success = await store.updateTaskBoardItemStatuses([
      TaskBoardItemStatusUpdate(id: "board-1", status: .inProgress)
    ])

    #expect(success)
    // The board move's own begin/end pair must not release the unrelated
    // owner's busy state - it is still running.
    #expect(store.isDaemonActionInFlight)

    store.endDaemonAction()
    #expect(store.isDaemonActionInFlight == false)
  }
}
