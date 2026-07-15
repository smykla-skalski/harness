import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Task-board approval grant refresh")
struct TaskBoardApprovalGrantsViewTests {
  @Test("Offline refresh does not queue work or start loading")
  func offlineRefreshDoesNotQueueWorkOrStartLoading() async {
    let store = await makeBootstrappedStore()
    store.connectionState = .offline("daemon down")
    let view = approvalGrantsView(store: store)
    let state = view.state
    var submittedItems: [HarnessMonitorAsyncWorkQueue.WorkItem] = []

    view.enqueueRefresh { submittedItems.append($0) }

    #expect(submittedItems.isEmpty)
    #expect(!state.isLoading)
  }

  @Test("Online refresh queues work and starts loading")
  func onlineRefreshQueuesWorkAndStartsLoading() async {
    let store = await makeBootstrappedStore()
    store.connectionState = .online
    let view = approvalGrantsView(store: store)
    let state = view.state
    var submittedItems: [HarnessMonitorAsyncWorkQueue.WorkItem] = []

    view.enqueueRefresh { submittedItems.append($0) }

    #expect(submittedItems.count == 1)
    #expect(state.isLoading)
  }

  private func approvalGrantsView(store: HarnessMonitorStore) -> TaskBoardApprovalGrantsView {
    TaskBoardApprovalGrantsView(
      store: store,
      workspace: nil,
      refreshID: TaskBoardApprovalGrantRefreshID(
        heldIntentIDs: [],
        activeCanvasID: nil,
        activeRevision: nil,
        lastRunID: nil,
        evaluationFingerprint: nil,
        localGeneration: 0
      ),
      isDisabled: false
    )
  }
}
