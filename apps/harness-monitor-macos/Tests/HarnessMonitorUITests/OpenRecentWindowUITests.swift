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

  func testOpenRecentDoesNotShowCloseAfterPickCheckbox() {
    let app = launchPreviewOpenRecent()
    let toggle = app.checkBoxes["Close Open Recent after picking a session"].firstMatch

    XCTAssertFalse(
      toggle.waitForExistence(timeout: Self.fastActionTimeout),
      "Open Recent should not expose the close-after-pick checkbox."
    )
  }

  func testCloseAfterPickDismissesWelcomeWindowAfterSessionOpens() {
    let app = launchPreviewOpenRecent()
    let openRecentWindow = element(in: app, identifier: Accessibility.openRecentRoot)
    XCTAssertTrue(waitForElement(openRecentWindow, timeout: Self.uiTimeout))

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
      "Top session sidebar content should stay clear of the toolbar chrome "
        + "instead of rendering underneath it."
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !openRecentWindow.exists },
      "Open Recent should dismiss itself once the chosen session window opens."
    )
  }

  func testSessionWindowToolbarSeparatorIsSuppressed() {
    let app = launchPreviewOpenRecent()
    let openRecentWindow = element(in: app, identifier: Accessibility.openRecentRoot)
    XCTAssertTrue(waitForElement(openRecentWindow, timeout: Self.uiTimeout))

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

    let separatorSuppressed = element(
      in: app,
      identifier: Accessibility.sessionWindowToolbarSeparatorSuppressed
    )
    XCTAssertTrue(
      separatorSuppressed.waitForExistence(timeout: Self.actionTimeout),
      """
      Session window toolbar separator suppressor must be applied to prevent the seam between
      native toolbar glass and the sidebar
      """
    )
    XCTAssertEqual(
      separatorSuppressed.label,
      "suppressed",
      "Session window separator suppressor marker should report 'suppressed'"
    )
  }

  func testSessionWindowSplitColumnsStayInsideMinimumWindowWidth() {
    let app = launchPreviewOpenRecent(
      additionalEnvironment: [
        "HARNESS_MONITOR_UI_MAIN_WINDOW_WIDTH": "920",
        "HARNESS_MONITOR_UI_MAIN_WINDOW_HEIGHT": "620",
      ]
    )
    let openRecentWindow = element(in: app, identifier: Accessibility.openRecentRoot)
    XCTAssertTrue(waitForElement(openRecentWindow, timeout: Self.uiTimeout))

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
    XCTAssertTrue(waitUntil(timeout: Self.actionTimeout) { !openRecentWindow.exists })

    let window = mainWindow(in: app)
    let sidebar = element(in: app, identifier: Accessibility.sessionWindowSidebar)
    XCTAssertTrue(waitForElement(sidebar, timeout: Self.fastActionTimeout))

    let diagnostics = "window=\(window.frame) sidebar=\(sidebar.frame)"
    XCTAssertGreaterThanOrEqual(sidebar.frame.minX, window.frame.minX - 2, diagnostics)
    XCTAssertLessThanOrEqual(sidebar.frame.maxX, window.frame.maxX + 2, diagnostics)

    let leaderRow = element(
      in: app,
      identifier: "harness.session.window.sidebar.agent.leader-claude"
    )
    XCTAssertTrue(waitForElement(leaderRow, timeout: Self.fastActionTimeout))
    XCTAssertTrue(tapElementReliably(in: app, element: leaderRow))

    let detail = element(in: app, identifier: "harness.agent.detail.scroll")
    XCTAssertTrue(waitForElement(detail, timeout: Self.actionTimeout))
    let detailDiagnostics = "window=\(window.frame) detail=\(detail.frame)"
    XCTAssertGreaterThanOrEqual(detail.frame.minX, window.frame.minX - 2, detailDiagnostics)
    XCTAssertLessThanOrEqual(detail.frame.maxX, window.frame.maxX + 2, detailDiagnostics)
  }

  func testDisablingCloseAfterPickKeepsWelcomeWindowVisible() {
    let app = launchPreviewOpenRecent(
      additionalEnvironment: [
        HarnessMonitorSettingsUITestKeys.openRecentCloseAfterPickOverride: "0"
      ]
    )
    let openRecentWindow = element(in: app, identifier: Accessibility.openRecentRoot)
    XCTAssertTrue(waitForElement(openRecentWindow, timeout: Self.uiTimeout))

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

  private func launchPreviewOpenRecent(
    additionalEnvironment: [String: String] = [:]
  ) -> XCUIApplication {
    launch(
      mode: "preview",
      additionalEnvironment: [
        Self.previewScenarioKey: Self.dashboardLandingScenario
      ]
      .merging(additionalEnvironment) { _, newValue in newValue }
    )
  }
}
