import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreTaskBoardPositioningTests {
  @Test("A cross-lane retry fails closed when the source card moved")
  func crossLaneMoveRejectsConcurrentSourceLaneChange() async {
    let client = RecordingHarnessClient()
    let moving = taskBoardItem(id: "moving", status: .todo)
    let anchor = taskBoardItem(id: "anchor", status: .planning)
    client.configureTaskBoardItems([moving, anchor])
    client.taskBoardPositionError = concurrentModificationError
    client.taskBoardPositionErrorRemainingUses = 1
    client.taskBoardPositionItemsAfterError = [
      taskBoardItem(id: "moving", status: .inProgress),
      anchor,
    ]
    let store = await makeBootstrappedStore(client: client)

    let success = await store.positionTaskBoardItem(
      id: "moving",
      sourceStatus: .todo,
      destinationStatus: .planning,
      placement: .relative(relative(after: "anchor"))
    )

    #expect(success == false)
    let setCalls = client.recordedCalls().filter {
      if case .setTaskBoardItemPosition = $0 { return true }
      return false
    }
    #expect(setCalls.count == 1)
    #expect(
      store.globalTaskBoardItems.first(where: { $0.id == "moving" })?.status == .inProgress
    )
    #expect(
      store.currentFailureFeedbackMessage
        == "Cannot update task board position: the board changed before the action completed"
    )
  }
}
