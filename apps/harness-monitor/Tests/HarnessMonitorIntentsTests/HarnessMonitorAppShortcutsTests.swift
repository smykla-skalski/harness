import AppIntents
import XCTest

@testable import HarnessMonitorIntents

final class HarnessMonitorAppShortcutsTests: XCTestCase {
  func testAppShortcutsExposesAllSpotlightSurfacedIntents() {
    let shortcuts = HarnessMonitorAppShortcuts.appShortcuts

    XCTAssertEqual(
      shortcuts.count,
      6,
      "AppShortcutsProvider count is a contract — adding or removing a shortcut changes how Spotlight surfaces Harness Monitor"
    )
  }
}
