import AppKit
import XCTest

@testable import HarnessMonitorUIPreviewable

@MainActor
final class TaskBoardNativeListTunerTests: XCTestCase {
  func testRegistrationSuppressesNativeFeedbackWithoutReplacingTableOwners() {
    let tableView = NSTableView()
    let owner = TableOwner()
    tableView.delegate = owner
    tableView.dataSource = owner
    tableView.draggingDestinationFeedbackStyle = .regular
    tableView.selectionHighlightStyle = .regular
    tableView.focusRingType = .default

    let coordinator = TaskBoardNativeListCoordinator()
    coordinator.register(tableView, lane: .todo)

    XCTAssertEqual(tableView.draggingDestinationFeedbackStyle, .none)
    XCTAssertEqual(tableView.selectionHighlightStyle, .none)
    XCTAssertEqual(tableView.focusRingType, .none)
    XCTAssertTrue(tableView.delegate === owner)
    XCTAssertTrue(tableView.dataSource === owner)

    coordinator.beginDrag()
    XCTAssertEqual(tableView.draggingDestinationFeedbackStyle, .none)

    coordinator.updateGapTarget(.todo, reason: "test-target")
    XCTAssertEqual(tableView.draggingDestinationFeedbackStyle, .none)

    coordinator.clearGapTarget(.todo, reason: "test-exit")
    XCTAssertEqual(tableView.draggingDestinationFeedbackStyle, .none)
  }

  func testRevealSucceedsOnlyAfterTheRequestedRowExists() async {
    let tableView = NSTableView()
    let owner = TableOwner(rowCount: 1)
    tableView.dataSource = owner
    tableView.reloadData()
    let coordinator = TaskBoardNativeListCoordinator()
    coordinator.register(tableView, lane: .todo)

    let existingRow = await coordinator.reveal(row: 0, in: .todo)
    let missingRow = await coordinator.reveal(
      row: 1,
      in: .todo,
      remainingAttempts: 1
    )
    let missingLane = await coordinator.reveal(
      row: 0,
      in: .planning,
      remainingAttempts: 1
    )

    XCTAssertTrue(existingRow)
    XCTAssertFalse(missingRow)
    XCTAssertFalse(missingLane)
  }
}

private final class TableOwner: NSObject, NSTableViewDelegate, NSTableViewDataSource {
  let rowCount: Int

  init(rowCount: Int = 0) {
    self.rowCount = rowCount
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    rowCount
  }
}
