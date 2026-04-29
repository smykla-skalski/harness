import XCTest

@testable import HarnessMonitor

final class WindowMenuCommandsTests: XCTestCase {
  func testDecisionsTitleOmitsCountWhenQueueIsEmpty() {
    XCTAssertEqual(WindowMenuCommands.decisionsTitle(for: 0), "Decisions")
    XCTAssertEqual(WindowMenuCommands.decisionsTitle(for: -1), "Decisions")
  }

  func testDecisionsTitleIncludesPendingCount() {
    XCTAssertEqual(WindowMenuCommands.decisionsTitle(for: 1), "Decisions (1)")
    XCTAssertEqual(WindowMenuCommands.decisionsTitle(for: 3), "Decisions (3)")
  }
}
