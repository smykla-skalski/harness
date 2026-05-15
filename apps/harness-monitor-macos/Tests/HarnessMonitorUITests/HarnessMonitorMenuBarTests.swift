import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

/// UI tests covering the dashboard-window menu affordances.
@MainActor
final class HarnessMonitorMenuBarTests: HarnessMonitorUITestCase {
  private static let previewScenarioKey = "HARNESS_MONITOR_PREVIEW_SCENARIO"
  private static let dashboardLandingScenario = "dashboard-landing"
  private static let previewSessionTitle = "Harness Monitor Cockpit"

  override nonisolated class var reuseLaunchedApp: Bool { true }

  func testWindowMenuOpensDashboardWindow() throws {
    let app = launch(mode: "preview")
    invokeMenuItem(in: app, menu: "Window", title: "Dashboard")

    let dashboardWindow = element(in: app, identifier: Accessibility.dashboardWindowRoot)
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) { dashboardWindow.exists },
      "Dashboard should appear after invoking Window > Dashboard"
    )
  }

  func testWindowMenuKeepsDashboardCommandAvailableAlongsideSystemItems() throws {
    let app = launch(mode: "preview")
    let windowMenu = app.menuBars.firstMatch.menuBarItems["Window"]
    XCTAssertTrue(
      windowMenu.waitForExistence(timeout: Self.uiTimeout),
      "Window menu must be reachable in the menu bar"
    )
    windowMenu.click()

    XCTAssertTrue(
      windowMenu.menuItems["Dashboard"].exists,
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
      submenu: "Recent Sessions",
      title: Self.previewSessionTitle
    )

    let sessionWindow = element(in: app, identifier: Accessibility.sessionWindowShell)
    XCTAssertTrue(
      waitForElement(sessionWindow, timeout: Self.uiTimeout),
      "File > Recent Sessions should reopen the selected recent session"
    )
  }
}
