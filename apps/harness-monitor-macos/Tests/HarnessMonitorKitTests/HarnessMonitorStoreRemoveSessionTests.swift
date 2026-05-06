import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor remove-session actions")
struct HarnessMonitorStoreRemoveSessionTests {
  @Test("Request remove-session confirmation uses the control-plane actor")
  func requestRemoveSessionConfirmationUsesControlPlaneActor() async {
    let store = await makeBootstrappedStore()

    store.requestRemoveSessionConfirmation(sessionID: PreviewFixtures.summary.sessionId)

    #expect(
      store.pendingConfirmation
        == .removeSession(
          sessionID: PreviewFixtures.summary.sessionId,
          actorID: "harness-app"
        )
    )
  }

  @Test("Request multi remove-session confirmation uses the control-plane actor")
  func requestRemoveSessionsConfirmationUsesControlPlaneActor() async {
    let client = makeMultiSessionClient()
    let store = await makeBootstrappedStore(client: client)

    store.requestRemoveSessionConfirmation(
      sessionIDs: [
        PreviewFixtures.summary.sessionId,
        PreviewFixtures.signalRegressionSecondarySummary.sessionId,
      ]
    )

    #expect(
      store.pendingConfirmation
        == .removeSessions(
          sessionIDs: [
            PreviewFixtures.summary.sessionId,
            PreviewFixtures.signalRegressionSecondarySummary.sessionId,
          ],
          actorID: "harness-app"
        )
    )
  }

  @Test("Confirm pending remove-session action clears the cockpit and prunes navigation")
  func confirmPendingRemoveSessionClearsCockpitAndPrunesNavigation() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.navigationBackStack = [PreviewFixtures.summary.sessionId, "sess-older", nil]
    store.navigationForwardStack = [PreviewFixtures.summary.sessionId]

    store.requestRemoveSessionConfirmation(sessionID: PreviewFixtures.summary.sessionId)
    await store.confirmPendingAction()

    #expect(store.pendingConfirmation == nil)
    #expect(store.selectedSessionID == nil)
    #expect(store.selectedSession == nil)
    #expect(store.contentUI.session.selectedSessionSummary == nil)
    #expect(store.contentUI.sessionDetail.presentedSessionDetail == nil)
    #expect(store.sessions.isEmpty)
    #expect(store.currentSuccessFeedbackMessage == "Remove session")
    #expect(store.navigationBackStack.allSatisfy { $0 != PreviewFixtures.summary.sessionId })
    #expect(store.navigationForwardStack.allSatisfy { $0 != PreviewFixtures.summary.sessionId })
    #expect(
      client.recordedCalls()
        == [
          .removeSession(
            sessionID: PreviewFixtures.summary.sessionId,
            actor: "harness-app"
          )
        ]
    )
  }

  @Test("Late push updates do not resurrect a removed session")
  func latePushUpdatesDoNotResurrectARemovedSession() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let staleProjects = store.projects

    store.requestRemoveSessionConfirmation(sessionID: PreviewFixtures.summary.sessionId)
    await store.confirmPendingAction()

    store.applyGlobalPushEvent(
      .sessionUpdated(
        recordedAt: "2026-04-01T10:00:00Z",
        sessionId: PreviewFixtures.summary.sessionId,
        detail: PreviewFixtures.sessionDetail(session: PreviewFixtures.summary),
        timeline: PreviewFixtures.timeline
      )
    )
    store.applyGlobalPushEvent(
      .sessionsUpdated(
        recordedAt: "2026-04-01T10:00:01Z",
        projects: staleProjects,
        sessions: [PreviewFixtures.summary]
      )
    )

    #expect(store.sessions.isEmpty)
    #expect(store.selectedSessionID == nil)
    #expect(store.contentUI.session.selectedSessionSummary == nil)
  }

  @Test("Stale refresh snapshots do not resurrect a removed session")
  func staleRefreshSnapshotsDoNotResurrectARemovedSession() async {
    let client = RecordingHarnessClient()
    client.archiveSessionMutatesReadSnapshots = false
    let store = await makeBootstrappedStore(client: client)

    store.requestRemoveSessionConfirmation(sessionID: PreviewFixtures.summary.sessionId)
    await store.confirmPendingAction()

    #expect(store.sessions.isEmpty)
    #expect(store.projects.isEmpty)
    #expect(store.selectedSessionID == nil)
    #expect(store.contentUI.session.selectedSessionSummary == nil)
  }

  @Test("Preview removal does not auto-reselect the ready session after refresh")
  func previewRemovalDoesNotAutoReselectReadySessionAfterRefresh() async {
    let client = PreviewHarnessClient(fixtures: .populated, isLaunchAgentInstalled: true)
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

    #expect(store.selectedSessionID == PreviewFixtures.summary.sessionId)
    #expect(
      store.contentUI.session.selectedSessionSummary?.sessionId == PreviewFixtures.summary.sessionId
    )

    store.requestRemoveSessionConfirmation(sessionID: PreviewFixtures.summary.sessionId)
    await store.confirmPendingAction()
    await Task.yield()
    await Task.yield()

    #expect(store.sessions.isEmpty)
    #expect(store.projects.isEmpty)
    #expect(store.selectedSessionID == nil)
    #expect(store.selectedSession == nil)
    #expect(store.contentUI.session.selectedSessionSummary == nil)
    #expect(store.contentUI.sessionDetail.presentedSessionDetail == nil)
  }

  @Test("Captured confirmation still removes the session after dialog dismissal clears store state")
  func capturedConfirmationSurvivesDialogDismissalRace() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    let pendingConfirmation = HarnessMonitorStore.PendingConfirmation.removeSession(
      sessionID: PreviewFixtures.summary.sessionId,
      actorID: "harness-app"
    )
    store.pendingConfirmation = pendingConfirmation

    store.cancelConfirmation()
    await store.confirmPendingAction(pendingConfirmation)

    #expect(store.sessions.isEmpty)
    #expect(store.selectedSessionID == nil)
    #expect(
      client.recordedCalls()
        == [
          .removeSession(
            sessionID: PreviewFixtures.summary.sessionId,
            actor: "harness-app"
          )
        ]
    )
  }

  @Test("Daemon missing-session archive replies still remove the stale session locally")
  func missingSessionArchiveReplyStillRemovesSessionLocally() async {
    let client = RecordingHarnessClient()
    client.archiveSessionMutatesReadSnapshots = false
    client.configureArchiveSessionError(
      HarnessMonitorAPIError.server(
        code: 400,
        message:
          "session not active: session '\(PreviewFixtures.summary.sessionId)' not found"
      )
    )
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.requestRemoveSessionConfirmation(sessionID: PreviewFixtures.summary.sessionId)
    await store.confirmPendingAction()

    #expect(store.sessions.isEmpty)
    #expect(store.projects.isEmpty)
    #expect(store.selectedSessionID == nil)
    #expect(store.selectedSession == nil)
    #expect(store.contentUI.session.selectedSessionSummary == nil)
    #expect(store.contentUI.sessionDetail.presentedSessionDetail == nil)
    #expect(store.currentSuccessFeedbackMessage == "Remove session")
    #expect(
      client.recordedCalls()
        == [
          .removeSession(
            sessionID: PreviewFixtures.summary.sessionId,
            actor: "harness-app"
          )
        ]
    )
  }

  @Test("Removing a session clears stale pending workspace create anchors")
  func removingSessionClearsPendingWorkspaceCreateAnchor() async {
    let store = await makeBootstrappedStore()
    store.requestWorkspaceCreateEntryPoint(.agent, sessionID: PreviewFixtures.summary.sessionId)

    #expect(store.pendingWorkspaceCreateSessionID == PreviewFixtures.summary.sessionId)

    store.requestRemoveSessionConfirmation(sessionID: PreviewFixtures.summary.sessionId)
    await store.confirmPendingAction()

    #expect(store.pendingWorkspaceCreateSessionID == nil)
  }

  @Test("Confirm pending multi remove-session action removes every selected session")
  func confirmPendingRemoveSessionsRemovesEverySelectedSession() async {
    let client = makeMultiSessionClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.navigationBackStack = [
      PreviewFixtures.summary.sessionId,
      PreviewFixtures.signalRegressionSecondarySummary.sessionId,
      nil,
    ]
    store.navigationForwardStack = [PreviewFixtures.signalRegressionSecondarySummary.sessionId]

    store.requestRemoveSessionConfirmation(
      sessionIDs: [
        PreviewFixtures.summary.sessionId,
        PreviewFixtures.signalRegressionSecondarySummary.sessionId,
      ]
    )
    await store.confirmPendingAction()

    #expect(store.pendingConfirmation == nil)
    #expect(store.sessions.isEmpty)
    #expect(store.projects.isEmpty)
    #expect(store.selectedSessionID == nil)
    #expect(store.selectedSession == nil)
    #expect(store.contentUI.session.selectedSessionSummary == nil)
    #expect(store.contentUI.sessionDetail.presentedSessionDetail == nil)
    #expect(store.currentSuccessFeedbackMessage == "Removed 2 sessions")
    #expect(
      store.navigationBackStack.allSatisfy {
        $0 != PreviewFixtures.summary.sessionId
          && $0 != PreviewFixtures.signalRegressionSecondarySummary.sessionId
      }
    )
    #expect(
      store.navigationForwardStack.allSatisfy {
        $0 != PreviewFixtures.summary.sessionId
          && $0 != PreviewFixtures.signalRegressionSecondarySummary.sessionId
      }
    )
    #expect(
      client.recordedCalls()
        == [
          .removeSession(
            sessionID: PreviewFixtures.summary.sessionId,
            actor: "harness-app"
          ),
          .removeSession(
            sessionID: PreviewFixtures.signalRegressionSecondarySummary.sessionId,
            actor: "harness-app"
          ),
        ]
    )
  }

  private func makeMultiSessionClient() -> RecordingHarnessClient {
    let client = RecordingHarnessClient()
    client.configureSessions(
      summaries: PreviewFixtures.signalRegressionSessions,
      detailsByID: [
        PreviewFixtures.summary.sessionId: PreviewFixtures.detail,
        PreviewFixtures.signalRegressionSecondarySummary.sessionId:
          PreviewFixtures.signalRegressionSecondaryDetail,
      ],
      timelinesBySessionID: [
        PreviewFixtures.summary.sessionId: PreviewFixtures.pagedTimeline,
        PreviewFixtures.signalRegressionSecondarySummary.sessionId: PreviewFixtures.timeline,
      ]
    )
    return client
  }
}
