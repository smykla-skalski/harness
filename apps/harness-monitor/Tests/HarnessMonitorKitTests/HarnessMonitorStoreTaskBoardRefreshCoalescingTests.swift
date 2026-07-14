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
}
