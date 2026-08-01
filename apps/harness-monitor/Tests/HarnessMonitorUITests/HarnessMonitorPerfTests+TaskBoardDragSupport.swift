import XCTest

@MainActor
extension HarnessMonitorPerfTests {
  func waitForTaskBoardOrder(
    _ itemIDs: [String],
    in orderMarker: XCUIElement,
    timeout: TimeInterval = HarnessMonitorPerfTests.actionTimeout
  ) -> Bool {
    return waitUntil(timeout: timeout, pollInterval: Self.fastPollInterval) {
      self.markerText(orderMarker)
        .split(separator: ",")
        .map(String.init)
        .starts(with: itemIDs)
    }
  }

  func waitForTaskBoardOrderEnding(
    _ itemIDs: [String],
    in orderMarker: XCUIElement,
    timeout: TimeInterval = HarnessMonitorPerfTests.actionTimeout
  ) -> Bool {
    waitUntil(timeout: timeout, pollInterval: Self.fastPollInterval) {
      self.markerText(orderMarker)
        .split(separator: ",")
        .map(String.init)
        .suffix(itemIDs.count)
        .elementsEqual(itemIDs)
    }
  }

  func taskBoardCard(_ itemID: String, in app: XCUIApplication) -> XCUIElement {
    app.buttons
      .matching(identifier: "harness.task-board.api-item.\(itemID)")
      .firstMatch
  }

  func taskBoardLane(_ lane: String, in app: XCUIApplication) -> XCUIElement {
    element(in: app, identifier: "harness.task-board.column.\(lane)")
  }

  func taskBoardLaneOrder(_ lane: String, in app: XCUIApplication) -> XCUIElement {
    element(in: app, identifier: "harness.task-board.column.\(lane).order")
  }
}

@MainActor
struct TaskBoardDragContext {
  let backlogOrder: XCUIElement
  let todoOrder: XCUIElement
  let planningOrder: XCUIElement
  let optimisticSettle: XCUIElement
  let orchestratorStart: XCUIElement
}
