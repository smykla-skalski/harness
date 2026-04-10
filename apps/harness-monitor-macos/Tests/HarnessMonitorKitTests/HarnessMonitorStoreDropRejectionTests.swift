import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task drop rejection feedback")
struct HarnessMonitorStoreDropRejectionTests {
  @Test("Drop task failure surfaces the last error to the inspector")
  func dropTaskFailureSetsLastError() async {
    let client = FailingHarnessClient()
    let daemon = RecordingDaemonController(client: client)
    let store = HarnessMonitorStore(daemonController: daemon)
    await store.bootstrap()
    await store.selectSession("sess-1")

    await store.dropTask(
      taskID: "task-1",
      target: .agent(agentId: "agent-1")
    )

    #expect(store.lastError != nil)
    #expect(store.isBusy == false)
  }

  @Test("Report drop rejection records a user-visible reason")
  func reportDropRejectionSetsLastError() async {
    let store = await makeBootstrappedStore()

    store.reportDropRejection("Cannot assign task: observer cannot take tasks.")

    #expect(store.lastError == "Cannot assign task: observer cannot take tasks.")
  }
}
