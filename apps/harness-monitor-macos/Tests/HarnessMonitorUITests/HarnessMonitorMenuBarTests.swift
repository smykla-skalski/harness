import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

/// UI tests covering the consolidated Workspace window menu affordances.
@MainActor
final class HarnessMonitorMenuBarTests: HarnessMonitorUITestCase {
  // swiftlint:disable:next static_over_final_class
  override nonisolated class var reuseLaunchedApp: Bool { true }

  func testWindowMenuOpensWorkspaceWindow() throws {
    let app = launch(mode: "preview")
    invokeMenuItem(in: app, menu: "Window", title: "Workspace")

    let workspaceWindow = element(in: app, identifier: Accessibility.workspaceWindow)
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) { workspaceWindow.exists },
      "Workspace window should appear after invoking Window > Workspace"
    )
  }

  func testWindowMenuDoesNotExposeLegacyWindowItems() throws {
    let app = launch(mode: "preview")
    let windowMenu = app.menuBars.firstMatch.menuBarItems["Window"]
    XCTAssertTrue(windowMenu.waitForExistence(timeout: Self.uiTimeout))
    windowMenu.click()

    XCTAssertFalse(windowMenu.menuItems["Agents"].exists)
    XCTAssertFalse(windowMenu.menuItems["Decisions"].exists)
    windowMenu.typeKey(.escape, modifierFlags: [])
  }

  func testWindowMenuHasNoTabbingItems() throws {
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
      "Window menu must not surface 'Show Tab Bar' once tabbing is disabled per HIG"
    )
    XCTAssertFalse(
      mergeWindowsItem.exists,
      "Window menu must not surface 'Merge All Windows' once tabbing is disabled per HIG"
    )
    XCTAssertFalse(
      moveTabItem.exists,
      "Window menu must not surface 'Move Tab to New Window' once tabbing is disabled per HIG"
    )

    windowMenu.typeKey(.escape, modifierFlags: [])
  }
}
