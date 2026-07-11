import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreUpdateStreamTests {
  @Test("Same-revision GitHub pushes replace the latest operation")
  func sameRevisionGitHubPushReplacesLatestOperation() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    store.applyGlobalNonSessionPushEvent(
      githubDataChange(revision: 7, operation: "reviews.pull_requests.resolve")
    )
    store.applyGlobalNonSessionPushEvent(
      githubDataChange(revision: 7, operation: "task_board.github.local_sync_ready")
    )

    #expect(store.contentUI.dashboard.githubDataRevision == 7)
    #expect(
      store.contentUI.dashboard.latestGitHubDataChange?.operation
        == "task_board.github.local_sync_ready"
    )
  }

  private func githubDataChange(revision: UInt64, operation: String) -> DaemonPushEvent {
    DaemonPushEvent(
      recordedAt: "2026-07-11T14:00:00Z",
      sessionId: nil,
      kind: .githubDataChanged(
        GitHubDataChangedPayload(revision: revision, operation: operation)
      )
    )
  }
}
