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
    let titlePredicate = NSPredicate(
      format: "identifier == %@ OR label == %@",
      Accessibility.menuBarExtra,
      "Harness Monitor"
    )
    return [
      app.descendants(matching: .any)
        .matching(identifier: Accessibility.menuBarExtra)
        .firstMatch,
      systemUIServer.descendants(matching: .any)
        .matching(identifier: Accessibility.menuBarExtra)
        .firstMatch,
      systemUIServer.descendants(matching: .any)
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
    let appItem = app.menuItems[title].firstMatch
    if appItem.exists {
      return appItem
    }
    return systemUIServer.menuItems[title].firstMatch
  }
}
