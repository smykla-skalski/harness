import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board triage reads")
struct HarnessMonitorStoreTaskBoardTriageTests {
  @Test("Fetches the current decision when online")
  func fetchesCurrentDecisionWhenOnline() async throws {
    let client = RecordingHarnessClient()
    client.taskBoardTriageDecisionsStorage["task-1"] = [
      TaskBoardTriageDecisionRecord(
        decisionId: "triage-00000000000000000000000000000000",
        itemId: "task-1",
        generation: 1,
        verdict: .todo,
        reasonCode: .meaningfulLabel,
        reasonDetail: nil,
        evaluatorIdentity: "task_board.triage.builtin_v1",
        evaluatorVersion: 1,
        evidenceFingerprint:
          "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        cause: .initial,
        decidedAt: "2026-07-23T00:00:00Z",
        supersededAt: nil
      )
    ]
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController(client: client))
    store.client = client
    store.connectionState = .online

    let response = await store.taskBoardItemTriageCurrent(id: "task-1")

    #expect(response?.current?.generation == 1)
  }

  @Test("Returns nil without a client instead of throwing")
  func returnsNilWhenOffline() async throws {
    let client = RecordingHarnessClient()
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController(client: client))
    store.client = client
    store.connectionState = .offline("daemon unavailable")

    let current = await store.taskBoardItemTriageCurrent(id: "task-1")
    let history = await store.taskBoardItemTriageHistory(id: "task-1")

    #expect(current == nil)
    #expect(history == nil)
  }

  @Test("Recording client purges triage history when an id is reused")
  func recordingClientPurgesTriageHistoryOnDelete() async throws {
    let client = RecordingHarnessClient()
    let request = TaskBoardCreateItemRequest(
      title: "Reusable recording item",
      body: "",
      priority: .medium,
      agentMode: .headless,
      tags: []
    )
    let created = try await client.createTaskBoardItem(request: request)
    client.taskBoardTriageDecisionsStorage[created.id] = [
      TaskBoardTriageDecisionRecord(
        decisionId: "triage-00000000000000000000000000000000",
        itemId: created.id,
        generation: 1,
        verdict: .todo,
        reasonCode: .meaningfulLabel,
        reasonDetail: nil,
        evaluatorIdentity: "task_board.triage.builtin_v1",
        evaluatorVersion: 1,
        evidenceFingerprint:
          "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        cause: .initial,
        decidedAt: "2026-07-23T00:00:00Z",
        supersededAt: nil
      )
    ]
    client.taskBoardTriageOverridesStorage[created.id] = Self.triageOverride

    _ = try await client.deleteTaskBoardItem(id: created.id)
    let recreated = try await client.createTaskBoardItem(request: request)
    let current = try await client.taskBoardItemTriageCurrent(id: recreated.id)

    #expect(recreated.id == created.id)
    #expect(current.current == nil)
    #expect(current.triageOverride == nil)
  }

  @Test("A failed override mutation still refreshes the dashboard snapshot")
  func failedOverrideMutationStillRefreshesSnapshot() async throws {
    let client = RecordingHarnessClient()
    client.taskBoardItemsStorage = [Self.item(id: "task-1")]
    client.taskBoardTriageOverrideError = HarnessMonitorAPIError.server(
      code: 501,
      message: "Triage override unavailable"
    )
    client.taskBoardTriageOverrideErrorRemainingUses = 1
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController(client: client))
    store.client = client
    store.connectionState = .online
    store.globalTaskBoardItems = [Self.item(id: "task-1")]

    client.taskBoardItemsStorage.append(Self.item(id: "task-2"))

    let succeeded = await store.setTaskBoardItemTriageOverride(
      id: "task-1", verdict: .todo, reason: nil)

    #expect(succeeded == false)
    #expect(store.globalTaskBoardItems.contains { $0.id == "task-2" })
  }

  @Test("Set retries when only the board sequence changed")
  func setRetriesAfterUnrelatedBoardChange() async {
    let client = RecordingHarnessClient()
    let task = Self.item(id: "task-1")
    client.taskBoardItemsStorage = [task, Self.item(id: "task-2")]
    client.taskBoardTriageOverrideError = Self.concurrentModificationError
    client.taskBoardTriageOverrideErrorRemainingUses = 1
    client.taskBoardTriageOverrideItemsAfterError = [
      task,
      Self.item(id: "task-2", title: "Changed elsewhere"),
    ]
    let store = Self.onlineStore(client: client, items: [task])

    let succeeded = await store.setTaskBoardItemTriageOverride(
      id: task.id,
      verdict: .todo,
      reason: "operator decision"
    )

    #expect(succeeded)
    #expect(client.taskBoardTriageOverrideSetRequests.count == 2)
    #expect(client.taskBoardTriageOverrideSetRequests.map(\.expectedItemRevision) == [1, 1])
    #expect(client.taskBoardTriageOverrideSetRequests.map(\.expectedItemsChangeSeq) == [0, 1])
  }

  @Test("Set refuses to overwrite a same-item concurrent change")
  func setRejectsSameItemConcurrentChange() async {
    let client = RecordingHarnessClient()
    let task = Self.item(id: "task-1")
    client.taskBoardItemsStorage = [task]
    client.taskBoardTriageOverrideError = Self.concurrentModificationError
    client.taskBoardTriageOverrideErrorRemainingUses = 1
    client.taskBoardTriageOverrideItemsAfterError = [
      Self.item(id: task.id, title: "Changed by another operator")
    ]
    let store = Self.onlineStore(client: client, items: [task])

    let succeeded = await store.setTaskBoardItemTriageOverride(
      id: task.id,
      verdict: .todo,
      reason: nil
    )

    #expect(!succeeded)
    #expect(client.taskBoardTriageOverrideSetRequests.count == 1)
  }

  @Test("Clear retries when only the board sequence changed")
  func clearRetriesAfterUnrelatedBoardChange() async {
    let client = RecordingHarnessClient()
    let task = Self.item(id: "task-1")
    client.taskBoardItemsStorage = [task, Self.item(id: "task-2")]
    client.taskBoardTriageOverridesStorage[task.id] = Self.triageOverride
    client.taskBoardTriageOverrideError = Self.concurrentModificationError
    client.taskBoardTriageOverrideErrorRemainingUses = 1
    client.taskBoardTriageOverrideItemsAfterError = [
      task,
      Self.item(id: "task-2", title: "Changed elsewhere"),
    ]
    let store = Self.onlineStore(client: client, items: [task])

    let succeeded = await store.clearTaskBoardItemTriageOverride(id: task.id)

    #expect(succeeded)
    #expect(client.taskBoardTriageOverrideClearRequests.count == 2)
    #expect(client.taskBoardTriageOverrideClearRequests.map(\.expectedItemRevision) == [1, 1])
    #expect(client.taskBoardTriageOverrideClearRequests.map(\.expectedItemsChangeSeq) == [0, 1])
  }

  @Test("Clear refuses to remove a same-item concurrent override")
  func clearRejectsSameItemConcurrentChange() async {
    let client = RecordingHarnessClient()
    let task = Self.item(id: "task-1")
    client.taskBoardItemsStorage = [task]
    client.taskBoardTriageOverridesStorage[task.id] = Self.triageOverride
    client.taskBoardTriageOverrideError = Self.concurrentModificationError
    client.taskBoardTriageOverrideErrorRemainingUses = 1
    client.taskBoardTriageOverrideItemsAfterError = [
      Self.item(id: task.id, title: "Changed by another operator")
    ]
    let store = Self.onlineStore(client: client, items: [task])

    let succeeded = await store.clearTaskBoardItemTriageOverride(id: task.id)

    #expect(!succeeded)
    #expect(client.taskBoardTriageOverrideClearRequests.count == 1)
    #expect(client.taskBoardTriageOverridesStorage[task.id] == Self.triageOverride)
  }

  private static var concurrentModificationError: HarnessMonitorAPIError {
    .semanticServer(
      code: 409,
      semanticCode: "WORKFLOW_CONCURRENT",
      message: "Task board triage override changed"
    )
  }

  private static var triageOverride: TaskBoardTriageOverride {
    TaskBoardTriageOverride(
      verdict: .undecided,
      actor: "operator-1",
      reason: "waiting for evidence",
      setAt: "2026-07-23T14:00:00Z"
    )
  }

  private static func onlineStore(
    client: RecordingHarnessClient,
    items: [TaskBoardItem]
  ) -> HarnessMonitorStore {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController(client: client))
    store.client = client
    store.connectionState = .online
    store.globalTaskBoardItems = items
    return store
  }

  private static func item(id: String, title: String = "Fixture board item") -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: title,
      body: "",
      status: .todo,
      priority: .medium,
      tags: [],
      projectId: nil,
      agentMode: .interactive,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-07-23T00:00:00Z",
      updatedAt: "2026-07-23T00:01:00Z",
      deletedAt: nil
    )
  }
}
