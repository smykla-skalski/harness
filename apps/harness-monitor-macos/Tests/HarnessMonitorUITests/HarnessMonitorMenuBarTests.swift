import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

/// UI tests covering the welcome-window menu affordances.
@MainActor
final class HarnessMonitorMenuBarTests: HarnessMonitorUITestCase {
  // swiftlint:disable:next static_over_final_class
  override nonisolated class var reuseLaunchedApp: Bool { true }

  func testWindowMenuOpensOpenRecentWindow() throws {
    let app = launch(mode: "preview")
    invokeMenuItem(in: app, menu: "Window", title: "Open Recent Session")

    let openRecentWindow = element(in: app, identifier: Accessibility.openRecentRoot)
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) { openRecentWindow.exists },
      "Open Recent should appear after invoking Window > Open Recent Session"
    )
  }

  func testWelcomeWindowDoesNotExposeTabbingItems() throws {
    let app = launch(mode: "preview")
    let windowMenu = app.menuBars.firstMatch.menuBarItems["Window"]
    XCTAssertTrue(
      windowMenu.waitForExistence(timeout: Self.uiTimeout),
      "Window menu must be reachable in the menu bar"
    )
    windowMenu.click()

    let tabBarItem = windowMenu.menuItems["Show Tab Bar"]
    let mergeWindowsItem = windowMenu.menuItems["Merge All Windows"]
    let moveTabItem = windowMenu.menuItems["Move Tab to New Window"]

    XCTAssertFalse(
      tabBarItem.exists,
      "The welcome window opts out of native tabbing and should not expose a tab bar"
    )
    XCTAssertFalse(
      mergeWindowsItem.exists,
      "The welcome window opts out of native tabbing and should not expose merge commands"
    )
    XCTAssertFalse(
      moveTabItem.exists,
      "The welcome window opts out of native tabbing and should not expose tab extraction"
    )

    windowMenu.typeKey(.escape, modifierFlags: [])
  }
}
