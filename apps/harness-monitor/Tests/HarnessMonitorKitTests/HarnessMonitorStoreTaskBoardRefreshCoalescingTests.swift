import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board refresh coalescing")
struct HarnessMonitorStoreTaskBoardRefreshCoalescingTests {
  @Test("Push and explicit refresh share one item and status snapshot")
  func pushAndExplicitRefreshShareSnapshot() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()
    let baselineItemReads = client.readCallCount(.taskBoardItems(nil))
    let baselineStatusReads = client.readCallCount(.taskBoardOrchestratorStatus)

    store.scheduleGitHubTaskBoardRefresh(using: client)
    await store.refreshTaskBoardDashboardSnapshot(using: client)
    try await Task.sleep(for: .milliseconds(100))

    #expect(client.readCallCount(.taskBoardItems(nil)) == baselineItemReads + 1)
    #expect(
      client.readCallCount(.taskBoardOrchestratorStatus) == baselineStatusReads + 1
    )
  }

  @Test("Mutation deferral holds a push beyond the debounce and releases one snapshot")
  func mutationDeferralHoldsPushUntilCompletion() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()
    let baselineItemReads = client.readCallCount(.taskBoardItems(nil))
    let baselineStatusReads = client.readCallCount(.taskBoardOrchestratorStatus)

    store.beginTaskBoardDashboardRefreshDeferral()
    store.scheduleGitHubTaskBoardRefresh(using: client)
    try await Task.sleep(for: .milliseconds(100))

    #expect(client.readCallCount(.taskBoardItems(nil)) == baselineItemReads)
    #expect(client.readCallCount(.taskBoardOrchestratorStatus) == baselineStatusReads)

    await store.finishTaskBoardDashboardRefreshDeferral(using: client)
    try await Task.sleep(for: .milliseconds(100))

    #expect(client.readCallCount(.taskBoardItems(nil)) == baselineItemReads + 1)
    #expect(
      client.readCallCount(.taskBoardOrchestratorStatus) == baselineStatusReads + 1
    )
  }

  @Test("Explicit refresh waits for a deferred snapshot to finish")
  func deferredExplicitRefreshWaitsUntilDeferralFinishes() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()
    let baselineGeneration = store.cacheWriteSync.taskBoardRefreshRequestGeneration
    let completion = TaskBoardRefreshCompletionProbe()

    store.beginTaskBoardDashboardRefreshDeferral()
    let refreshTask = Task { @MainActor in
      await store.refreshTaskBoardDashboardSnapshot(using: client)
      completion.didFinish = true
    }
    _ = await waitUntil {
      store.cacheWriteSync.taskBoardRefreshRequestGeneration != baselineGeneration
    }

    #expect(store.cacheWriteSync.taskBoardRefreshRequestGeneration > baselineGeneration)
    let requestGeneration = store.cacheWriteSync.taskBoardRefreshRequestGeneration
    #expect(store.cacheWriteSync.taskBoardRefreshTask == nil)
    #expect(store.cacheWriteSync.taskBoardRefreshCompletedGeneration < requestGeneration)
    #expect(store.cacheWriteSync.taskBoardRefreshCompletionWaiters[requestGeneration]?.count == 1)
    #expect(completion.didFinish == false)

    await store.finishTaskBoardDashboardRefreshDeferral(using: client)
    await refreshTask.value

    #expect(completion.didFinish)
    #expect(store.cacheWriteSync.taskBoardRefreshCompletedGeneration >= requestGeneration)
    #expect(store.cacheWriteSync.taskBoardRefreshCompletionWaiters.isEmpty)
  }

  @Test("Already-completed refresh generation returns without registering a waiter")
  func completedRefreshGenerationReturnsWithoutRegisteringWaiter() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()
    let completedGeneration = store.cacheWriteSync.taskBoardRefreshCompletedGeneration

    await store.waitForTaskBoardDashboardSnapshotRefresh(completedGeneration)

    #expect(store.cacheWriteSync.taskBoardRefreshCompletionWaiters.isEmpty)
  }

  @Test("A refresh loaded before an optimistic move cannot restore the old position")
  func staleRefreshCannotOverwriteOptimisticPosition() async {
    let client = RecordingHarnessClient()
    let moving = taskBoardItem(id: "moving", status: .todo)
    let anchor = taskBoardItem(id: "anchor", status: .planning)
    client.configureTaskBoardItems([moving, anchor])
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()
    client.configureTaskBoardItemSnapshots([[moving, anchor]])
    await client.blockNextTaskBoardItemsRead()

    let refresh = Task { @MainActor in
      await store.refreshTaskBoardDashboardSnapshot(using: client)
    }
    await client.waitUntilTaskBoardItemsReadIsBlocked()
    let mutation = store.beginOptimisticTaskBoardPosition(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: .relative(
        TaskBoardRelativeLanePlacement(anchorItemID: "anchor", edge: .after)
      )
    )
    #expect(mutation != nil)
    #expect(store.globalTaskBoardItems.map(\.id) == ["anchor", "moving"])
    let position = Task { @MainActor in
      await store.positionTaskBoardItem(
        id: "moving",
        sourceStatus: .todo,
        destinationStatus: .planning,
        placement: .relative(
          TaskBoardRelativeLanePlacement(anchorItemID: "anchor", edge: .after)
        ),
        optimisticMutation: mutation
      )
    }
    _ = await waitUntil {
      store.taskBoardRuntimeState.positionMutation.pendingTokens.isEmpty
    }
    #expect(store.taskBoardRuntimeState.positionMutation.pendingTokens.isEmpty)

    await client.releaseTaskBoardItemsRead()
    await refresh.value

    #expect(store.globalTaskBoardItems.map(\.id) == ["anchor", "moving"])
    #expect(store.globalTaskBoardItems.last?.status == .planning)
    #expect(await position.value)
  }

  @Test("A refresh stays behind an active optimistic move")
  func refreshCannotOverwritePendingOptimisticPosition() async {
    let client = RecordingHarnessClient()
    let moving = taskBoardItem(id: "moving", status: .todo)
    let anchor = taskBoardItem(id: "anchor", status: .planning)
    client.configureTaskBoardItems([moving, anchor])
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()
    let mutation = store.beginOptimisticTaskBoardPosition(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: .relative(
        TaskBoardRelativeLanePlacement(anchorItemID: "anchor", edge: .after)
      )
    )
    #expect(mutation != nil)
    client.configureTaskBoardItemSnapshots([[moving, anchor]])

    await store.refreshTaskBoardDashboardSnapshot(using: client)

    #expect(store.globalTaskBoardItems.map(\.id) == ["anchor", "moving"])
    #expect(store.globalTaskBoardItems.last?.status == .planning)
  }

  @Test("A full lifecycle refresh cannot apply items loaded before a position move")
  func lifecycleRefreshCannotOverwriteResolvedPosition() async {
    let client = RecordingHarnessClient()
    let moving = taskBoardItem(id: "moving", status: .todo)
    let anchor = taskBoardItem(id: "anchor", status: .planning)
    client.configureTaskBoardItems([moving, anchor])
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()
    client.configureTaskBoardItemSnapshots([[moving, anchor]])
    await client.blockNextTaskBoardItemsRead()

    let refresh = Task { @MainActor in
      await store.refresh(using: client, preserveSelection: false)
    }
    await client.waitUntilTaskBoardItemsReadIsBlocked()
    let placement = TaskBoardLanePlacement.relative(
      TaskBoardRelativeLanePlacement(anchorItemID: "anchor", edge: .after)
    )
    let mutation = store.beginOptimisticTaskBoardPosition(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: placement
    )
    let success = await store.positionTaskBoardItem(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: placement,
      optimisticMutation: mutation
    )
    #expect(success)

    await client.releaseTaskBoardItemsRead()
    await refresh.value

    #expect(store.globalTaskBoardItems.map(\.id) == ["anchor", "moving"])
    #expect(store.globalTaskBoardItems.last?.status == .planning)
  }

  @Test("A cancelled confirmation refresh cannot restore a pre-move snapshot")
  func confirmationRefreshCannotOverwriteResolvedPosition() async throws {
    let client = RecordingHarnessClient()
    let moving = taskBoardItem(id: "moving", status: .todo)
    let anchor = taskBoardItem(id: "anchor", status: .planning)
    client.configureTaskBoardItems([moving, anchor])
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()
    store.initialTaskBoardConfirmationGracePeriod = .seconds(1)
    store.taskBoardConfirmationRetryInterval = .milliseconds(1)
    client.configureTaskBoardItemSnapshots([[moving, anchor]])
    await client.blockNextTaskBoardItemsRead()
    store.scheduleInitialTaskBoardConfirmationRefresh(
      using: client,
      preservedItemIDs: ["moving"],
      preservedStatus: false
    )
    let confirmationTask = try #require(store.initialTaskBoardConfirmationTask)
    await client.waitUntilTaskBoardItemsReadIsBlocked()
    let placement = TaskBoardLanePlacement.relative(
      TaskBoardRelativeLanePlacement(anchorItemID: "anchor", edge: .after)
    )
    let mutation = store.beginOptimisticTaskBoardPosition(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: placement
    )
    let success = await store.positionTaskBoardItem(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: placement,
      optimisticMutation: mutation
    )
    #expect(success)

    await client.releaseTaskBoardItemsRead()
    await confirmationTask.value

    #expect(store.globalTaskBoardItems.map(\.id) == ["anchor", "moving"])
    #expect(store.globalTaskBoardItems.last?.status == .planning)
  }

  @Test("An older position response cannot overwrite a newer optimistic move")
  func stalePositionResponseCannotOverwriteNewerMove() async throws {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(id: "moving", status: .todo),
      taskBoardItem(id: "planning-anchor", status: .planning),
      taskBoardItem(id: "progress-anchor", status: .inProgress),
    ])
    let store = await makeBootstrappedStore(client: client)
    let pendingCacheWrite = Task<Void, Never> {
      _ = try? await Task.sleep(for: .seconds(60))
    }
    store.cacheWriteSync.pendingTaskBoardSnapshotCacheWriteTask = pendingCacheWrite
    let cacheWriteToken = store.cacheWriteSync.taskBoardSnapshotCacheWriteToken
    let first = try #require(
      store.beginOptimisticTaskBoardPosition(
        id: "moving",
        sourceStatus: .todo,
        destinationStatus: .planning,
        placement: .relative(
          TaskBoardRelativeLanePlacement(anchorItemID: "planning-anchor", edge: .after)
        )
      )
    )
    #expect(pendingCacheWrite.isCancelled)
    #expect(store.cacheWriteSync.pendingTaskBoardSnapshotCacheWriteTask == nil)
    #expect(store.cacheWriteSync.taskBoardSnapshotCacheWriteToken == cacheWriteToken + 1)
    let second = try #require(
      store.beginOptimisticTaskBoardPosition(
        id: "moving",
        sourceStatus: .planning,
        destinationStatus: .inProgress,
        placement: .relative(
          TaskBoardRelativeLanePlacement(anchorItemID: "progress-anchor", edge: .after)
        )
      )
    )

    store.completeSuccessfulTaskBoardPosition(
      taskBoardItem(id: "moving", status: .planning),
      mutation: first
    )

    #expect(
      store.globalTaskBoardItems.first(where: { $0.id == "moving" })?.status == .inProgress
    )
    #expect(
      store.taskBoardRuntimeState.positionMutation.pendingTokens == Set([second.token])
    )
  }

  @Test("Policy push refreshes only policy state")
  func policyPushRefreshesOnlyPolicyState() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()
    try await Task.sleep(for: .milliseconds(100))
    let baselineWorkspaceReads = client.readCallCount(.policyCanvasWorkspace)
    let baselinePipelineReads = client.readCallCount(.policyPipeline)
    let baselineAuditReads = client.readCallCount(.policyPipelineAudit)
    let baselineItemReads = client.readCallCount(.taskBoardItems(nil))
    let baselineStatusReads = client.readCallCount(.taskBoardOrchestratorStatus)

    let handled = await store.applyGlobalDataPushEventFromStream(
      DaemonPushEvent(
        recordedAt: "2026-07-15T12:00:00Z",
        sessionId: nil,
        kind: .taskBoardUpdated(
          TaskBoardUpdatedPayload(
            revision: 41,
            scopes: ["task_board:policy_pipeline"]
          )
        )
      )
    )
    try await Task.sleep(for: .milliseconds(100))

    #expect(handled)
    #expect(client.readCallCount(.policyCanvasWorkspace) == baselineWorkspaceReads + 1)
    #expect(client.readCallCount(.policyPipeline) == baselinePipelineReads + 1)
    #expect(client.readCallCount(.policyPipelineAudit) == baselineAuditReads + 1)
    #expect(client.readCallCount(.taskBoardItems(nil)) == baselineItemReads)
    #expect(client.readCallCount(.taskBoardOrchestratorStatus) == baselineStatusReads)
    #expect(store.globalPolicyCanvasWorkspace != nil)
  }

  @Test("Reconnect refreshes loaded policy state and keeps unused policy state lazy")
  func reconnectRefreshesOnlyPreviouslyLoadedPolicyState() async throws {
    let loadedClient = RecordingHarnessClient()
    let loadedStore = await makeBootstrappedStore(client: loadedClient)
    loadedStore.stopGlobalStream()
    await loadedStore.refreshPolicyPipeline()
    try await Task.sleep(for: .milliseconds(100))
    let loadedWorkspaceReads = loadedClient.readCallCount(.policyCanvasWorkspace)

    await loadedStore.recoverGitHubDataPushState(using: loadedClient)
    try await Task.sleep(for: .milliseconds(100))

    #expect(loadedClient.readCallCount(.policyCanvasWorkspace) == loadedWorkspaceReads + 1)

    let lazyClient = RecordingHarnessClient()
    let lazyStore = await makeBootstrappedStore(client: lazyClient)
    lazyStore.stopGlobalStream()
    try await Task.sleep(for: .milliseconds(100))
    let lazyWorkspaceReads = lazyClient.readCallCount(.policyCanvasWorkspace)
    #expect(lazyStore.globalPolicyCanvasWorkspace == nil)

    await lazyStore.recoverGitHubDataPushState(using: lazyClient)
    try await Task.sleep(for: .milliseconds(100))

    #expect(lazyClient.readCallCount(.policyCanvasWorkspace) == lazyWorkspaceReads)
  }

  private func taskBoardItem(id: String, status: TaskBoardStatus) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Board item \(id)",
      body: "",
      status: status,
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
      createdAt: "2026-07-28T10:00:00Z",
      updatedAt: "2026-07-28T10:00:00Z",
      deletedAt: nil
    )
  }
}

@MainActor
private final class TaskBoardRefreshCompletionProbe {
  var didFinish = false
}
