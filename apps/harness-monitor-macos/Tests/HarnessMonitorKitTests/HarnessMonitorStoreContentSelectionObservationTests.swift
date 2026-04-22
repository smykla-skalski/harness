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

  @Test("Content shell state ignores inspector selection churn")
  func contentShellStateIgnoresInspectorSelectionChurn() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let didChange = await didInvalidate(
      {
        (
          toolbarGlobalActionState(for: store)(),
          store.contentUI.shell.connectionState
        )
      },
      after: {
        store.inspect(agentID: PreviewFixtures.agents[1].agentId)
      }
    )

    #expect(didChange == false)
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
    #expect(store.debugUISyncCount(for: .inspector) == 0)
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
    #expect(store.debugUISyncCount(for: .inspector) == 0)
  }

  @Test("Persisted data availability churn skips shell session dashboard and inspector")
  func persistedDataAvailabilityChurnSkipsShellSessionDashboardAndInspector() async {
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
    #expect(store.debugUISyncCount(for: .inspector) == 0)
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

  @Test("Priming session selection defers inspector primary content until detail loads")
  func primingSessionSelectionDefersInspectorPrimaryContentUntilDetailLoads() async {
    let store = await makeBootstrappedStore()

    let didChange = await didInvalidate(
      { store.inspectorUI.primaryContent },
      after: {
        store.primeSessionSelection(PreviewFixtures.summary.sessionId)
      }
    )

    #expect(didChange == false)
  }

  @Test("Priming session selection does not resync content chrome before detail loads")
  func primingSessionSelectionSkipsContentChromeResync() async {
    let store = await makeBootstrappedStore()
    store.debugResetUISyncCounts()

    store.primeSessionSelection(PreviewFixtures.summary.sessionId)

    #expect(store.debugUISyncCount(for: .contentShell) == 0)
    #expect(store.debugUISyncCount(for: .contentSession) == 1)
    #expect(store.debugUISyncCount(for: .sidebar) == 1)
    #expect(store.debugUISyncCount(for: .inspector) == 0)
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
}
