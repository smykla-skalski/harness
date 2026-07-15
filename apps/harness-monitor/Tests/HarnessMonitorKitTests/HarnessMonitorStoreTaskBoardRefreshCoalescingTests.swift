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
    for _ in 0..<20 {
      guard store.cacheWriteSync.taskBoardRefreshRequestGeneration == baselineGeneration else {
        break
      }
      await Task.yield()
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
}

@MainActor
private final class TaskBoardRefreshCompletionProbe {
  var didFinish = false
}
