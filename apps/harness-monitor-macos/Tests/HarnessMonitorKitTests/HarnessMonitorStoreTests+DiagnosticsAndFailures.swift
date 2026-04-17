import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreTests {
  @Test("Refreshing diagnostics loads live daemon diagnostics")
  func refreshDiagnosticsLoadsLiveDaemonDiagnostics() async {
    let store = await makeBootstrappedStore()

    store.diagnostics = nil

    await store.refreshDiagnostics()

    #expect(store.diagnostics?.workspace.databaseSizeBytes == 1_740_800)
    #expect(store.diagnostics?.recentEvents.count == 1)
  }

  @Test("Bootstrap failure sets the offline state and error")
  func bootstrapFailureSetsOfflineStateAndError() async {
    let daemon = FailingDaemonController(
      bootstrapError: DaemonControlError.harnessBinaryNotFound
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    #expect(
      store.connectionState
        == .offline(DaemonControlError.harnessBinaryNotFound.localizedDescription)
    )
    #expect(store.currentFailureFeedbackMessage != nil)
    #expect(store.health == nil)
  }

  @Test("Create task failure sets the last error")
  func createTaskFailureSetsLastError() async {
    let client = FailingHarnessClient()
    let daemon = RecordingDaemonController(client: client)
    let store = HarnessMonitorStore(daemonController: daemon)
    await store.bootstrap()
    await store.selectSession("sess-1")

    await store.createTask(title: "broken", context: nil, severity: .high)

    #expect(store.currentFailureFeedbackMessage != nil)
    #expect(store.isBusy == false)
  }

  @Test("Refresh with no client triggers bootstrap")
  func refreshWithNoClientTriggersBootstrap() async {
    let daemon = FailingDaemonController(
      bootstrapError: DaemonControlError.daemonDidNotStart
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.refresh()

    #expect(store.currentFailureFeedbackMessage != nil)
  }
}
