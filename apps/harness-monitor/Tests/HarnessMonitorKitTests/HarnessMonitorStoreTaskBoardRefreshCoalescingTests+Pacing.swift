import Testing

@testable import HarnessMonitorKit

/// Store-level cover for the pacing floor. `TaskBoardItemsRefreshPacingTests`
/// only pins the pure delay arithmetic; these pin the behaviour that arithmetic
/// exists for, so a regression in the slice loop or the immediate bypass shows
/// up as a failing test rather than as CPU burn during a board sync.
extension HarnessMonitorStoreTaskBoardRefreshCoalescingTests {
  @Test("A second push inside the pacing floor does not fetch the board again yet")
  func pushBurstInsidePacingFloorDefersSecondFetch() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()

    store.scheduleGitHubTaskBoardRefresh(using: client)
    try await Task.sleep(for: .milliseconds(200))
    let afterFirstFetch = client.readCallCount(.taskBoardItems(nil))

    store.scheduleGitHubTaskBoardRefresh(using: client)
    try await Task.sleep(for: .milliseconds(300))

    #expect(client.readCallCount(.taskBoardItems(nil)) == afterFirstFetch)

    try await Task.sleep(for: .milliseconds(900))

    #expect(client.readCallCount(.taskBoardItems(nil)) == afterFirstFetch + 1)
  }

  @Test("An awaited refresh breaks out of a pacing wait already in progress")
  func awaitedRefreshBreaksOutOfPacingWait() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()

    store.scheduleGitHubTaskBoardRefresh(using: client)
    try await Task.sleep(for: .milliseconds(200))
    let afterFirstFetch = client.readCallCount(.taskBoardItems(nil))

    // Leaves the refresh task parked inside the pacing wait, which is the state
    // an immediate request could not restart before.
    store.scheduleGitHubTaskBoardRefresh(using: client)
    try await Task.sleep(for: .milliseconds(120))

    let started = ContinuousClock.now
    await store.refreshTaskBoardDashboardSnapshot(using: client)
    let elapsed = ContinuousClock.now - started

    #expect(client.readCallCount(.taskBoardItems(nil)) > afterFirstFetch)
    #expect(elapsed < .milliseconds(600))
  }
}
