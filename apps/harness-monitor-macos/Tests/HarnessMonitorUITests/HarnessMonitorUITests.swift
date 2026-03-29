import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorUITests: HarnessMonitorUITestCase {
  func testPreviewModeLoadsDashboardAndOpensCockpit() throws {
    let app = launch(mode: "preview")

    let sessionRow = app.buttons.matching(identifier: Accessibility.previewSessionRow).firstMatch
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))

    tapButton(in: app, identifier: Accessibility.previewSessionRow)

    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch
    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.uiTimeout))
  }

  func testEmptyModeShowsOnboardingCard() throws {
    let app = launch(mode: "empty")

    XCTAssertTrue(
      app.staticTexts["Bring The Monitor Online"].waitForExistence(timeout: Self.uiTimeout)
    )
    XCTAssertTrue(app.buttons["Start Daemon"].exists)

    let sidebarEmptyState = element(in: app, identifier: Accessibility.sidebarEmptyState)
    let sidebarRoot = element(in: app, identifier: Accessibility.sidebarRoot)
    XCTAssertTrue(sidebarEmptyState.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sidebarRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertFalse(element(in: app, identifier: Accessibility.sidebarSessionList).exists)
    XCTAssertEqual(sidebarRoot.descendants(matching: .scrollView).count, 0)
    XCTAssertEqual(sidebarRoot.descendants(matching: .scrollBar).count, 0)

    let activeFilter = element(in: app, identifier: Accessibility.activeFilterButton)
    XCTAssertTrue(activeFilter.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(activeFilter.value as? String, "selected accent-on-light")
    XCTAssertEqual(
      element(in: app, identifier: Accessibility.allFilterButton).value as? String,
      "not selected ink-on-panel"
    )
    XCTAssertEqual(
      element(in: app, identifier: Accessibility.endedFilterButton).value as? String,
      "not selected ink-on-panel"
    )
  }

  func testToolbarOpensPreferencesSheet() throws {
    let app = launch(mode: "preview")

    let preferencesButton = toolbarButton(in: app, identifier: Accessibility.preferencesButton)
    XCTAssertTrue(preferencesButton.waitForExistence(timeout: Self.uiTimeout))

    preferencesButton.tap()

    XCTAssertTrue(
      app.staticTexts["Daemon Preferences"].waitForExistence(timeout: Self.uiTimeout)
    )
    XCTAssertTrue(element(in: app, identifier: Accessibility.preferencesRoot).exists)
  }

  func testObserveSummaryIsAvailableInSessionCockpit() throws {
    let app = launch(mode: "preview")

    let sessionRow = app.buttons.matching(identifier: Accessibility.previewSessionRow).firstMatch
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapButton(in: app, identifier: Accessibility.previewSessionRow)

    let tasks = app.staticTexts["Tasks"]
    let signals = app.staticTexts["Signals"]
    XCTAssertTrue(tasks.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(signals.waitForExistence(timeout: Self.uiTimeout))

    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch
    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.uiTimeout))
    tapButton(in: app, identifier: Accessibility.observeSummaryButton)

    XCTAssertTrue(tasks.exists)
    XCTAssertTrue(signals.exists)
  }

  func testToolbarSurvivesSidebarToggle() throws {
    let app = launch(mode: "preview")

    let sidebarToggle = sidebarToggleButton(in: app)
    let refreshButton = toolbarButton(in: app, identifier: Accessibility.refreshButton)
    let preferencesButton = toolbarButton(in: app, identifier: Accessibility.preferencesButton)
    let sessionRow = app.buttons.matching(identifier: Accessibility.previewSessionRow).firstMatch

    XCTAssertTrue(sidebarToggle.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(refreshButton.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(preferencesButton.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    let refreshToolbarButtons = app.toolbars.buttons.matching(
      identifier: Accessibility.refreshButton
    )
    let preferencesToolbarButtons = app.toolbars.buttons.matching(
      identifier: Accessibility.preferencesButton
    )
    let visibleRefreshButtons = refreshToolbarButtons
      .allElementsBoundByIndex
      .filter { $0.exists && $0.isHittable }
    let visiblePreferencesButtons = preferencesToolbarButtons
      .allElementsBoundByIndex
      .filter { $0.exists && $0.isHittable }
    XCTAssertGreaterThanOrEqual(visibleRefreshButtons.count, 1)
    XCTAssertGreaterThanOrEqual(visiblePreferencesButtons.count, 1)
    XCTAssertTrue(refreshButton.isHittable)
    XCTAssertTrue(preferencesButton.isHittable)

    sidebarToggle.tap()

    XCTAssertTrue(waitUntil { !sessionRow.exists || !sessionRow.isHittable })
    XCTAssertTrue(refreshButton.exists)
    XCTAssertTrue(preferencesButton.exists)
    XCTAssertTrue(refreshButton.isHittable)
    XCTAssertTrue(preferencesButton.isHittable)

    sidebarToggle.tap()

    XCTAssertTrue(waitUntil { sessionRow.exists && sessionRow.isHittable })
    XCTAssertTrue(refreshButton.isHittable)
    XCTAssertTrue(preferencesButton.isHittable)
    refreshButton.tap()
    XCTAssertTrue(preferencesButton.exists)
  }

  func testSessionActionsExposeActorPickerAndRemoveAgentFlow() throws {
    let app = launch(mode: "preview")

    let sessionRow = app.buttons.matching(identifier: Accessibility.previewSessionRow).firstMatch
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapButton(in: app, identifier: Accessibility.previewSessionRow)
    tapButton(in: app, identifier: Accessibility.workerAgentCard)

    let actorPicker = element(in: app, identifier: Accessibility.actionActorPicker)
    let removeAgentButton = element(in: app, identifier: Accessibility.removeAgentButton)

    XCTAssertTrue(actorPicker.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(removeAgentButton.waitForExistence(timeout: Self.uiTimeout))
  }

  func testTaskInspectorShowsCheckpointNotesAndSuggestedFix() throws {
    let app = launch(mode: "preview")

    let sessionRow = app.buttons.matching(identifier: Accessibility.previewSessionRow).firstMatch
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapButton(in: app, identifier: Accessibility.previewSessionRow)
    tapButton(in: app, identifier: Accessibility.taskUICard)

    let inspectorCard = element(in: app, identifier: Accessibility.taskInspectorCard)

    XCTAssertTrue(inspectorCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(app.staticTexts["Checkpoint"].exists)
    XCTAssertTrue(app.staticTexts["Suggested Fix"].exists)
    XCTAssertTrue(
      app.staticTexts["Merged daemon timeline entries with session checkpoints."].exists
    )
  }

  func testAgentInspectorShowsRuntimeCapabilitiesAndToolActivity() throws {
    let app = launch(mode: "preview")

    let sessionRow = app.buttons.matching(identifier: Accessibility.previewSessionRow).firstMatch
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapButton(in: app, identifier: Accessibility.previewSessionRow)
    tapButton(in: app, identifier: Accessibility.workerAgentCard)

    let inspectorCard = element(in: app, identifier: Accessibility.agentInspectorCard)
    let sendSignalButton = element(in: app, identifier: Accessibility.signalSendButton)

    XCTAssertTrue(inspectorCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sendSignalButton.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(app.staticTexts["Runtime Capabilities"].exists)
    XCTAssertTrue(app.staticTexts["Tool Activity"].exists)
    XCTAssertTrue(app.staticTexts["PreToolUse · 5s · context"].exists)
    XCTAssertTrue(app.staticTexts["Edit"].exists)
  }

  func testObserverInspectorShowsCycleHistoryAndTrackedSessions() throws {
    let app = launch(mode: "preview")

    let sessionRow = app.buttons.matching(identifier: Accessibility.previewSessionRow).firstMatch
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapButton(in: app, identifier: Accessibility.previewSessionRow)
    tapButton(in: app, identifier: Accessibility.observeSummaryButton)

    let inspectorCard = element(in: app, identifier: Accessibility.observerInspectorCard)

    XCTAssertTrue(inspectorCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(app.staticTexts["Cycle History"].exists)
    XCTAssertTrue(app.staticTexts["Tracked Agent Sessions"].exists)
    XCTAssertTrue(app.staticTexts["Cursor 104"].exists)
  }

  func testEndSessionRequiresConfirmation() throws {
    let app = launch(mode: "preview")

    let sessionRow = app.buttons.matching(identifier: Accessibility.previewSessionRow).firstMatch
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapButton(in: app, identifier: Accessibility.previewSessionRow)

    let endSessionButton = element(in: app, identifier: Accessibility.endSessionButton)
    XCTAssertTrue(endSessionButton.waitForExistence(timeout: Self.uiTimeout))
    tapElement(in: app, identifier: Accessibility.endSessionButton)

    XCTAssertTrue(app.buttons["End Session Now"].waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(app.staticTexts["End Session?"].exists)
    dismissConfirmationDialog(in: app)
  }

  func testPreferencesBackdropDismissesOverlay() throws {
    let app = launch(mode: "preview")

    let preferencesButton = toolbarButton(in: app, identifier: Accessibility.preferencesButton)
    XCTAssertTrue(preferencesButton.waitForExistence(timeout: Self.uiTimeout))
    preferencesButton.tap()

    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    let preferencesPanel = frameElement(in: app, identifier: Accessibility.preferencesPanel)

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(preferencesPanel.waitForExistence(timeout: Self.uiTimeout))

    tapOutsidePreferencesPanel(in: app)

    XCTAssertTrue(waitUntil { !preferencesRoot.exists })
  }

  func testRemoveLaunchAgentRequiresConfirmation() throws {
    let app = launch(mode: "preview")

    let preferencesButton = toolbarButton(in: app, identifier: Accessibility.preferencesButton)
    XCTAssertTrue(preferencesButton.waitForExistence(timeout: Self.uiTimeout))
    preferencesButton.tap()

    let remove = element(in: app, identifier: Accessibility.removeLaunchAgentButton)
    XCTAssertTrue(remove.waitForExistence(timeout: Self.uiTimeout))
    tapElement(in: app, identifier: Accessibility.removeLaunchAgentButton)

    XCTAssertTrue(
      app.buttons["Remove Launch Agent Now"].waitForExistence(timeout: Self.uiTimeout)
    )
    XCTAssertTrue(app.staticTexts["Remove Launch Agent?"].exists)
    dismissConfirmationDialog(in: app)
  }
}
