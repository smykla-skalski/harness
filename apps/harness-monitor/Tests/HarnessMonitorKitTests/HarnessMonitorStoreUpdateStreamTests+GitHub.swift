import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreUpdateStreamTests {
  @Test("Task Board push scopes select only affected dashboard data")
  func taskBoardPushScopesSelectAffectedData() {
    #expect(
      HarnessMonitorStore.taskBoardPushRefreshSelection(scopes: ["task_board:items"])
        == .init(items: true, orchestratorStatus: false, policyPipeline: false)
    )
    #expect(
      HarnessMonitorStore.taskBoardPushRefreshSelection(scopes: ["task_board:orchestrator"])
        == .init(items: false, orchestratorStatus: true, policyPipeline: false)
    )
    #expect(
      HarnessMonitorStore.taskBoardPushRefreshSelection(scopes: ["task_board:policy_pipeline"])
        == .init(items: false, orchestratorStatus: false, policyPipeline: true)
    )
    #expect(
      HarnessMonitorStore.taskBoardPushRefreshSelection(scopes: ["task_board:runtime_config"])
        == .init(items: false, orchestratorStatus: false, policyPipeline: false)
    )
    #expect(
      HarnessMonitorStore.taskBoardPushRefreshSelection(scopes: ["task_board:future"])
        == .init(items: true, orchestratorStatus: true, policyPipeline: true)
    )
  }

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
