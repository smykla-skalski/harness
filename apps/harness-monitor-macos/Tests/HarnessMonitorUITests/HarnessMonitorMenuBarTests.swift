import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

/// UI tests covering the macOS HIG menu bar restructure: the new Window menu
/// items must open the Agents and Decisions windows.
@MainActor
final class HarnessMonitorMenuBarTests: HarnessMonitorUITestCase {
  // swiftlint:disable:next static_over_final_class
  override nonisolated class var reuseLaunchedApp: Bool { true }

  func testWindowMenuOpensAgentsWindow() throws {
    let app = launch(mode: "preview")
    invokeMenuItem(in: app, menu: "Window", title: "Agents")

    let agentsWindow = element(in: app, identifier: Accessibility.agentsWindow)
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) { agentsWindow.exists },
      "Agents window should appear after invoking Window > Agents"
    )
  }

  func testWindowMenuOpensDecisionsWindow() throws {
    let app = launch(mode: "preview")
    invokeMenuItem(in: app, menu: "Window", title: "Decisions")

    let decisionsWindow = element(in: app, identifier: Accessibility.decisionsWindow)
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) { decisionsWindow.exists },
      "Decisions window should appear after invoking Window > Decisions"
    )
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
