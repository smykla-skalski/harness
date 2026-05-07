import XCTest

@testable import HarnessMonitor

final class WindowMenuCommandsTests: XCTestCase {
  func testOpenRecentSessionTitleStaysStable() {
    XCTAssertEqual(WindowMenuCommands.mainTitle, "Open Recent Session")
  }

  func testNewTabCommandUsesCommandTContract() {
    XCTAssertEqual(WindowMenuCommands.newTabTitle, "New Tab")
    XCTAssertEqual(WindowMenuCommands.newTabShortcut, "t")
  }
}
