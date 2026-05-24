import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor content selection observation")
struct HarnessMonitorContentSelectionTests {
  @Test("Content toolbar global actions ignore bookmark and filter churn")
  func contentToolbarGlobalActionsIgnoreBookmarkAndFilterChurn() async {
    let store = await makeBootstrappedStore()

    let bookmarkInvalidated = await didInvalidate(
      toolbarGlobalActionState(for: store),
      after: {
        store.bookmarkedSessionIds = ["bookmark-content"]
      }
    )
    #expect(bookmarkInvalidated == false)

    let filterInvalidated = await didInvalidate(
      toolbarGlobalActionState(for: store),
      after: {
        store.searchText = "preview"
        store.flushPendingSearchRebuild()
      }
    )
    #expect(filterInvalidated == false)
  }

  @Test("Content session summary ignores toast feedback churn")
  func contentSessionSummaryIgnoresToastFeedbackChurn() async {
    let store = await makeBootstrappedStore()

    let didChange = await didInvalidate(
      { store.contentUI.session.selectedSessionSummary },
      after: {
        store.presentSuccessFeedback("Refresh complete")
      }
    )

    #expect(didChange == false)
  }

  @Test("Content dashboard state ignores session selection churn")
  func contentDashboardStateIgnoresSessionSelectionChurn() async {
    let store = await makeBootstrappedStore()

    let didChange = await didInvalidate(
      {
        (
          store.contentUI.dashboard.connectionState,
          store.contentUI.dashboard.isBusy,
          store.contentUI.dashboard.isRefreshing,
          store.contentUI.dashboard.isLaunchAgentInstalled
        )
      },
      after: {
        await store.selectSession(PreviewFixtures.summary.sessionId)
      }
    )

    #expect(didChange == false)
  }

  @Test("Daemon status churn skips shell session chrome and inspector resync")
  func daemonStatusChurnSkipsShellSessionChromeAndInspectorResync() async {
    let store = await makeBootstrappedStore()
    guard let daemonStatus = store.daemonStatus else {
      Issue.record("Missing daemon status after bootstrap")
      return
    }

    store.debugResetUISyncCounts()
    store.daemonStatus = DaemonStatusReport(
      manifest: daemonStatus.manifest,
      launchAgent: daemonStatus.launchAgent,
      projectCount: daemonStatus.projectCount + 1,
      worktreeCount: daemonStatus.worktreeCount,
      sessionCount: daemonStatus.sessionCount,
      diagnostics: daemonStatus.diagnostics
    )

    #expect(store.debugUISyncCount(for: .contentToolbar) == 1)
    #expect(store.debugUISyncCount(for: .contentDashboard) == 1)
    #expect(store.debugUISyncCount(for: .contentShell) == 0)
    #expect(store.debugUISyncCount(for: .contentChrome) == 0)
    #expect(store.debugUISyncCount(for: .contentSession) == 0)
    #expect(store.debugUISyncCount(for: .contentSessionDetail) == 0)
  }

  @Test("Daemon busy churn only resyncs toolbar and dashboard")
  func daemonBusyChurnOnlyResyncsToolbarAndDashboard() async {
    let store = await makeBootstrappedStore()
    store.debugResetUISyncCounts()

    store.isDaemonActionInFlight = true

    #expect(store.debugUISyncCount(for: .contentToolbar) == 1)
    #expect(store.debugUISyncCount(for: .contentDashboard) == 1)
    #expect(store.debugUISyncCount(for: .contentShell) == 0)
    #expect(store.debugUISyncCount(for: .contentChrome) == 0)
    #expect(store.debugUISyncCount(for: .contentSession) == 0)
    #expect(store.debugUISyncCount(for: .contentSessionDetail) == 0)
  }

  @Test("Persisted data availability churn skips shell session and dashboard")
  func persistedDataAvailabilityChurnSkipsShellSessionAndDashboard() async {
    let store = await makeBootstrappedStore()
    store.connectionState = .offline("Daemon offline")
    store.debugResetUISyncCounts()

    store.persistedSessionCount = 1

    #expect(store.debugUISyncCount(for: .contentToolbar) == 1)
    #expect(store.debugUISyncCount(for: .contentChrome) == 1)
    #expect(store.debugUISyncCount(for: .contentShell) == 0)
    #expect(store.debugUISyncCount(for: .contentSession) == 0)
    #expect(store.debugUISyncCount(for: .contentSessionDetail) == 0)
    #expect(store.debugUISyncCount(for: .contentDashboard) == 0)
  }

  @Test("Content toolbar global actions ignore session selection churn")
  func contentToolbarGlobalActionsIgnoreSessionSelectionChurn() async {
    let store = await makeBootstrappedStore()

    let didChange = await didInvalidate(
      toolbarGlobalActionState(for: store),
      after: {
        await store.selectSession(PreviewFixtures.summary.sessionId)
      }
    )

    #expect(didChange == false)
  }

  @Test("Content session summary tracks session selection changes")
  func contentSessionSummaryTracksSessionSelectionChanges() async {
    let store = await makeBootstrappedStore()

    let didChange = await didInvalidate(
      { store.contentUI.session.selectedSessionSummary },
      after: {
        await store.selectSession(PreviewFixtures.summary.sessionId)
      }
    )

    #expect(didChange)
    #expect(store.contentUI.session.selectedSessionSummary == PreviewFixtures.summary)
  }

  @Test("Priming session selection updates content session state")
  func primingSessionSelectionUpdatesContentSessionState() async {
    let store = await makeBootstrappedStore()

    let didChange = await didInvalidate(
      {
        (
          store.contentUI.session.selectedSessionSummary,
          store.contentUI.session.isSelectionLoading
        )
      },
      after: {
        store.primeSessionSelection(PreviewFixtures.summary.sessionId)
      }
    )

    #expect(didChange)
    #expect(store.contentUI.session.selectedSessionSummary == PreviewFixtures.summary)
    #expect(store.contentUI.session.isSelectionLoading)
  }

  @Test("Priming session selection updates sidebar selection state")
  func primingSessionSelectionUpdatesSidebarSelectionState() async {
    let store = await makeBootstrappedStore()

    let didChange = await didInvalidate(
      { store.sidebarUI.selectedSessionID },
      after: {
        store.primeSessionSelection(PreviewFixtures.summary.sessionId)
      }
    )

    #expect(didChange)
    #expect(store.sidebarUI.selectedSessionID == PreviewFixtures.summary.sessionId)
  }

  @Test("Priming session selection does not resync content chrome before detail loads")
  func primingSessionSelectionSkipsContentChromeResync() async {
    let store = await makeBootstrappedStore()
    store.debugResetUISyncCounts()

    store.primeSessionSelection(PreviewFixtures.summary.sessionId)

    #expect(store.debugUISyncCount(for: .contentShell) == 0)
    #expect(store.debugUISyncCount(for: .contentSession) == 1)
    #expect(store.debugUISyncCount(for: .sidebar) == 1)
    #expect(store.debugUISyncCount(for: .contentChrome) == 0)
  }

  @Test("Selected-session task push skips content chrome resync")
  func selectedSessionTaskPushSkipsContentChromeResync() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.debugResetUISyncCounts()

    let task = WorkItem(
      taskId: "task-review-push",
      title: "Review push",
      context: "Task-only snapshot update",
      severity: .medium,
      status: .awaitingReview,
      assignedTo: nil,
      createdAt: "2026-03-28T14:21:00Z",
      updatedAt: "2026-03-28T14:21:00Z",
      createdBy: "leader-claude",
      notes: [],
      suggestedFix: nil,
      source: .manual,
      blockedReason: nil,
      completedAt: nil,
      checkpointSummary: nil
    )
    let metrics = SessionMetrics(
      agentCount: PreviewFixtures.summary.metrics.agentCount,
      activeAgentCount: PreviewFixtures.summary.metrics.activeAgentCount,
      idleAgentCount: PreviewFixtures.summary.metrics.idleAgentCount,
      awaitingReviewAgentCount: PreviewFixtures.summary.metrics.awaitingReviewAgentCount,
      openTaskCount: PreviewFixtures.summary.metrics.openTaskCount + 1,
      inProgressTaskCount: PreviewFixtures.summary.metrics.inProgressTaskCount,
      awaitingReviewTaskCount: PreviewFixtures.summary.metrics.awaitingReviewTaskCount + 1,
      inReviewTaskCount: PreviewFixtures.summary.metrics.inReviewTaskCount,
      arbitrationTaskCount: PreviewFixtures.summary.metrics.arbitrationTaskCount,
      blockedTaskCount: PreviewFixtures.summary.metrics.blockedTaskCount,
      completedTaskCount: PreviewFixtures.summary.metrics.completedTaskCount
    )
    let updatedSummary = replacingMetrics(PreviewFixtures.summary, with: metrics)
    let updatedDetail = SessionDetail(
      session: updatedSummary,
      agents: PreviewFixtures.agents,
      tasks: PreviewFixtures.tasks + [task],
      signals: PreviewFixtures.signals,
      observer: PreviewFixtures.observer,
      agentActivity: PreviewFixtures.agentActivity
    )

    store.applySelectedSessionSnapshot(
      sessionID: PreviewFixtures.summary.sessionId,
      detail: updatedDetail,
      timeline: store.timeline,
      timelineWindow: store.timelineWindow,
      showingCachedData: false,
      cancelPendingTimelineRefresh: false
    )

    #expect(store.contentUI.sessionDetail.selectedSessionTasks.last?.taskId == task.taskId)
    #expect(store.debugUISyncCount(for: .contentSessionDetail) == 1)
    #expect(store.debugUISyncCount(for: .contentChrome) == 0)
  }

  @Test("Sidebar summary counts reflect indexed session metrics")
  func sidebarSummaryCountsReflectIndexedSessionMetrics() async {
    let store = await makeBootstrappedStore()

    #expect(store.sidebarUI.projectCount == store.indexedProjectCount)
    #expect(store.sidebarUI.worktreeCount == store.indexedWorktreeCount)
    #expect(store.sidebarUI.sessionCount == store.indexedSessionCount)
    #expect(store.sidebarUI.openWorkCount == store.sessionIndex.totalOpenWorkCount)
    #expect(store.sidebarUI.blockedCount == store.sessionIndex.totalBlockedCount)
  }

  @Test("Daemon status churn resyncs sidebar summary counts")
  func daemonStatusChurnResyncsSidebarSummaryCounts() async {
    let store = await makeBootstrappedStore()
    guard let daemonStatus = store.daemonStatus else {
      Issue.record("Missing daemon status after bootstrap")
      return
    }

    store.debugResetUISyncCounts()
    store.daemonStatus = DaemonStatusReport(
      manifest: daemonStatus.manifest,
      launchAgent: daemonStatus.launchAgent,
      projectCount: daemonStatus.projectCount + 1,
      worktreeCount: daemonStatus.worktreeCount,
      sessionCount: daemonStatus.sessionCount,
      diagnostics: daemonStatus.diagnostics
    )

    #expect(store.debugUISyncCount(for: .sidebar) == 1)
  }

  func alternateSummary() -> SessionSummary {
    SessionSummary(
      projectId: PreviewFixtures.summary.projectId,
      projectName: PreviewFixtures.summary.projectName,
      projectDir: PreviewFixtures.summary.projectDir,
      contextRoot: PreviewFixtures.summary.contextRoot,
      sessionId: "session-alternate",
      worktreePath: PreviewFixtures.summary.worktreePath,
      sharedPath: PreviewFixtures.summary.sharedPath,
      originPath: PreviewFixtures.summary.originPath,
      branchRef: PreviewFixtures.summary.branchRef,
      title: "Alternate session",
      context: "A different selection target",
      status: PreviewFixtures.summary.status,
      createdAt: "2026-03-28T14:20:00Z",
      updatedAt: "2026-03-28T14:20:00Z",
      lastActivityAt: "2026-03-28T14:20:00Z",
      leaderId: PreviewFixtures.summary.leaderId,
      observeId: nil,
      pendingLeaderTransfer: nil,
      metrics: PreviewFixtures.summary.metrics
    )
  }

  private func toolbarGlobalActionState(
    for store: HarnessMonitorStore
  ) -> () -> (Bool, Bool) {
    {
      (
        store.contentUI.toolbar.isRefreshing,
        store.contentUI.toolbar.sleepPreventionEnabled
      )
    }
  }

  private func replacingMetrics(
    _ summary: SessionSummary,
    with metrics: SessionMetrics
  ) -> SessionSummary {
    SessionSummary(
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
      updatedAt: summary.updatedAt,
      lastActivityAt: summary.lastActivityAt,
      leaderId: summary.leaderId,
      observeId: summary.observeId,
      pendingLeaderTransfer: summary.pendingLeaderTransfer,
      externalOrigin: summary.externalOrigin,
      adoptedAt: summary.adoptedAt,
      metrics: metrics
    )
  }
}
