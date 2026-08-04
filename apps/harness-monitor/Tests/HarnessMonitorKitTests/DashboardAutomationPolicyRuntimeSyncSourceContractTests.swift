import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension SessionWindowFlowTests {
  @Test("App runtime service applies a restored automation kill switch without a dashboard")
  @MainActor
  func appRuntimeServiceAppliesRestoredAutomationKillSwitch() {
    let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .taskBoardBoardOnly)
    let center = AutomationPolicyCenter()
    let service = AutomationPolicyRuntimeService(policyCenter: center)
    store.globalPolicyCanvasWorkspace = PolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: "restored-kill-switch",
      canvases: [],
      spawnKillSwitch: true
    )

    service.start(store: store)

    #expect(center.isKillSwitchEngaged)
  }
}
