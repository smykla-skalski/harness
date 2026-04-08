import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility
private let textSizeOverrideKey = "HARNESS_MONITOR_TEXT_SIZE_OVERRIDE"

@MainActor
final class HarnessMonitorUITests: HarnessMonitorUITestCase {
  func testPreviewModeLoadsDashboardAndOpensCockpit() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    if !sessionRow.waitForExistence(timeout: Self.uiTimeout) {
      attachWindowScreenshot(in: app, named: "preview-session-row-missing")
    }
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))

    tapPreviewSession(in: app)

    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch
    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.uiTimeout))
  }

  func testEmptyModeShowsOnboardingCard() throws {
    let app = launch(mode: "empty")

    XCTAssertTrue(
      app.staticTexts["Bring Harness Monitor Online"].waitForExistence(timeout: Self.uiTimeout)
    )
    XCTAssertTrue(element(in: app, identifier: Accessibility.sidebarStartButton).exists)

    let sidebarEmptyState = app.staticTexts[Accessibility.sidebarEmptyStateTitle]
    let sidebarRoot = element(in: app, identifier: Accessibility.sidebarRoot)
    XCTAssertTrue(sidebarEmptyState.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sidebarRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertFalse(element(in: app, identifier: Accessibility.sidebarSessionList).exists)
    XCTAssertGreaterThanOrEqual(sidebarRoot.descendants(matching: .scrollView).count, 1)
    XCTAssertEqual(sidebarRoot.descendants(matching: .scrollBar).count, 0)

    let activeFilter = button(in: app, identifier: Accessibility.activeFilterButton)
    let allFilter = button(in: app, identifier: Accessibility.allFilterButton)
    let endedFilter = button(in: app, identifier: Accessibility.endedFilterButton)
    let sortSegment = button(
      in: app,
      identifier: Accessibility.sidebarSortSegment("recentActivity")
    )
    let focusSegment = button(
      in: app,
      identifier: Accessibility.sidebarFocusChip("all")
    )
    let sessionFilterGroup = element(in: app, identifier: Accessibility.sessionFilterGroup)

    XCTAssertTrue(activeFilter.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(allFilter.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(endedFilter.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sortSegment.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(focusSegment.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionFilterGroup.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(sessionFilterGroup.label, "status=active")
  }

  func testDegradedPersistenceModeShowsWarningAndHidesPersistenceControls() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_FORCE_PERSISTENCE_FAILURE": "1"]
    )

    let persistenceBanner = element(in: app, identifier: Accessibility.persistenceBanner)
    let sessionRow = previewSessionTrigger(in: app)
    let clearSearchHistoryButton = element(
      in: app,
      identifier: Accessibility.sidebarClearSearchHistoryButton
    )

    XCTAssertTrue(persistenceBanner.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertFalse(clearSearchHistoryButton.exists)

    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.taskUICard)

    let notesUnavailable = element(in: app, identifier: Accessibility.taskNotesUnavailable)
    XCTAssertTrue(notesUnavailable.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertFalse(element(in: app, identifier: Accessibility.taskNoteField).exists)
    XCTAssertFalse(element(in: app, identifier: Accessibility.taskNoteAddButton).exists)
  }

  func testObserveSummaryIsAvailableInSessionCockpit() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapPreviewSession(in: app)

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

  func testExistingSignalsRemainVisibleAfterSwitchingSessions() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "signal-regression"]
    )

    let primarySession = previewSessionTrigger(in: app)
    let secondarySession = sessionTrigger(
      in: app,
      identifier: Accessibility.signalRegressionSecondarySessionRow
    )
    let primarySignal = button(in: app, identifier: Accessibility.previewSignalCard)
    let noSignalsState = app.staticTexts["No signals"]
    let signalInspector = element(in: app, identifier: Accessibility.signalInspectorCard)

    XCTAssertTrue(primarySession.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(secondarySession.waitForExistence(timeout: Self.uiTimeout))

    if !primarySignal.waitForExistence(timeout: 1.5) {
      tapPreviewSession(in: app)
    }

    XCTAssertTrue(
      primarySignal.waitForExistence(timeout: Self.uiTimeout),
      "Existing session signals should be visible when the cockpit opens"
    )
    tapButton(in: app, identifier: Accessibility.previewSignalCard)
    XCTAssertTrue(
      signalInspector.waitForExistence(timeout: Self.uiTimeout),
      "Selecting a signal row should open the signal inspector"
    )

    tapSession(in: app, identifier: Accessibility.signalRegressionSecondarySessionRow)
    XCTAssertTrue(
      noSignalsState.waitForExistence(timeout: Self.uiTimeout),
      "A different session without signals should replace the previous signal list"
    )

    tapPreviewSession(in: app)
    XCTAssertTrue(
      primarySignal.waitForExistence(timeout: Self.uiTimeout),
      "Existing signals should still be visible after switching away and back"
    )
  }

  func testToolbarSurvivesSidebarToggle() throws {
    let app = launch(mode: "preview")

    let sidebarToggle = sidebarToggleButton(in: app)
    let refreshButton = toolbarButton(in: app, identifier: Accessibility.refreshButton)
    let preferencesButton = toolbarButton(in: app, identifier: Accessibility.preferencesButton)
    let sidebarShellQuery = app.otherElements
      .matching(identifier: Accessibility.sidebarShellFrame)
    let sidebarShell = sidebarShellQuery.firstMatch

    XCTAssertTrue(sidebarToggle.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(refreshButton.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(preferencesButton.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sidebarShell.waitForExistence(timeout: Self.uiTimeout))
    let initialSidebarWidth = sidebarShell.frame.width
    XCTAssertGreaterThan(initialSidebarWidth, 200)
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

    XCTAssertTrue(
      waitUntil {
        guard let collapsedSidebar = sidebarShellQuery.allElementsBoundByIndex.first else {
          return true
        }
        return collapsedSidebar.frame.width < max(120, initialSidebarWidth * 0.5)
      }
    )
    XCTAssertTrue(refreshButton.exists)
    XCTAssertTrue(preferencesButton.exists)
    XCTAssertTrue(refreshButton.isHittable)
    XCTAssertTrue(preferencesButton.isHittable)

    sidebarToggle.tap()

    XCTAssertTrue(
      waitUntil {
        guard let restoredSidebar = sidebarShellQuery.allElementsBoundByIndex.first else {
          return false
        }
        return restoredSidebar.frame.width > (initialSidebarWidth * 0.75)
      }
    )
    XCTAssertTrue(refreshButton.isHittable)
    XCTAssertTrue(preferencesButton.isHittable)
    refreshButton.tap()
    XCTAssertTrue(preferencesButton.exists)
  }

  func testSessionActionsExposeActorPickerAndRemoveAgentFlow() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.workerAgentCard)

    let actorPicker = element(in: app, identifier: Accessibility.actionActorPicker)
    let removeAgentButton = element(in: app, identifier: Accessibility.removeAgentButton)

    XCTAssertTrue(actorPicker.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(removeAgentButton.waitForExistence(timeout: Self.uiTimeout))
  }

  func testTaskInspectorShowsCheckpointNotesAndSuggestedFix() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapPreviewSession(in: app)
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

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapPreviewSession(in: app)
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

  func testAgentInspectorKeepsNativeFormControlsUsableAtLargestTextSize() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [textSizeOverrideKey: "6"]
    )

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.workerAgentCard)

    let appChromeState = element(in: app, identifier: Accessibility.appChromeState)
    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    let actorPicker = popUpButton(in: app, identifier: Accessibility.actionActorPicker)
    let commandField = editableField(in: app, identifier: Accessibility.signalCommandField)
    let messageField = editableField(in: app, identifier: Accessibility.signalMessageField)

    XCTAssertTrue(appChromeState.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(actorPicker.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(commandField.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(messageField.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(
      appChromeState.label,
      "contentChrome=native, interactiveRows=button, controlGlass=native"
    )

    for _ in 0..<4 {
      if actorPicker.isHittable, commandField.isHittable, messageField.isHittable {
        break
      }
      dragUp(in: app, element: inspectorRoot, distanceRatio: 0.18)
    }

    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        actorPicker.isHittable && commandField.isHittable && messageField.isHittable
      }
    )
  }

  func testObserverInspectorShowsCycleHistoryAndTrackedSessions() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.observeSummaryButton)

    let inspectorCard = element(in: app, identifier: Accessibility.observerInspectorCard)

    XCTAssertTrue(inspectorCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(app.staticTexts["Cycle History"].exists)
    XCTAssertTrue(app.staticTexts["Tracked Agent Sessions"].exists)
    XCTAssertTrue(app.staticTexts["Cursor 104"].exists)
  }

  func testEndSessionRequiresConfirmation() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapPreviewSession(in: app)

    let endSessionButton = element(in: app, identifier: Accessibility.endSessionButton)
    XCTAssertTrue(endSessionButton.waitForExistence(timeout: Self.uiTimeout))
    tapElement(in: app, identifier: Accessibility.endSessionButton)

    XCTAssertTrue(app.buttons["End Session Now"].waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(app.staticTexts["End Session?"].exists)
    dismissConfirmationDialog(in: app)
  }

  func testSidebarSearchFieldIsInTheFiltersCard() throws {
    let app = launch(mode: "preview")

    let searchField = element(in: app, identifier: Accessibility.sidebarSearchField)
    let filtersHeading = app.staticTexts["Search & Filters"]
    let noMatches = app.staticTexts["No sessions match"]

    XCTAssertTrue(filtersHeading.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(searchField.waitForExistence(timeout: Self.uiTimeout))

    tapElement(in: app, identifier: Accessibility.sidebarSearchField)
    app.typeText("zzznomatch")

    if !noMatches.waitForExistence(timeout: Self.uiTimeout) {
      attachWindowScreenshot(in: app, named: "sidebar-search-not-hittable")
    }
    XCTAssertTrue(noMatches.exists)
  }

  func testLeaderTransferSectionShowsPickerWithCurrentLeaderDimmed() throws {
    let app = launch(mode: "preview")

    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.workerAgentCard)

    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.uiTimeout))

    let transferSection = element(in: app, identifier: Accessibility.leaderTransferSection)
    let transferButton = button(in: app, title: "Transfer Leadership")

    for _ in 0..<8 where !transferButton.exists {
      dragUp(in: app, element: inspectorRoot, distanceRatio: 0.25)
    }

    XCTAssertTrue(transferSection.exists, "Leader transfer section should be visible")
    XCTAssertTrue(transferButton.exists, "Transfer button should be visible")
    XCTAssertTrue(
      app.staticTexts["Leader Transfer"].exists,
      "Section header should read Leader Transfer"
    )
  }

  func testLeaderTransferSectionIsDisabledForSingleAgentSession() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "single-agent"]
    )

    tapSession(in: app, identifier: Accessibility.singleAgentSessionRow)

    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.uiTimeout))

    let transferSection = element(in: app, identifier: Accessibility.leaderTransferSection)

    for _ in 0..<8 where !transferSection.exists {
      dragUp(in: app, element: inspectorRoot, distanceRatio: 0.25)
    }

    XCTAssertTrue(transferSection.exists, "Leader transfer section should be in the tree")
    XCTAssertFalse(transferSection.isEnabled, "Section should be disabled with only one agent")
  }

  func testActionToastAppearsAndAutoDismisses() throws {
    let app = launch(mode: "preview")

    tapPreviewSession(in: app)

    let observeButton = app.buttons["Observe"].firstMatch
    XCTAssertTrue(observeButton.waitForExistence(timeout: Self.uiTimeout))
    if observeButton.isHittable {
      observeButton.tap()
    } else if let coordinate = centerCoordinate(in: app, for: observeButton) {
      coordinate.tap()
    } else {
      XCTFail("Failed to tap Observe button")
    }

    let toast = element(in: app, identifier: Accessibility.actionToast)
    XCTAssertTrue(
      toast.waitForExistence(timeout: Self.uiTimeout),
      "Toast should appear after action"
    )

    let dismissed = waitUntil(timeout: 8) { !toast.exists }
    XCTAssertTrue(dismissed, "Toast should dismiss after appearing")
  }
}
