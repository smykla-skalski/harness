import Testing

@testable import HarnessKit

@MainActor
@Suite("Harness store confirmations")
struct HarnessStoreConfirmationTests {
  @Test("showConfirmation returns true when pending confirmation exists")
  func showConfirmationReflectsPendingState() {
    let store = HarnessStore(daemonController: RecordingDaemonController())
    #expect(store.showConfirmation == false)

    store.pendingConfirmation = .removeLaunchAgent
    #expect(store.showConfirmation == true)
  }

  @Test("Setting showConfirmation to false cancels pending confirmation")
  func showConfirmationSetFalseCancels() {
    let store = HarnessStore(daemonController: RecordingDaemonController())
    store.pendingConfirmation = .removeLaunchAgent

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

  @Test("Remove launch agent confirmation sets pending and confirm executes")
  func removeLaunchAgentConfirmationFlow() async {
    let controller = RecordingDaemonController(launchAgentInstalled: true)
    let store = HarnessStore(daemonController: controller)
    await store.bootstrap()

    store.requestRemoveLaunchAgentConfirmation()

    #expect(store.pendingConfirmation == .removeLaunchAgent)

    await store.confirmPendingAction()

    #expect(store.pendingConfirmation == nil)
    #expect(store.daemonStatus?.launchAgent.installed == false)
    #expect(store.lastAction == "Remove launch agent")
  }

  @Test("Cancel confirmation clears the pending state")
  func cancelConfirmationClearsPendingState() {
    let store = HarnessStore(daemonController: RecordingDaemonController())
    store.pendingConfirmation = .removeLaunchAgent

    store.cancelConfirmation()

    #expect(store.pendingConfirmation == nil)
  }

  @Test("Confirm with no pending action is a no-op")
  func confirmWithNoPendingActionIsNoOp() async {
    let store = HarnessStore(daemonController: RecordingDaemonController())
    #expect(store.pendingConfirmation == nil)

    await store.confirmPendingAction()

    #expect(store.lastAction == "")
  }
}
