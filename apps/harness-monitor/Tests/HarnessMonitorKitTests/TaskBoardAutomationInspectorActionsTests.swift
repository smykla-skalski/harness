import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Task-board automation inspector actions")
struct TaskBoardAutomationInspectorActionsTests {
  @Test("Inspector Stop discards a queued Run Once before daemon execution")
  func inspectorStopDiscardsQueuedRunOnce() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.stopGlobalStream()
    let state = TaskBoardAutomationInspectorState()
    let actions = TaskBoardAutomationInspectorActions(
      store: store,
      state: state,
      isActive: true
    )

    actions.enqueueControl(
      .runOnce,
      isPresentationCurrent: true,
      controlBlockedReason: nil
    )
    #expect(store.isTaskBoardRunOnceInFlight)

    actions.enqueueControl(
      .stop,
      isPresentationCurrent: true,
      controlBlockedReason: nil
    )
    #expect(!store.isTaskBoardRunOnceInFlight)

    let stopped = await waitUntil(timeout: .seconds(2)) {
      client.recordedCalls().contains(.stopTaskBoardOrchestrator)
    }
    let runOnceCalls = client.recordedCalls().filter {
      if case .runTaskBoardOrchestratorOnce = $0 { return true }
      return false
    }
    #expect(stopped)
    #expect(runOnceCalls.isEmpty)
  }
}
