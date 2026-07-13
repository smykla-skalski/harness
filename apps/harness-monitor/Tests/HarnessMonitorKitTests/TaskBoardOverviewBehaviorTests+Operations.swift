import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
extension TaskBoardOverviewBehaviorTests {
  @Test("Dispatch presentation filters host project types off main")
  func dispatchPresentationFiltersHostProjectTypes() async {
    let worker = TaskBoardOperationsDispatchPresentationWorker()
    let accepted = taskBoardItem(
      id: "accepted",
      status: .todo,
      targetProjectTypes: ["swift"]
    )
    let rejected = taskBoardItem(
      id: "rejected",
      status: .todo,
      targetProjectTypes: ["rust"]
    )

    let presentation = await worker.compute(
      input: TaskBoardOperationsDispatchPresentationInput(
        taskBoardItems: [accepted, rejected],
        localHostProjectTypes: ["swift"]
      )
    )

    #expect(presentation.dispatchableItems.map(\.id) == ["accepted"])
    #expect(presentation.item(id: "accepted")?.id == "accepted")
    #expect(presentation.item(id: "rejected") == nil)
    #expect(!presentation.didFilterOut)
  }

  @Test("Dispatch presentation matches visible board ordering")
  func dispatchPresentationMatchesVisibleBoardOrdering() async {
    let worker = TaskBoardOperationsDispatchPresentationWorker()
    let high = taskBoardItem(id: "high", status: .todo, priority: .critical)
    let low = taskBoardItem(id: "low", status: .todo, priority: .low)
    let done = taskBoardItem(id: "done", status: .done)
    let deleted = taskBoardItem(
      id: "deleted",
      status: .todo,
      deletedAt: "2026-05-14T10:02:00Z"
    )

    let presentation = await worker.compute(
      input: TaskBoardOperationsDispatchPresentationInput(
        taskBoardItems: [done, low, deleted, high],
        localHostProjectTypes: []
      )
    )

    #expect(presentation.dispatchableItems.map(\.id) == ["high", "low"])
    #expect(!presentation.didFilterOut)
  }

  @Test("Hidden board items do not report a host mismatch")
  func hiddenBoardItemsDoNotReportHostMismatch() async {
    let worker = TaskBoardOperationsDispatchPresentationWorker()
    let done = taskBoardItem(
      id: "done",
      status: .done,
      targetProjectTypes: ["unavailable"]
    )

    let presentation = await worker.compute(
      input: TaskBoardOperationsDispatchPresentationInput(
        taskBoardItems: [done],
        localHostProjectTypes: ["local"]
      )
    )

    #expect(presentation.dispatchableItems.isEmpty)
    #expect(!presentation.didFilterOut)
  }
}
