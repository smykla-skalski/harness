import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorMenuBarExtraUITests: HarnessMonitorUITestCase {
  func testMenuBarExtraRoutesToWorkspaceSettingsAndSupervisorControls() {
    let app = launch(mode: "preview")

    openMenuBarExtra(for: app)
    assertMenuItemExists("Open Workspace")
    assertMenuItemExists("Settings...")
    assertMenuItemExists("Refresh")
    assertMenuItemExists("Enable Supervisor")

    tapMenuExtraItem("Open Workspace")
    let workspaceWindow = element(in: app, identifier: Accessibility.workspaceWindow)
    XCTAssertTrue(
      waitForElement(workspaceWindow, timeout: Self.uiTimeout),
      "Open Workspace should open the Workspace window"
    )

    openMenuBarExtra(for: app)
    tapMenuExtraItem("Settings...")
    let settingsRoot = element(in: app, identifier: Accessibility.settingsRoot)
    XCTAssertTrue(
      waitForElement(settingsRoot, timeout: Self.uiTimeout),
      "Settings... should open the Settings window"
    )

    openMenuBarExtra(for: app)
    assertMenuItemExists("Enable Supervisor")
    tapMenuExtraItem("Enable Supervisor")

    openMenuBarExtra(for: app)
    assertMenuItemExists("Disable Supervisor")
    assertMenuItemExists("Refresh")
  }

  private func openMenuBarExtra(for app: XCUIApplication) {
    app.activate()
    let candidates = menuBarExtraCandidates(in: app)
    for candidate in candidates where waitForElement(candidate, timeout: Self.actionTimeout) {
      candidate.click()
      return
    }
    XCTFail("Harness Monitor menu bar extra should appear")
  }

  private func menuBarExtraCandidates(in app: XCUIApplication) -> [XCUIElement] {
    let systemUIServer = XCUIApplication(bundleIdentifier: "com.apple.systemuiserver")
    let controlCenter = XCUIApplication(bundleIdentifier: "com.apple.controlcenter")
    let statusItemTitle = "Harness Monitor"
    let titlePredicate = NSPredicate(
      format: "identifier == %@ OR label == %@",
      Accessibility.menuBarExtra,
      statusItemTitle
    )
    return [
      app.descendants(matching: .any)
        .matching(identifier: Accessibility.menuBarExtra)
        .firstMatch,
      app.menuBars.firstMatch.menuBarItems[statusItemTitle].firstMatch,
      systemUIServer.descendants(matching: .any)
        .matching(identifier: Accessibility.menuBarExtra)
        .firstMatch,
      systemUIServer.menuBars.firstMatch.menuBarItems[statusItemTitle].firstMatch,
      systemUIServer.descendants(matching: .any)
        .matching(titlePredicate)
        .firstMatch,
      controlCenter.menuBars.firstMatch.menuBarItems[statusItemTitle].firstMatch,
      controlCenter.descendants(matching: .any)
        .matching(titlePredicate)
        .firstMatch,
    ]
  }

  private func assertMenuItemExists(
    _ title: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let item = menuItem(title)
    XCTAssertTrue(
      waitForElement(item, timeout: Self.actionTimeout),
      "\(title) should appear in the Harness Monitor menu bar extra",
      file: file,
      line: line
    )
  }

  private func tapMenuExtraItem(_ title: String) {
    let item = menuItem(title)
    XCTAssertTrue(
      waitForElement(item, timeout: Self.actionTimeout),
      "\(title) should appear in the Harness Monitor menu bar extra"
    )
    item.click()
  }

  private func menuItem(_ title: String) -> XCUIElement {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let systemUIServer = XCUIApplication(bundleIdentifier: "com.apple.systemuiserver")
    let controlCenter = XCUIApplication(bundleIdentifier: "com.apple.controlcenter")
    let appItem = app.menuItems[title].firstMatch
    if appItem.exists {
      return appItem
    }
    let systemItem = systemUIServer.menuItems[title].firstMatch
    if systemItem.exists {
      return systemItem
    }
    return controlCenter.menuItems[title].firstMatch
  }
}
