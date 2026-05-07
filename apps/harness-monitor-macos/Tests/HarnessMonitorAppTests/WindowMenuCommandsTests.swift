import XCTest

@testable import HarnessMonitor

final class WindowMenuCommandsTests: XCTestCase {
  func testWelcomeRecentsTitleStaysStable() {
    XCTAssertEqual(WindowMenuCommands.mainTitle, "Welcome Recents")
  }
}
