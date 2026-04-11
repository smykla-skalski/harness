import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor content selection observation")
struct HarnessMonitorContentSelectionTests {
  @Test("Content toolbar metrics ignore bookmark and filter churn")
  func contentToolbarMetricsIgnoreBookmarkAndFilterChurn() async {
    let store = await makeBootstrappedStore()

    let bookmarkInvalidated = await didInvalidate(
      { store.contentUI.toolbar.toolbarMetrics },
      after: {
        store.bookmarkedSessionIds = ["bookmark-content"]
      }
    )
    #expect(bookmarkInvalidated == false)

    let filterInvalidated = await didInvalidate(
      { store.contentUI.toolbar.toolbarMetrics },
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
          store.contentUI.toolbar.toolbarMetrics,
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

  @Test("Content toolbar centerpiece ignores session selection churn")
  func contentToolbarCenterpieceIgnoresSessionSelectionChurn() async {
    let store = await makeBootstrappedStore()

    let didChange = await didInvalidate(
      {
        (
          store.contentUI.toolbar.toolbarMetrics,
          store.contentUI.toolbar.statusMessages,
          store.contentUI.toolbar.daemonIndicator
        )
      },
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

  @Test("Priming session selection updates inspector primary content")
  func primingSessionSelectionUpdatesInspectorPrimaryContent() async {
    let store = await makeBootstrappedStore()

    let didChange = await didInvalidate(
      { store.inspectorUI.primaryContent },
      after: {
        store.primeSessionSelection(PreviewFixtures.summary.sessionId)
      }
    )

    #expect(didChange)
  }

  @Test("Priming session selection does not resync content chrome before detail loads")
  func primingSessionSelectionSkipsContentChromeResync() async {
    let store = await makeBootstrappedStore()
    store.debugResetUISyncCounts()

    store.primeSessionSelection(PreviewFixtures.summary.sessionId)

    #expect(store.debugUISyncCount(for: .contentShell) == 0)
    #expect(store.debugUISyncCount(for: .contentSession) == 1)
    #expect(store.debugUISyncCount(for: .sidebar) == 1)
    #expect(store.debugUISyncCount(for: .inspector) == 1)
    #expect(store.debugUISyncCount(for: .contentChrome) == 0)
  }

  @Test("Inspector primary content ignores toast feedback churn")
  func inspectorPrimaryContentIgnoresToastFeedbackChurn() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let didChange = await didInvalidate(
      { store.inspectorUI.primaryContent },
      after: {
        store.presentSuccessFeedback("Task created")
      }
    )

    #expect(didChange == false)
  }

  @Test("Content session detail state tracks selected session detail and timeline")
  func contentSessionDetailStateTracksSelectedSessionDetailAndTimeline() async {
    let store = await makeBootstrappedStore()

    let didChange = await didInvalidate(
      {
        (
          store.contentUI.sessionDetail.selectedSessionDetail,
          store.contentUI.sessionDetail.timeline
        )
      },
      after: {
        await store.selectSession(PreviewFixtures.summary.sessionId)
      }
    )

    #expect(didChange)
    #expect(store.contentUI.sessionDetail.selectedSessionDetail == PreviewFixtures.detail)
    #expect(store.contentUI.sessionDetail.timeline == PreviewFixtures.timeline)
  }

  @Test("Hydrating the selected session detail skips shell resync when the summary is already selected")
  func selectedSessionHydrationSkipsShellResync() async {
    let store = await makeBootstrappedStore()
    store.primeSessionSelection(PreviewFixtures.summary.sessionId)
    store.debugResetUISyncCounts()

    store.selectedSession = PreviewFixtures.detail

    #expect(store.debugUISyncCount(for: .contentShell) == 0)
    #expect(store.debugUISyncCount(for: .contentChrome) == 1)
    #expect(store.debugUISyncCount(for: .contentSessionDetail) == 1)
    #expect(store.debugUISyncCount(for: .inspector) == 1)
  }

  @Test("Completing a selection load does not resync the root shell")
  func completingSelectionLoadSkipsShellResync() async {
    let store = await makeBootstrappedStore()
    store.primeSessionSelection(PreviewFixtures.summary.sessionId)
    store.debugResetUISyncCounts()

    store.isSelectionLoading = false

    #expect(store.debugUISyncCount(for: .contentShell) == 0)
    #expect(store.debugUISyncCount(for: .contentSession) == 1)
  }

  @Test("Selecting a session from the dashboard skips root shell sync")
  func selectingSessionSkipsRootShellSync() async {
    let store = await makeBootstrappedStore()
    store.debugResetUISyncCounts()

    await store.selectSession(PreviewFixtures.summary.sessionId)

    #expect(store.debugUISyncCount(for: .contentShell) == 0)
  }

  @Test("Priming current session does not invalidate content or inspector slices")
  func primingCurrentSessionDoesNotInvalidateContentOrInspectorSlices() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let contentChanged = await didInvalidate(
      {
        (
          store.contentUI.session.selectedSessionSummary,
          store.contentUI.session.isSelectionLoading,
          store.contentUI.toolbar.canNavigateBack,
          store.contentUI.toolbar.canNavigateForward,
          store.contentUI.chrome.sessionStatus
        )
      },
      after: {
        store.primeSessionSelection(PreviewFixtures.summary.sessionId)
      }
    )

    let inspectorChanged = await didInvalidate(
      { store.inspectorUI.primaryContent },
      after: {
        store.primeSessionSelection(PreviewFixtures.summary.sessionId)
      }
    )

    #expect(contentChanged == false)
    #expect(inspectorChanged == false)
    #expect(store.selectedSession == PreviewFixtures.detail)
    #expect(store.isSelectionLoading == false)
  }
}
