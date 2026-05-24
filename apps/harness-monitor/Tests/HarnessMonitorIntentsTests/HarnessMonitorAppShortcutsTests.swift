import AppIntents
import XCTest

@testable import HarnessMonitorIntents

final class HarnessMonitorAppShortcutsTests: XCTestCase {
  func testAppShortcutsExposesAllSpotlightSurfacedIntents() {
    let shortcuts = HarnessMonitorAppShortcuts.appShortcuts

    XCTAssertEqual(
      shortcuts.count,
      10,
      "AppShortcutsProvider count is a contract - adding or removing a shortcut changes how Spotlight surfaces Harness Monitor"
    )
  }

  func testAppShortcutsStayAtOrBelowAppleSoftLimit() {
    let shortcuts = HarnessMonitorAppShortcuts.appShortcuts

    XCTAssertLessThanOrEqual(
      shortcuts.count,
      10,
      "Apple's documented soft limit for AppShortcutsProvider is 10 - extra shortcuts may not surface in Spotlight"
    )
  }
}
