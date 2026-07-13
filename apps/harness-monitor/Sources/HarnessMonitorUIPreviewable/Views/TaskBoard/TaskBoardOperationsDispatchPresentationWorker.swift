import Foundation
import HarnessMonitorKit
import OSLog

struct TaskBoardOperationsDispatchPresentationInput: Equatable, Sendable {
  let taskBoardItems: [TaskBoardItem]
  let localHostProjectTypes: [String]
}

struct TaskBoardOperationsDispatchPresentation: Equatable, Sendable {
  static let empty = Self(
    dispatchableItems: [],
    dispatchableItemsByID: [:],
    didFilterOut: false
  )

  let dispatchableItems: [TaskBoardItem]
  let dispatchableItemsByID: [String: TaskBoardItem]
  let didFilterOut: Bool

  func item(id: String) -> TaskBoardItem? {
    dispatchableItemsByID[id]
  }
}

actor TaskBoardOperationsDispatchPresentationWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )

  private var cachedInput: TaskBoardOperationsDispatchPresentationInput?
  private var cachedOutput = TaskBoardOperationsDispatchPresentation.empty

  func compute(
    input: TaskBoardOperationsDispatchPresentationInput
  ) -> TaskBoardOperationsDispatchPresentation {
    guard input != cachedInput else {
      return cachedOutput
    }

    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(
      "task_board_dispatch.presentation.compute",
      id: signpostID,
      "items=\(input.taskBoardItems.count, privacy: .public)"
    )
    defer {
      Self.signposter.endInterval(
        "task_board_dispatch.presentation.compute",
        interval,
        "dispatchable=\(self.cachedOutput.dispatchableItems.count, privacy: .public)"
      )
    }

    cachedInput = input
    let visibleItems = TaskBoardVisibleItems.sorted(input.taskBoardItems)
    let dispatchableItems = TaskBoardHostMachine.dispatchableItems(
      visibleItems,
      machineProjectTypes: input.localHostProjectTypes
    )
    cachedOutput = TaskBoardOperationsDispatchPresentation(
      dispatchableItems: dispatchableItems,
      dispatchableItemsByID: Dictionary(
        uniqueKeysWithValues: dispatchableItems.map { ($0.id, $0) }
      ),
      didFilterOut: !visibleItems.isEmpty && dispatchableItems.isEmpty
    )
    return cachedOutput
  }

  func waitForIdle() async {}
}
