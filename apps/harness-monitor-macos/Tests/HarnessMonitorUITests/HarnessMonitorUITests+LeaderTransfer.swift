import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension HarnessMonitorUITests {
  func testAgentsTaskDetailShowsCheckpointNotesAndSuggestedFix() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.taskUICard)

    let detailCard = element(in: app, identifier: Accessibility.agentsTaskCard)

    XCTAssertTrue(detailCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(app.staticTexts["Checkpoint"].exists)
    XCTAssertTrue(app.staticTexts["Suggested Fix"].exists)
    XCTAssertTrue(
      app.staticTexts["Merged daemon timeline entries with session checkpoints."].exists
    )
  }

  func testObserverPanelShowsTrackedAgentSessions() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.observeSummaryButton)

    let observerPanel = element(in: app, identifier: Accessibility.decisionsObserverPanel)

    XCTAssertTrue(observerPanel.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(app.staticTexts["Tracked Agent Sessions"].exists)
    XCTAssertTrue(app.staticTexts["Cursor 104"].exists)
  }

  func testEndSessionRequiresConfirmation() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    let endSessionButton = element(in: app, identifier: Accessibility.endSessionButton)
    XCTAssertTrue(endSessionButton.waitForExistence(timeout: Self.actionTimeout))
    tapElement(in: app, identifier: Accessibility.endSessionButton)

    XCTAssertTrue(app.buttons["End Session Now"].waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(app.staticTexts["End Session?"].exists)
    dismissConfirmationDialog(in: app)
  }

  func testSidebarSearchFieldFiltersSessions() throws {
    let app = launch(mode: "preview")

    let searchField = editableField(in: app, identifier: Accessibility.sidebarSearchField)
    let noMatches = app.staticTexts["No sessions match"]

    XCTAssertTrue(searchField.waitForExistence(timeout: Self.actionTimeout))

    tapElement(in: app, identifier: Accessibility.sidebarSearchField)
    app.typeText("zzznomatch")

    if !noMatches.waitForExistence(timeout: Self.actionTimeout) {
      attachWindowScreenshot(in: app, named: "sidebar-search-not-hittable")
    }
    XCTAssertTrue(noMatches.exists)
  }

  func testCommandFMovesFocusToNativeSidebarSearchField() throws {
    let app = launch(mode: "preview")

    let searchField = editableField(in: app, identifier: Accessibility.sidebarSearchField)
    let noMatches = app.staticTexts["No sessions match"]

    XCTAssertTrue(searchField.waitForExistence(timeout: Self.actionTimeout))

    tapPreviewSession(in: app)
    app.typeKey("f", modifierFlags: .command)
    app.typeText("zzznomatch")

    XCTAssertTrue(
      noMatches.waitForExistence(timeout: Self.actionTimeout),
      "Cmd-F should move focus to the native sidebar search field and filter sessions"
    )
  }

}
