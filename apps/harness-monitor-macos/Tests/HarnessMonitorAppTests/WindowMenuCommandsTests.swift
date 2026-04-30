import XCTest

@testable import HarnessMonitor

final class WindowMenuCommandsTests: XCTestCase {
  func testWorkspaceTitleStaysStable() {
    XCTAssertEqual(WindowMenuCommands.workspaceTitle, "Workspace")
  }

  func testMainTitleStaysStable() {
    XCTAssertEqual(WindowMenuCommands.mainTitle, "Main")
  }
}
