import Testing

@testable import HarnessKit

@MainActor
@Suite("Harness store confirmations")
struct HarnessStoreConfirmationTests {
  @Test("showConfirmation returns true when pending confirmation exists")
  func showConfirmationReflectsPendingState() {
    let store = HarnessStore(daemonController: RecordingDaemonController())
    #expect(store.showConfirmation == false)

    store.pendingConfirmation = .endSession(sessionID: "sess-1", actorID: "agent-1")
    #expect(store.showConfirmation == true)
  }

  @Test("Setting showConfirmation to false cancels pending confirmation")
  func showConfirmationSetFalseCancels() {
    let store = HarnessStore(daemonController: RecordingDaemonController())
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
    let store = HarnessStore(daemonController: RecordingDaemonController())
    #expect(store.pendingConfirmation == nil)

    store.showConfirmation = true

    #expect(store.pendingConfirmation == nil)
  }

  @Test("Confirm pending end-session action clears the pending state")
  func confirmPendingEndSessionClearsPendingState() async {
    let store = HarnessStore(daemonController: RecordingDaemonController())
    store.pendingConfirmation = .endSession(sessionID: "sess-1", actorID: "agent-1")

    await store.confirmPendingAction()

    #expect(store.pendingConfirmation == nil)
  }

  @Test("Cancel confirmation clears the pending state")
  func cancelConfirmationClearsPendingState() {
    let store = HarnessStore(daemonController: RecordingDaemonController())
    store.pendingConfirmation = .endSession(sessionID: "sess-1", actorID: "agent-1")

    store.cancelConfirmation()

    #expect(store.pendingConfirmation == nil)
  }

  @Test("Confirm with no pending action is a no-op")
  func confirmWithNoPendingActionIsNoOp() async {
    let store = HarnessStore(daemonController: RecordingDaemonController())
    #expect(store.pendingConfirmation == nil)

    await store.confirmPendingAction()

    #expect(store.lastAction.isEmpty)
  }
}
