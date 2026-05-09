import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

/// UI tests covering the welcome-window menu affordances.
@MainActor
final class HarnessMonitorMenuBarTests: HarnessMonitorUITestCase {
  private static let previewScenarioKey = "HARNESS_MONITOR_PREVIEW_SCENARIO"
  private static let dashboardLandingScenario = "dashboard-landing"
  private static let previewSessionTitle = "Harness Monitor Cockpit"

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

  func testWindowMenuKeepsOpenRecentCommandAvailableAlongsideSystemItems() throws {
    let app = launch(mode: "preview")
    let windowMenu = app.menuBars.firstMatch.menuBarItems["Window"]
    XCTAssertTrue(
      windowMenu.waitForExistence(timeout: Self.uiTimeout),
      "Window menu must be reachable in the menu bar"
    )
    windowMenu.click()

    XCTAssertTrue(
      windowMenu.menuItems["Open Recent Session"].exists,
      "The app-owned window command should stay available while native window items remain system-owned"
    )

    windowMenu.typeKey(.escape, modifierFlags: [])
  }

  func testFileMenuReopensRecentSessionFromSubmenu() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        Self.previewScenarioKey: Self.dashboardLandingScenario
      ]
    )
    invokeNestedMenuItem(
      in: app,
      menu: "File",
      submenu: "Open Recent Session",
      title: Self.previewSessionTitle
    )

    let sessionWindow = element(in: app, identifier: Accessibility.sessionWindowShell)
    XCTAssertTrue(
      waitForElement(sessionWindow, timeout: Self.uiTimeout),
      "File > Open Recent Session should reopen the selected recent session"
    )
  }
}
