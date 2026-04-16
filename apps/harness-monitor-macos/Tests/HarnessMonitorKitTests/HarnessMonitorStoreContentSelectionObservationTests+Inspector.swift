import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorContentSelectionTests {
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

  @Test(
    "Content session detail presentation retains the current cockpit during same-session reloads")
  func contentSessionDetailPresentationRetainsCurrentCockpitDuringSameSessionReloads() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.selectedSession = nil
    store.timeline = []

    #expect(
      store.contentUI.session.selectedSessionSummary?.sessionId == PreviewFixtures.summary.sessionId
    )
    #expect(store.contentUI.sessionDetail.selectedSessionDetail == nil)
    #expect(store.contentUI.sessionDetail.presentedSessionDetail == PreviewFixtures.detail)
    #expect(store.contentUI.sessionDetail.presentedTimeline == PreviewFixtures.timeline)
  }

  @Test(
    "Selected-session summary refresh keeps the prior cockpit visible while fresh detail reloads")
  func selectedSessionSummaryRefreshKeepsCockpitVisibleWhileFreshDetailReloads() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let updatedSummary = SessionSummary(
      projectId: PreviewFixtures.summary.projectId,
      projectName: PreviewFixtures.summary.projectName,
      projectDir: PreviewFixtures.summary.projectDir,
      contextRoot: PreviewFixtures.summary.contextRoot,
      checkoutId: PreviewFixtures.summary.checkoutId,
      checkoutRoot: PreviewFixtures.summary.checkoutRoot,
      isWorktree: PreviewFixtures.summary.isWorktree,
      worktreeName: PreviewFixtures.summary.worktreeName,
      sessionId: PreviewFixtures.summary.sessionId,
      title: PreviewFixtures.summary.title,
      context: PreviewFixtures.summary.context,
      status: .active,
      createdAt: PreviewFixtures.summary.createdAt,
      updatedAt: "2026-04-15T17:32:00Z",
      lastActivityAt: "2026-04-15T17:32:00Z",
      leaderId: nil,
      observeId: PreviewFixtures.summary.observeId,
      pendingLeaderTransfer: nil,
      metrics: SessionMetrics(
        agentCount: 1,
        activeAgentCount: 0,
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        completedTaskCount: PreviewFixtures.summary.metrics.completedTaskCount
      )
    )

    store.refreshSelectedSessionIfSummaryChanged(sessions: [updatedSummary])

    #expect(store.contentUI.session.selectedSessionSummary == updatedSummary)
    #expect(store.selectedSession == nil)
    #expect(store.contentUI.sessionDetail.selectedSessionDetail == nil)
    #expect(store.contentUI.sessionDetail.presentedSessionDetail == PreviewFixtures.detail)
    #expect(store.contentUI.sessionDetail.presentedTimeline == PreviewFixtures.timeline)
    #expect(store.contentUI.session.isSelectionLoading)
  }

  @Test("Switching to a different session retains the prior cockpit until fresh detail arrives")
  func contentSessionDetailPresentationRetainsCockpitDuringSessionSwitch() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let nextSummary = alternateSummary()
    let didChange = store.sessionIndex.applySessionSummary(nextSummary)
    #expect(didChange)

    store.primeSessionSelection(nextSummary.sessionId)

    #expect(store.contentUI.session.selectedSessionSummary?.sessionId == nextSummary.sessionId)
    #expect(store.contentUI.sessionDetail.selectedSessionDetail == nil)
    #expect(store.contentUI.sessionDetail.presentedSessionDetail == PreviewFixtures.detail)
    #expect(store.contentUI.sessionDetail.presentedTimeline == PreviewFixtures.timeline)
  }

  @Test("Returning to the dashboard clears the retained cockpit")
  func contentSessionDetailPresentationClearsWhenSelectionReturnsToDashboard() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.primeSessionSelection(nil)

    #expect(store.contentUI.session.selectedSessionSummary == nil)
    #expect(store.contentUI.sessionDetail.selectedSessionDetail == nil)
    #expect(store.contentUI.sessionDetail.presentedSessionDetail == nil)
    #expect(store.contentUI.sessionDetail.presentedTimeline.isEmpty)
  }

  @Test(
    "Hydrating the selected session detail skips shell resync when the summary is already selected")
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

  @Test("Selected session summary metadata skips detail-driven surfaces once detail is loaded")
  func selectedSessionSummaryMetadataSkipsDetailDrivenSurfacesAfterHydration() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.debugResetUISyncCounts()

    let updatedSummary = SessionSummary(
      projectId: PreviewFixtures.summary.projectId,
      projectName: PreviewFixtures.summary.projectName,
      projectDir: PreviewFixtures.summary.projectDir,
      contextRoot: PreviewFixtures.summary.contextRoot,
      checkoutId: PreviewFixtures.summary.checkoutId,
      checkoutRoot: PreviewFixtures.summary.checkoutRoot,
      isWorktree: PreviewFixtures.summary.isWorktree,
      worktreeName: PreviewFixtures.summary.worktreeName,
      sessionId: PreviewFixtures.summary.sessionId,
      title: PreviewFixtures.summary.title,
      context: PreviewFixtures.summary.context,
      status: PreviewFixtures.summary.status,
      createdAt: PreviewFixtures.summary.createdAt,
      updatedAt: PreviewFixtures.summary.updatedAt,
      lastActivityAt: PreviewFixtures.summary.lastActivityAt,
      leaderId: PreviewFixtures.summary.leaderId,
      observeId: PreviewFixtures.summary.observeId,
      pendingLeaderTransfer: PreviewFixtures.summary.pendingLeaderTransfer,
      metrics: SessionMetrics(
        agentCount: PreviewFixtures.summary.metrics.agentCount + 1,
        activeAgentCount: PreviewFixtures.summary.metrics.activeAgentCount,
        openTaskCount: PreviewFixtures.summary.metrics.openTaskCount,
        inProgressTaskCount: PreviewFixtures.summary.metrics.inProgressTaskCount,
        blockedTaskCount: PreviewFixtures.summary.metrics.blockedTaskCount,
        completedTaskCount: PreviewFixtures.summary.metrics.completedTaskCount
      )
    )

    let didChange = store.sessionIndex.applySessionSummary(updatedSummary)

    #expect(didChange)
    #expect(store.debugUISyncCount(for: .contentToolbar) == 0)
    #expect(store.debugUISyncCount(for: .contentChrome) == 0)
    #expect(store.debugUISyncCount(for: .contentSession) == 0)
    #expect(store.debugUISyncCount(for: .inspector) == 0)
  }

  @Test("Selected session projection churn skips detail-driven surfaces after hydration")
  func selectedSessionProjectionChurnSkipsDetailDrivenSurfacesAfterHydration() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.debugResetUISyncCounts()

    let updatedSummary = SessionSummary(
      projectId: PreviewFixtures.summary.projectId,
      projectName: PreviewFixtures.summary.projectName,
      projectDir: PreviewFixtures.summary.projectDir,
      contextRoot: PreviewFixtures.summary.contextRoot,
      checkoutId: PreviewFixtures.summary.checkoutId,
      checkoutRoot: PreviewFixtures.summary.checkoutRoot,
      isWorktree: PreviewFixtures.summary.isWorktree,
      worktreeName: PreviewFixtures.summary.worktreeName,
      sessionId: PreviewFixtures.summary.sessionId,
      title: PreviewFixtures.summary.title,
      context: PreviewFixtures.summary.context,
      status: PreviewFixtures.summary.status,
      createdAt: PreviewFixtures.summary.createdAt,
      updatedAt: "2026-03-28T14:19:00Z",
      lastActivityAt: "2026-03-28T14:19:00Z",
      leaderId: PreviewFixtures.summary.leaderId,
      observeId: PreviewFixtures.summary.observeId,
      pendingLeaderTransfer: PreviewFixtures.summary.pendingLeaderTransfer,
      metrics: SessionMetrics(
        agentCount: PreviewFixtures.summary.metrics.agentCount,
        activeAgentCount: PreviewFixtures.summary.metrics.activeAgentCount,
        openTaskCount: PreviewFixtures.summary.metrics.openTaskCount + 1,
        inProgressTaskCount: PreviewFixtures.summary.metrics.inProgressTaskCount,
        blockedTaskCount: PreviewFixtures.summary.metrics.blockedTaskCount,
        completedTaskCount: PreviewFixtures.summary.metrics.completedTaskCount
      )
    )

    let didChange = store.sessionIndex.applySessionSummary(updatedSummary)

    #expect(didChange)
    #expect(store.debugUISyncCount(for: .contentToolbar) == 1)
    #expect(store.debugUISyncCount(for: .contentChrome) == 0)
    #expect(store.debugUISyncCount(for: .contentSession) == 0)
    #expect(store.debugUISyncCount(for: .inspector) == 0)
  }

  @Test(
    "Loading session summary metadata stays within the content loading surface before detail hydrates"
  )
  func loadingSessionSummaryMetadataStaysWithinContentLoadingSurface() async {
    let store = await makeBootstrappedStore()
    store.primeSessionSelection(PreviewFixtures.summary.sessionId)
    store.debugResetUISyncCounts()

    let updatedSummary = SessionSummary(
      projectId: PreviewFixtures.summary.projectId,
      projectName: PreviewFixtures.summary.projectName,
      projectDir: PreviewFixtures.summary.projectDir,
      contextRoot: PreviewFixtures.summary.contextRoot,
      checkoutId: PreviewFixtures.summary.checkoutId,
      checkoutRoot: PreviewFixtures.summary.checkoutRoot,
      isWorktree: PreviewFixtures.summary.isWorktree,
      worktreeName: PreviewFixtures.summary.worktreeName,
      sessionId: PreviewFixtures.summary.sessionId,
      title: PreviewFixtures.summary.title,
      context: PreviewFixtures.summary.context,
      status: PreviewFixtures.summary.status,
      createdAt: PreviewFixtures.summary.createdAt,
      updatedAt: PreviewFixtures.summary.updatedAt,
      lastActivityAt: PreviewFixtures.summary.lastActivityAt,
      leaderId: PreviewFixtures.summary.leaderId,
      observeId: PreviewFixtures.summary.observeId,
      pendingLeaderTransfer: PreviewFixtures.summary.pendingLeaderTransfer,
      metrics: SessionMetrics(
        agentCount: PreviewFixtures.summary.metrics.agentCount + 1,
        activeAgentCount: PreviewFixtures.summary.metrics.activeAgentCount,
        openTaskCount: PreviewFixtures.summary.metrics.openTaskCount,
        inProgressTaskCount: PreviewFixtures.summary.metrics.inProgressTaskCount,
        blockedTaskCount: PreviewFixtures.summary.metrics.blockedTaskCount,
        completedTaskCount: PreviewFixtures.summary.metrics.completedTaskCount
      )
    )

    let didChange = store.sessionIndex.applySessionSummary(updatedSummary)

    #expect(didChange)
    #expect(store.debugUISyncCount(for: .contentToolbar) == 0)
    #expect(store.debugUISyncCount(for: .contentChrome) == 0)
    #expect(store.debugUISyncCount(for: .contentSession) == 1)
    #expect(store.debugUISyncCount(for: .inspector) == 0)
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

  private func alternateSummary() -> SessionSummary {
    SessionSummary(
      projectId: PreviewFixtures.summary.projectId,
      projectName: PreviewFixtures.summary.projectName,
      projectDir: PreviewFixtures.summary.projectDir,
      contextRoot: PreviewFixtures.summary.contextRoot,
      checkoutId: PreviewFixtures.summary.checkoutId,
      checkoutRoot: PreviewFixtures.summary.checkoutRoot,
      isWorktree: PreviewFixtures.summary.isWorktree,
      worktreeName: PreviewFixtures.summary.worktreeName,
      sessionId: "session-alternate",
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
}
