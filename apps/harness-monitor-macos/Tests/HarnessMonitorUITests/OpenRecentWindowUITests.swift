import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

final class OpenRecentWindowUITests: HarnessMonitorUITestCase {
  private static let previewSessionID = "sess1234"
  private static let previewScenarioKey = "HARNESS_MONITOR_PREVIEW_SCENARIO"
  private static let dashboardLandingScenario = "dashboard-landing"

  func testOpenFolderRowRequestsNativeImporter() {
    let app = launch(mode: "empty")
    let root = element(in: app, identifier: Accessibility.openRecentRoot)
    XCTAssertTrue(root.waitForExistence(timeout: Self.fastActionTimeout))

    let actionState = element(in: app, identifier: Accessibility.openRecentActionState)
    XCTAssertTrue(actionState.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(actionState.label.contains("openFolder=0"))

    tapButton(in: app, identifier: Accessibility.openRecentOpenFolderButton)

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        actionState.label.contains("openFolder=1")
      },
      "Open Folder row did not invoke the SwiftUI action path"
    )
    XCTAssertTrue(
      waitUntil(timeout: 2.0) {
        app.sheets.firstMatch.exists
          || app.dialogs.firstMatch.exists
          || self.element(in: app, title: "Open").exists
      },
      "Open Folder row did not present the native file importer panel"
    )
    app.typeKey(.escape, modifierFlags: [])
  }

  func testCloseAfterPickToggleUsesCanonicalCopy() {
    let app = launchPreviewOpenRecent()
    let toggle = app.checkBoxes["Close Open Recent after picking a session"].firstMatch

    XCTAssertTrue(
      waitForElement(toggle, timeout: Self.fastActionTimeout),
      "Open Recent should expose the canonical close-after-pick toggle copy."
    )
    XCTAssertEqual(toggle.label, "Close Open Recent after picking a session")
  }

  func testCloseAfterPickDismissesWelcomeWindowAfterSessionOpens() {
    let app = launchPreviewOpenRecent()
    let openRecentWindow = element(in: app, identifier: Accessibility.openRecentRoot)
    XCTAssertTrue(waitForElement(openRecentWindow, timeout: Self.uiTimeout))
    let toggle = app.checkBoxes["Close Open Recent after picking a session"].firstMatch
    ensureCloseAfterPickEnabled(true, toggle: toggle)

    let sessionRowIdentifier = Accessibility.openRecentSessionRow(Self.previewSessionID)
    XCTAssertTrue(
      waitForButtonReady(
        in: app,
        identifier: sessionRowIdentifier,
        timeout: Self.actionTimeout
      )
    )

    tapButton(in: app, identifier: sessionRowIdentifier)

    let sessionWindow = element(in: app, identifier: Accessibility.sessionWindowShell)
    XCTAssertTrue(waitForElement(sessionWindow, timeout: Self.actionTimeout))
    let openedWindow = mainWindow(in: app)
    let topGap = sessionWindow.frame.minY - openedWindow.frame.minY
    XCTAssertLessThanOrEqual(
      topGap,
      140,
      "Session content should anchor near the top of the window instead of floating in the lower half."
    )
    let overviewRoute = element(in: app, identifier: Accessibility.sessionWindowRoute("overview"))
    XCTAssertTrue(waitForElement(overviewRoute, timeout: Self.fastActionTimeout))
    let overviewTopInset = overviewRoute.frame.minY - openedWindow.frame.minY
    XCTAssertGreaterThanOrEqual(
      overviewTopInset,
      80,
      "Top session sidebar content should stay clear of the toolbar chrome instead of rendering underneath it."
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !openRecentWindow.exists },
      "Open Recent should dismiss itself once the chosen session window opens."
    )
  }

  func testDisablingCloseAfterPickKeepsWelcomeWindowVisible() {
    let app = launchPreviewOpenRecent()
    let openRecentWindow = element(in: app, identifier: Accessibility.openRecentRoot)
    XCTAssertTrue(waitForElement(openRecentWindow, timeout: Self.uiTimeout))

    let toggle = app.checkBoxes["Close Open Recent after picking a session"].firstMatch
    ensureCloseAfterPickEnabled(false, toggle: toggle)

    let sessionRowIdentifier = Accessibility.openRecentSessionRow(Self.previewSessionID)
    XCTAssertTrue(
      waitForButtonReady(
        in: app,
        identifier: sessionRowIdentifier,
        timeout: Self.uiTimeout
      )
    )

    tapButton(in: app, identifier: sessionRowIdentifier)

    let sessionWindow = element(in: app, identifier: Accessibility.sessionWindowShell)
    XCTAssertTrue(waitForElement(sessionWindow, timeout: Self.uiTimeout))
    XCTAssertTrue(
      openRecentWindow.exists,
      "Disabling close-after-pick should keep the welcome window available after opening a session."
    )
  }

  private func checkboxValue(_ checkbox: XCUIElement) -> String {
    let rawValue = String(describing: checkbox.value ?? "")
    guard rawValue.hasPrefix("Optional("), rawValue.hasSuffix(")") else {
      return rawValue
    }
    return String(rawValue.dropFirst("Optional(".count).dropLast())
  }

  private func ensureCloseAfterPickEnabled(
    _ isEnabled: Bool,
    toggle: XCUIElement
  ) {
    XCTAssertTrue(waitForElement(toggle, timeout: Self.fastActionTimeout))
    let expectedValue = isEnabled ? "1" : "0"
    guard checkboxValue(toggle) != expectedValue else {
      return
    }
    toggle.click()
    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) { self.checkboxValue(toggle) == expectedValue },
      "Close-after-pick toggle should update to \(expectedValue)."
    )
  }

  private func launchPreviewOpenRecent() -> XCUIApplication {
    launch(
      mode: "preview",
      additionalEnvironment: [
        Self.previewScenarioKey: Self.dashboardLandingScenario
      ]
    )
  }
}
