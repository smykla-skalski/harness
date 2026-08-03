import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board refresh feedback")
struct HarnessMonitorStoreTaskBoardRefreshFeedbackTests {
  @Test("Refresh reports staged progress and completes at the bottom right")
  func refreshReportsStagedProgressAndCompletesAtBottomRight() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    var toastEvents: [ToastHistoryEvent] = []
    store.toast.onHistoryEvent = { toastEvents.append($0) }

    await store.refreshTaskBoardDashboard()

    let progressMessages = toastEvents.compactMap { event -> String? in
      guard event.feedback.severity == .activity else { return nil }
      switch event.kind {
      case .presented, .refreshed:
        return event.feedback.message
      case .dismissed:
        return nil
      }
    }
    #expect(
      progressMessages == [
        "Syncing task sources",
        "Board ready · refreshing task sources",
        "Loading refreshed tasks",
      ])
    #expect(
      toastEvents.first?.feedback.accessibilityIdentifier
        == "harness.toast.activity.task-board-dashboard-refresh"
    )
    #expect(store.toast.activeFeedback.count == 1)
    #expect(store.toast.activeFeedback.first?.message == "Task board refreshed")
    #expect(store.toast.activeFeedback.first?.severity == .success)
    #expect(store.toast.activeFeedback.first?.position == .bottomTrailing)
  }

  @Test("Cancellation dismisses progress without reload or failure feedback")
  func cancellationDismissesProgressWithoutReloadOrFailureFeedback() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let baselineItemReads = client.readCallCount(.taskBoardItems(nil))
    client.configureTaskBoardSyncError(CancellationError())

    await store.refreshTaskBoardDashboard()

    #expect(client.readCallCount(.taskBoardItems(nil)) == baselineItemReads)
    #expect(store.toast.activeFeedback.isEmpty)
    #expect(store.currentFailureFeedbackMessage == nil)
  }

  @Test("Refresh is ignored while another task-board action is in flight")
  func refreshIsIgnoredWhileAnotherTaskBoardActionIsInFlight() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.beginTaskBoardAction()
    defer { store.endTaskBoardAction() }

    await store.refreshTaskBoardDashboard()

    #expect(
      !client.recordedCalls().contains(
        .syncTaskBoard(direction: .pull, dryRun: false, status: nil, provider: nil)
      )
    )
    #expect(store.toast.activeFeedback.isEmpty)
  }

  @Test("Refresh proceeds while an unrelated daemon action is in flight")
  func refreshProceedsWhileUnrelatedDaemonActionIsInFlight() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.beginDaemonAction()
    defer { store.endDaemonAction() }

    await store.refreshTaskBoardDashboard()

    #expect(
      client.recordedCalls().contains(
        .syncTaskBoard(direction: .pull, dryRun: false, status: nil, provider: nil)
      )
    )
  }

  @Test("An active sync can stop cleanly and the next sync starts immediately")
  func activeSyncStopsCleanlyAndCanRestart() async {
    let client = RecordingHarnessClient()
    client.taskBoardSyncDelay = .milliseconds(250)
    client.configureTaskBoardSyncError(
      HarnessMonitorAPIError.server(code: 400, message: "task-board sync cancelled by user")
    )
    let store = await makeBootstrappedStore(client: client)

    let firstSync = Task { @MainActor in
      await store.refreshTaskBoardDashboard()
    }
    #expect(await waitUntil { store.taskBoardSyncPhase == .syncing })
    #expect(store.contentUI.dashboard.taskBoardSyncPhase == .syncing)

    #expect(await store.cancelTaskBoardSync())
    #expect(store.taskBoardSyncPhase == .stopping)
    #expect(client.recordedCalls().contains(.cancelTaskBoardSync))
    await firstSync.value

    #expect(store.taskBoardSyncPhase == .idle)
    #expect(store.contentUI.dashboard.taskBoardSyncPhase == .idle)
    #expect(store.currentFailureFeedbackMessage == nil)
    #expect(store.currentSuccessFeedbackMessage == "Task source refresh stopped")

    client.taskBoardSyncDelay = nil
    client.configureTaskBoardSync(summary: TaskBoardSyncSummary(total: 0, providers: []))
    await store.refreshTaskBoardDashboard()

    let syncCalls = client.recordedCalls().filter {
      if case .syncTaskBoard = $0 { return true }
      return false
    }
    #expect(syncCalls.count == 2)
    #expect(store.taskBoardSyncPhase == .idle)
  }

  @Test("Stop releases a sync waiting on an in-flight board snapshot")
  func stopReleasesInFlightBoardSnapshotWait() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await client.blockNextTaskBoardItemsRead()

    let refresh = Task { @MainActor in
      await store.refreshTaskBoardDashboard()
    }
    await client.waitUntilTaskBoardItemsReadIsBlocked()

    #expect(store.taskBoardSyncPhase == .syncing)
    #expect(await store.cancelTaskBoardSync())
    #expect(
      await waitUntil {
        store.taskBoardSyncPhase == .idle
      }
    )
    #expect(store.currentSuccessFeedbackMessage == "Task source refresh stopped")

    await client.releaseTaskBoardItemsRead()
    await refresh.value
  }

  @Test("Stop acknowledgment does not wait for its replacement board snapshot")
  func stopAcknowledgmentDoesNotWaitForReplacementSnapshot() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await client.blockNextTaskBoardItemsRead()

    let refresh = Task { @MainActor in
      await store.refreshTaskBoardDashboard()
    }
    await client.waitUntilTaskBoardItemsReadIsBlocked()
    client.configureTaskBoardItemsDelay(.seconds(2))

    #expect(await store.cancelTaskBoardSync())
    let clock = ContinuousClock()
    let start = clock.now
    #expect(
      await waitUntil(timeout: .milliseconds(300)) {
        store.taskBoardSyncPhase == .idle
      }
    )
    #expect(start.duration(to: clock.now) < .milliseconds(300))
    #expect(store.currentSuccessFeedbackMessage == "Task source refresh stopped")

    await client.releaseTaskBoardItemsRead()
    await refresh.value
  }

  @Test("Background source refresh leaves the board responsive")
  func backgroundSourceRefreshLeavesBoardResponsive() async {
    let client = RecordingHarnessClient()
    client.queuedTaskBoardSyncStatusResponses = [
      TaskBoardSyncStatusResponse(active: true, cancellationRequested: false),
      TaskBoardSyncStatusResponse(
        active: false,
        cancellationRequested: false,
        summary: TaskBoardSyncSummary(total: 7, providers: [])
      ),
    ]
    let store = await makeBootstrappedStore(client: client)

    let refresh = Task { @MainActor in
      await store.refreshTaskBoardDashboard()
    }
    #expect(await waitUntil { client.recordedCalls().contains(.taskBoardSyncStatus) })

    #expect(store.taskBoardSyncPhase == .syncing)
    #expect(!store.isTaskBoardBusy)
    await refresh.value
    #expect(store.taskBoardSyncPhase == .idle)
    #expect(store.globalTaskBoardSyncSummary?.total == 7)
    #expect(client.recordedCalls().filter { $0 == .taskBoardSyncStatus }.count == 2)
  }

  @Test("Stop is retried when it races the initial sync acknowledgement")
  func stopRetriesAfterAcknowledgementRace() async {
    let client = RecordingHarnessClient()
    client.taskBoardSyncDelay = .milliseconds(100)
    client.taskBoardSyncCancelResponse = TaskBoardSyncCancelResponse(cancelled: false)
    client.queuedTaskBoardSyncStatusResponses = [
      TaskBoardSyncStatusResponse(active: true, cancellationRequested: false),
      TaskBoardSyncStatusResponse(active: false, cancellationRequested: false),
    ]
    let store = await makeBootstrappedStore(client: client)

    let refresh = Task { @MainActor in
      await store.refreshTaskBoardDashboard()
    }
    #expect(await waitUntil { store.taskBoardSyncPhase == .syncing })
    #expect(await store.cancelTaskBoardSync())
    await refresh.value

    #expect(client.recordedCalls().filter { $0 == .cancelTaskBoardSync }.count == 2)
    #expect(store.taskBoardSyncPhase == .idle)
    #expect(store.currentSuccessFeedbackMessage == "Task source refresh stopped")
  }

  @Test("Background source failure is reported after the board acknowledgement")
  func backgroundSourceFailureIsReported() async {
    let client = RecordingHarnessClient()
    client.taskBoardSyncStatusResponse = TaskBoardSyncStatusResponse(
      active: false,
      cancellationRequested: false,
      error: "GitHub refresh failed"
    )
    let store = await makeBootstrappedStore(client: client)

    await store.refreshTaskBoardDashboard()

    #expect(store.taskBoardSyncPhase == .idle)
    #expect(store.currentFailureFeedbackMessage == "GitHub refresh failed")
    #expect(store.currentSuccessFeedbackMessage == nil)
  }

  @Test("Successful sync configuration clears a prior fixture error")
  func successfulSyncConfigurationClearsPriorFixtureError() async throws {
    let client = RecordingHarnessClient()
    client.configureTaskBoardSyncError(CancellationError())
    client.configureTaskBoardSync(
      summary: TaskBoardSyncSummary(total: 2, providers: [])
    )

    let summary = try await client.syncTaskBoard(
      request: TaskBoardSyncRequest(direction: .pull, dryRun: false)
    )

    #expect(summary.total == 2)
  }
}
