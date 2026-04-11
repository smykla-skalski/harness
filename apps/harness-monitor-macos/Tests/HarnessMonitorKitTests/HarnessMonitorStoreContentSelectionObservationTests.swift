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
          store.contentUI.shell.windowTitle,
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

  @Test("Content shell window title ignores last action churn")
  func contentShellWindowTitleIgnoresLastActionChurn() async {
    let store = await makeBootstrappedStore()

    let didChange = await didInvalidate(
      { store.contentUI.shell.windowTitle },
      after: {
        store.lastAction = "Refresh complete"
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

  @Test("Content UI selection state tracks session selection changes")
  func contentUISelectionStateTracksSessionSelectionChanges() async {
    let store = await makeBootstrappedStore()

    let didChange = await didInvalidate(
      { store.contentUI.shell.selectedSessionID },
      after: {
        await store.selectSession(PreviewFixtures.summary.sessionId)
      }
    )

    #expect(didChange)
    #expect(store.contentUI.shell.selectedSessionID == PreviewFixtures.summary.sessionId)
  }

  @Test("Priming session selection updates content shell selection state")
  func primingSessionSelectionUpdatesContentShellSelectionState() async {
    let store = await makeBootstrappedStore()

    let didChange = await didInvalidate(
      { store.contentUI.shell.selectedSessionID },
      after: {
        store.primeSessionSelection(PreviewFixtures.summary.sessionId)
      }
    )

    #expect(didChange)
    #expect(store.contentUI.shell.selectedSessionID == PreviewFixtures.summary.sessionId)
    #expect(store.contentUI.shell.isSelectionLoading)
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

  @Test("Inspector primary content ignores action status churn")
  func inspectorPrimaryContentIgnoresActionStatusChurn() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let didChange = await didInvalidate(
      { store.inspectorUI.primaryContent },
      after: {
        store.lastAction = "Task created"
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

  @Test("Priming current session does not invalidate content or inspector slices")
  func primingCurrentSessionDoesNotInvalidateContentOrInspectorSlices() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let contentChanged = await didInvalidate(
      {
        (
          store.contentUI.shell.selectedSessionID,
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
