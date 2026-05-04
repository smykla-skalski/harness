import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreActionTests {
  @Test("Offline session actions fail in read-only mode without sending daemon mutations")
  func offlineSessionActionsFailInReadOnlyMode() async {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)
    store.connectionState = .offline("daemon down")

    let created = await store.createTask(
      title: "Should not send",
      context: "Offline mode must stay read-only",
      severity: .low
    )

    #expect(created == false)
    #expect(client.recordedCalls().isEmpty)
    #expect(store.currentFailureFeedbackMessage?.contains("read-only mode") == true)

    store.requestEndSelectedSessionConfirmation()
    #expect(store.pendingConfirmation == nil)
  }

  @Test("Create task uses scoped session action loading")
  func createTaskUsesScopedSessionActionLoading() async {
    let client = RecordingHarnessClient()
    client.configureMutationDelay(.milliseconds(150))
    let store = await selectedActionStore(client: client)

    let createTask = Task {
      await store.createTask(
        title: "Scoped loading",
        context: "Diagnostics refresh should not impersonate a mutation spinner.",
        severity: .low
      )
    }
    await Task.yield()

    #expect(store.isSessionActionInFlight)
    #expect(store.isBusy)
    #expect(store.isDaemonActionInFlight == false)
    #expect(store.isDiagnosticsRefreshInFlight == false)

    _ = await createTask.value

    #expect(store.isSessionActionInFlight == false)
    #expect(store.isBusy == false)
  }

  func observeResponseSummary(updatedAt: String) -> SessionSummary {
    let summary = PreviewFixtures.summary
    return SessionSummary(
      projectId: summary.projectId,
      projectName: summary.projectName,
      projectDir: summary.projectDir,
      contextRoot: summary.contextRoot,
      sessionId: summary.sessionId,
      worktreePath: summary.worktreePath,
      sharedPath: summary.sharedPath,
      originPath: summary.originPath,
      branchRef: summary.branchRef,
      title: summary.title,
      context: summary.context,
      status: summary.status,
      createdAt: summary.createdAt,
      updatedAt: updatedAt,
      lastActivityAt: updatedAt,
      leaderId: summary.leaderId,
      observeId: summary.observeId,
      pendingLeaderTransfer: summary.pendingLeaderTransfer,
      externalOrigin: summary.externalOrigin,
      adoptedAt: summary.adoptedAt,
      metrics: summary.metrics
    )
  }
}
