import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility
private let textSizeOverrideKey = "HARNESS_MONITOR_TEXT_SIZE_OVERRIDE"

@MainActor
final class HarnessMonitorUITests: HarnessMonitorUITestCase {
  func testPreviewModeLoadsDashboardAndOpensCockpit() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    if !sessionRow.waitForExistence(timeout: Self.actionTimeout) {
      attachWindowScreenshot(in: app, named: "preview-session-row-missing")
    }
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))

    tapPreviewSession(in: app)

    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch
    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.actionTimeout))
  }

  func testEmptyModeShowsOnboardingCard() throws {
    let app = launch(mode: "empty")

    XCTAssertTrue(
      app.staticTexts["Bring Harness Monitor Online"].waitForExistence(timeout: Self.actionTimeout)
    )
    XCTAssertTrue(element(in: app, identifier: Accessibility.sidebarStartButton).exists)

    let sidebarEmptyState = app.staticTexts[Accessibility.sidebarEmptyStateTitle]
    let sidebarRoot = element(in: app, identifier: Accessibility.sidebarRoot)
    XCTAssertTrue(sidebarEmptyState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sidebarRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(element(in: app, identifier: Accessibility.sidebarSessionList).exists)
    XCTAssertGreaterThanOrEqual(sidebarRoot.descendants(matching: .scrollView).count, 1)
    XCTAssertEqual(sidebarRoot.descendants(matching: .scrollBar).count, 0)

    let searchField = editableField(in: app, identifier: Accessibility.sidebarSearchField)
    let filterMenu = button(in: app, identifier: Accessibility.sidebarFilterMenu)
    let filterState = element(in: app, identifier: Accessibility.sidebarFilterState)

    XCTAssertTrue(searchField.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(filterMenu.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(filterState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(filterState.label.contains("status=active"))
    XCTAssertTrue(filterState.label.contains("focus=all"))
    XCTAssertTrue(filterState.label.contains("sort=recentActivity"))
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

    XCTAssertTrue(persistenceBanner.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(clearSearchHistoryButton.exists)

    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.taskUICard)

    let notesUnavailable = element(in: app, identifier: Accessibility.taskNotesUnavailable)
    XCTAssertTrue(notesUnavailable.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(element(in: app, identifier: Accessibility.taskNoteField).exists)
    XCTAssertFalse(element(in: app, identifier: Accessibility.taskNoteAddButton).exists)
  }

  func testObserveSummaryIsAvailableInSessionCockpit() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    let tasks = app.staticTexts["Tasks"]
    let signals = app.staticTexts["Signals"]
    XCTAssertTrue(tasks.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(signals.waitForExistence(timeout: Self.actionTimeout))

    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch
    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.actionTimeout))
    tapButton(in: app, identifier: Accessibility.observeSummaryButton)

    XCTAssertTrue(tasks.exists)
    XCTAssertTrue(signals.exists)
  }

  func testTimelinePaginationChangesVisibleEntriesAndResetsAfterSessionSwitch() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "paged-timeline"]
    )

    let primarySession = previewSessionTrigger(in: app)
    let secondarySession = sessionTrigger(
      in: app,
      identifier: Accessibility.signalRegressionSecondarySessionRow
    )

    XCTAssertTrue(primarySession.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(secondarySession.waitForExistence(timeout: Self.actionTimeout))

    tapPreviewSession(in: app)

    let previousButton = button(
      in: app,
      identifier: Accessibility.sessionTimelinePaginationPrevious
    )
    let nextButton = button(
      in: app,
      identifier: Accessibility.sessionTimelinePaginationNext
    )
    let pageStatus = element(
      in: app,
      identifier: Accessibility.sessionTimelinePaginationStatus
    )
    let pageSizePicker = popUpButton(
      in: app,
      identifier: Accessibility.sessionTimelinePageSizePicker
    )

    XCTAssertTrue(pageStatus.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(previousButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(nextButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(pageSizePicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(
      app.staticTexts["Paged timeline event 32"].waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(app.staticTexts["Paged timeline event 22"].exists)
    XCTAssertFalse(previousButton.isEnabled)
    XCTAssertTrue(nextButton.isEnabled)
    XCTAssertEqual(pageStatus.label, "Page 1 of 4")

    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.sessionTimelinePageSizePicker,
      optionTitle: "30"
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        pageStatus.label == "Page 1 of 2"
      }
    )
    XCTAssertTrue(app.staticTexts["Paged timeline event 32"].exists)
    XCTAssertFalse(app.staticTexts["Paged timeline event 02"].exists)

    tapButton(in: app, identifier: Accessibility.sessionTimelinePaginationPageButton(2))

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        pageStatus.label == "Page 2 of 2"
      }
    )
    XCTAssertTrue(
      app.staticTexts["Paged timeline event 02"].waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(nextButton.isEnabled)

    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.sessionTimelinePageSizePicker,
      optionTitle: "15"
    )

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        pageStatus.label == "Page 3 of 3"
      }
    )
    XCTAssertTrue(app.staticTexts["Paged timeline event 02"].exists)
    XCTAssertTrue(previousButton.isEnabled)
    XCTAssertFalse(nextButton.isEnabled)

    tapButton(in: app, identifier: Accessibility.sessionTimelinePaginationPageButton(2))

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        pageStatus.label == "Page 2 of 3"
      }
    )
    XCTAssertTrue(
      app.staticTexts["Paged timeline event 17"].waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(app.staticTexts["Paged timeline event 32"].exists)
    XCTAssertTrue(previousButton.isEnabled)
    XCTAssertTrue(nextButton.isEnabled)

    tapButton(in: app, identifier: Accessibility.sessionTimelinePaginationPageButton(3))

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        pageStatus.label == "Page 3 of 3"
      }
    )
    XCTAssertTrue(
      app.staticTexts["Paged timeline event 02"].waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(nextButton.isEnabled)

    tapSession(in: app, identifier: Accessibility.signalRegressionSecondarySessionRow)

    XCTAssertTrue(
      app.staticTexts["worker-codex received a result from Edit"].waitForExistence(
        timeout: Self.actionTimeout
      )
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        !self.element(in: app, identifier: Accessibility.sessionTimelinePagination).exists
      }
    )

    tapPreviewSession(in: app)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.element(in: app, identifier: Accessibility.sessionTimelinePaginationStatus).label
          == "Page 1 of 4"
      }
    )
    XCTAssertTrue(
      app.staticTexts["Paged timeline event 32"].waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(app.staticTexts["Paged timeline event 22"].exists)
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

    XCTAssertTrue(primarySession.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(secondarySession.waitForExistence(timeout: Self.actionTimeout))

    if !primarySignal.waitForExistence(timeout: 1.5) {
      tapPreviewSession(in: app)
    }

    XCTAssertTrue(
      primarySignal.waitForExistence(timeout: Self.actionTimeout),
      "Existing session signals should be visible when the cockpit opens"
    )
    tapButton(in: app, identifier: Accessibility.previewSignalCard)
    XCTAssertTrue(
      signalInspector.waitForExistence(timeout: Self.actionTimeout),
      "Selecting a signal row should open the signal inspector"
    )

    tapSession(in: app, identifier: Accessibility.signalRegressionSecondarySessionRow)
    XCTAssertTrue(
      noSignalsState.waitForExistence(timeout: Self.actionTimeout),
      "A different session without signals should replace the previous signal list"
    )

    tapPreviewSession(in: app)
    XCTAssertTrue(
      primarySignal.waitForExistence(timeout: Self.actionTimeout),
      "Existing signals should still be visible after switching away and back"
    )
  }

  func testToolbarSurvivesSidebarToggle() throws {
    let app = launch(mode: "preview")

    let sidebarToggle = sidebarToggleButton(in: app)
    let refreshButton = toolbarButton(in: app, identifier: Accessibility.refreshButton)
    let sidebarShellQuery = app.otherElements
      .matching(identifier: Accessibility.sidebarShellFrame)
    let sidebarShell = sidebarShellQuery.firstMatch

    XCTAssertTrue(sidebarToggle.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(refreshButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sidebarShell.waitForExistence(timeout: Self.actionTimeout))
    let initialSidebarWidth = sidebarShell.frame.width
    XCTAssertGreaterThan(initialSidebarWidth, 200)
    let refreshToolbarButtons = app.toolbars.buttons.matching(
      identifier: Accessibility.refreshButton
    )
    let visibleRefreshButtons = refreshToolbarButtons
      .allElementsBoundByIndex
      .filter { $0.exists && $0.isHittable }
    XCTAssertGreaterThanOrEqual(visibleRefreshButtons.count, 1)
    XCTAssertTrue(refreshButton.isHittable)

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
    XCTAssertTrue(refreshButton.isHittable)

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
    refreshButton.tap()
    XCTAssertTrue(refreshButton.exists)
  }

  func testSidebarFilterMenuHidesWhenSidebarIsCollapsed() throws {
    let app = launch(mode: "preview")

    let sidebarToggle = sidebarToggleButton(in: app)
    let sidebarShellQuery = app.otherElements
      .matching(identifier: Accessibility.sidebarShellFrame)
    let sidebarShell = sidebarShellQuery.firstMatch

    XCTAssertTrue(sidebarToggle.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(
      button(in: app, identifier: Accessibility.sidebarFilterMenu)
        .waitForExistence(timeout: Self.actionTimeout)
    )
    XCTAssertTrue(sidebarShell.waitForExistence(timeout: Self.actionTimeout))
    let initialSidebarWidth = sidebarShell.frame.width
    XCTAssertGreaterThan(initialSidebarWidth, 200)

    sidebarToggle.tap()

    XCTAssertTrue(
      waitUntil {
        guard let collapsedSidebar = sidebarShellQuery.allElementsBoundByIndex.first else {
          return true
        }
        return collapsedSidebar.frame.width < max(120, initialSidebarWidth * 0.5)
      }
    )
    XCTAssertTrue(
      waitUntil {
        !self.button(in: app, identifier: Accessibility.sidebarFilterMenu).exists
      },
      "Sidebar-only filter controls should leave the toolbar when the sidebar is collapsed"
    )

    sidebarToggle.tap()

    XCTAssertTrue(
      waitUntil {
        guard let restoredSidebar = sidebarShellQuery.allElementsBoundByIndex.first else {
          return false
        }
        return restoredSidebar.frame.width > (initialSidebarWidth * 0.75)
      }
    )
    XCTAssertTrue(
      waitUntil {
        self.button(in: app, identifier: Accessibility.sidebarFilterMenu).isHittable
      },
      "Sidebar filter controls should return when the sidebar is visible again"
    )
  }

  func testSessionActionsExposeActorPickerAndRemoveAgentFlow() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.workerAgentCard)

    let actorPicker = element(in: app, identifier: Accessibility.actionActorPicker)
    let removeAgentButton = element(in: app, identifier: Accessibility.removeAgentButton)

    XCTAssertTrue(actorPicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(removeAgentButton.waitForExistence(timeout: Self.actionTimeout))
  }

  func testTaskInspectorShowsCheckpointNotesAndSuggestedFix() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.taskUICard)

    let inspectorCard = element(in: app, identifier: Accessibility.taskInspectorCard)

    XCTAssertTrue(inspectorCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(app.staticTexts["Checkpoint"].exists)
    XCTAssertTrue(app.staticTexts["Suggested Fix"].exists)
    XCTAssertTrue(
      app.staticTexts["Merged daemon timeline entries with session checkpoints."].exists
    )
  }

  func testAgentInspectorShowsRuntimeCapabilitiesAndToolActivity() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.workerAgentCard)

    let inspectorCard = element(in: app, identifier: Accessibility.agentInspectorCard)
    let sendSignalButton = element(in: app, identifier: Accessibility.signalSendButton)

    XCTAssertTrue(inspectorCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sendSignalButton.waitForExistence(timeout: Self.actionTimeout))
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
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.workerAgentCard)

    let appChromeState = element(in: app, identifier: Accessibility.appChromeState)
    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    let actorPicker = popUpButton(in: app, identifier: Accessibility.actionActorPicker)
    let commandField = editableField(in: app, identifier: Accessibility.signalCommandField)
    let messageField = editableField(in: app, identifier: Accessibility.signalMessageField)

    XCTAssertTrue(appChromeState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(actorPicker.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(commandField.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(messageField.waitForExistence(timeout: Self.actionTimeout))
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
      waitUntil(timeout: Self.actionTimeout) {
        actorPicker.isHittable && commandField.isHittable && messageField.isHittable
      }
    )
  }

  func testObserverInspectorShowsCycleHistoryAndTrackedSessions() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.observeSummaryButton)

    let inspectorCard = element(in: app, identifier: Accessibility.observerInspectorCard)

    XCTAssertTrue(inspectorCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(app.staticTexts["Cycle History"].exists)
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

  func testSidebarSearchFieldLivesInToolbarAndFiltersSessions() throws {
    let app = launch(mode: "preview")

    let searchField = editableField(in: app, identifier: Accessibility.sidebarSearchField)
    let filterMenu = button(in: app, identifier: Accessibility.sidebarFilterMenu)
    let noMatches = app.staticTexts["No sessions match"]

    XCTAssertTrue(searchField.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(filterMenu.waitForExistence(timeout: Self.actionTimeout))

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

  func testLeaderTransferSectionShowsPickerWithCurrentLeaderDimmed() throws {
    let app = launch(mode: "preview")

    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.workerAgentCard)

    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.actionTimeout))

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
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.actionTimeout))

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
    XCTAssertTrue(observeButton.waitForExistence(timeout: Self.actionTimeout))
    if observeButton.isHittable {
      observeButton.tap()
    } else if let coordinate = centerCoordinate(in: app, for: observeButton) {
      coordinate.tap()
    } else {
      XCTFail("Failed to tap Observe button")
    }

    let toast = element(in: app, identifier: Accessibility.actionToast)
    XCTAssertTrue(
      toast.waitForExistence(timeout: Self.actionTimeout),
      "Toast should appear after action"
    )

    let dismissed = waitUntil(timeout: 2) { !toast.exists }
    XCTAssertTrue(dismissed, "Toast should dismiss after appearing")
  }
}
