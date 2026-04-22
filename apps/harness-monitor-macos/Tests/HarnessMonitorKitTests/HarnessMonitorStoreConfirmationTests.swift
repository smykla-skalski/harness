import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store confirmations")
struct HarnessMonitorStoreConfirmationTests {
  @Test("showConfirmation returns true when pending confirmation exists")
  func showConfirmationReflectsPendingState() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    #expect(store.showConfirmation == false)

    store.pendingConfirmation = .endSession(sessionID: "sess-1", actorID: "agent-1")
    #expect(store.showConfirmation == true)
  }

  @Test("Setting showConfirmation to false cancels pending confirmation")
  func showConfirmationSetFalseCancels() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.pendingConfirmation = .removeAgent(
      sessionID: "sess-1",
      agentID: "agent-2",
      actorID: "agent-1"
    )

    store.showConfirmation = false

    #expect(store.pendingConfirmation == nil)
    #expect(store.showConfirmation == false)
  }

  @Test("Setting showConfirmation to true is a no-op")
  func showConfirmationSetTrueIsNoOp() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    #expect(store.pendingConfirmation == nil)

    store.showConfirmation = true

    #expect(store.pendingConfirmation == nil)
  }

  @Test("Confirm pending end-session action clears the pending state")
  func confirmPendingEndSessionClearsPendingState() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.pendingConfirmation = .endSession(sessionID: "sess-1", actorID: "agent-1")

    await store.confirmPendingAction()

    #expect(store.pendingConfirmation == nil)
  }

  @Test("Cancel confirmation clears the pending state")
  func cancelConfirmationClearsPendingState() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.pendingConfirmation = .endSession(sessionID: "sess-1", actorID: "agent-1")

    store.cancelConfirmation()

    #expect(store.pendingConfirmation == nil)
  }

  @Test("Confirm with no pending action is a no-op")
  func confirmWithNoPendingActionIsNoOp() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    #expect(store.pendingConfirmation == nil)

    await store.confirmPendingAction()

    #expect(store.currentSuccessFeedbackMessage == nil)
  }

  @Test("Awaiting-leader task creation uses the control-plane actor")
  func awaitingLeaderTaskCreationUsesControlPlaneActor() async {
    let client = actorlessActionClient()
    let store = await actorlessActionStore(client: client)

    let created = await store.createTask(
      title: "Seed control-plane task",
      context: "Fresh sessions should accept task seeding before any leader joins.",
      severity: .medium
    )

    #expect(created)
    #expect(store.areSelectedSessionActionsAvailable)
    #expect(store.selectedSessionActionUnavailableMessage == nil)
    #expect(store.areSelectedLeaderActionsAvailable == false)
    #expect(store.selectedLeaderActionUnavailableMessage == expectedLeaderlessActionMessage)
    #expect(
      client.recordedCalls()
        == [
          .createTask(
            sessionID: PreviewFixtures.emptyCockpitSummary.sessionId,
            title: "Seed control-plane task",
            context: "Fresh sessions should accept task seeding before any leader joins.",
            severity: .medium,
            actor: "harness-app"
          )
        ]
    )
  }

  @Test("Awaiting-leader control-plane session actions stay available")
  func awaitingLeaderControlPlaneSessionActionsStayAvailable() async {
    let client = actorlessActionClient()
    let store = await actorlessActionStore(client: client)

    let observed = await store.observeSelectedSession()

    #expect(observed)
    #expect(store.currentSuccessFeedbackMessage == "Observe session")

    store.requestEndSelectedSessionConfirmation()

    #expect(
      store.pendingConfirmation
        == .endSession(
          sessionID: PreviewFixtures.emptyCockpitSummary.sessionId,
          actorID: "harness-app"
        )
    )

    await store.confirmPendingAction()

    #expect(store.pendingConfirmation == nil)
    #expect(
      client.recordedCalls()
        == [
          .observeSession(
            sessionID: PreviewFixtures.emptyCockpitSummary.sessionId,
            actor: "harness-app"
          ),
          .endSession(
            sessionID: PreviewFixtures.emptyCockpitSummary.sessionId,
            actor: "harness-app"
          ),
        ]
    )
    #expect(store.selectedSession?.session.status == .ended)
    #expect(store.currentSuccessFeedbackMessage == "End session")
  }

  @Test("Default task actions keep the control-plane actor")
  func defaultTaskActionsKeepTheControlPlaneActor() async {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)

    await store.createTask(
      title: "Use the live leader",
      context: "Default actor resolution should not send harness-app.",
      severity: .medium
    )

    #expect(
      client.recordedCalls()
        == [
          .createTask(
            sessionID: PreviewFixtures.summary.sessionId,
            title: "Use the live leader",
            context: "Default actor resolution should not send harness-app.",
            severity: .medium,
            actor: "harness-app"
          )
        ]
    )
  }
}
