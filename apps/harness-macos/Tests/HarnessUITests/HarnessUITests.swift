import XCTest

private typealias Accessibility = HarnessUITestAccessibility

@MainActor
final class HarnessUITests: HarnessUITestCase {
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
      app.staticTexts["Bring Harness Online"].waitForExistence(timeout: Self.uiTimeout)
    )
    XCTAssertTrue(app.buttons["Start Daemon"].exists)

    let sidebarEmptyState = sidebarEmptyStateElement(in: app)
    let sidebarRoot = element(in: app, identifier: Accessibility.sidebarRoot)
    XCTAssertTrue(sidebarEmptyState.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sidebarRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertFalse(element(in: app, identifier: Accessibility.sidebarSessionList).exists)
    XCTAssertEqual(sidebarRoot.descendants(matching: .scrollView).count, 1)
    XCTAssertEqual(sidebarRoot.descendants(matching: .scrollBar).count, 0)

    let activeFilter = button(in: app, title: "Active")
    XCTAssertTrue(activeFilter.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(activeFilter.value as? String, "selected")
    XCTAssertEqual(
      button(in: app, title: "All").value as? String,
      "not selected"
    )
    XCTAssertEqual(
      button(in: app, title: "Ended").value as? String,
      "not selected"
    )
  }

  func testToolbarOpensSettingsWindow() throws {
    let app = launch(mode: "preview")

    let preferencesButton = toolbarButton(in: app, identifier: Accessibility.preferencesButton)
    XCTAssertTrue(preferencesButton.waitForExistence(timeout: Self.uiTimeout))

    preferencesButton.tap()

    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    let preferencesState = element(in: app, identifier: Accessibility.preferencesState)
    let preferencesPanel = frameElement(in: app, identifier: Accessibility.preferencesPanel)
    let title = element(in: app, identifier: Accessibility.preferencesTitle)

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(preferencesPanel.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(preferencesState.waitForExistence(timeout: Self.uiTimeout))
    let settingsWindow = window(in: app, containing: preferencesPanel)
    let generalSection = sidebarSectionElement(
      in: app,
      title: "General",
      within: settingsWindow
    )
    XCTAssertTrue(generalSection.exists)
    XCTAssertTrue(title.exists)
    XCTAssertEqual(title.label, "General")
    XCTAssertEqual(
      preferencesState.label,
      "mode=auto, section=general, preferencesChrome=native"
    )
  }

  func testCommandCommaOpensSingletonSettingsWindow() throws {
    let app = launch(mode: "preview")

    app.typeKey(",", modifierFlags: .command)

    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(
      app.descendants(matching: .any)
        .matching(identifier: Accessibility.preferencesRoot)
        .count,
      1
    )

    app.typeKey(",", modifierFlags: .command)

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(
      app.descendants(matching: .any)
        .matching(identifier: Accessibility.preferencesRoot)
        .count,
      1
    )
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

  func testRemoveLaunchAgentRequiresConfirmation() throws {
    let app = launch(mode: "preview")

    let preferencesButton = toolbarButton(in: app, identifier: Accessibility.preferencesButton)
    XCTAssertTrue(preferencesButton.waitForExistence(timeout: Self.uiTimeout))
    preferencesButton.tap()

    let remove = element(in: app, identifier: Accessibility.removeLaunchAgentButton)
    if !remove.waitForExistence(timeout: Self.uiTimeout) {
      attachAppHierarchy(in: app, named: "remove-launch-agent-hierarchy")
    }
    XCTAssertTrue(remove.exists)
    tapElement(in: app, identifier: Accessibility.removeLaunchAgentButton)

    XCTAssertTrue(
      app.buttons["Remove Launch Agent Now"].waitForExistence(timeout: Self.uiTimeout)
    )
    XCTAssertTrue(app.staticTexts["Remove Launch Agent?"].exists)
    dismissConfirmationDialog(in: app)
  }

  func testSettingsThemeModePickerKeepsNativeChromeContract() throws {
    let app = launch(mode: "preview")

    let preferencesButton = toolbarButton(in: app, identifier: Accessibility.preferencesButton)
    XCTAssertTrue(preferencesButton.waitForExistence(timeout: Self.uiTimeout))
    preferencesButton.tap()

    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    let preferencesState = element(in: app, identifier: Accessibility.preferencesState)
    let appChromeState = element(in: app, identifier: Accessibility.appChromeState)
    let modePicker = element(in: app, identifier: Accessibility.preferencesThemeModePicker)
    let sessionRow = previewSessionTrigger(in: app)
    let observeSummaryButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(preferencesState.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(appChromeState.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(modePicker.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapPreviewSession(in: app)
    XCTAssertTrue(observeSummaryButton.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(
      preferencesState.label,
      "mode=auto, section=general, preferencesChrome=native"
    )
    XCTAssertEqual(
      appChromeState.label,
      "contentChrome=native, interactiveRows=plain, controlGlass=system"
    )
    XCTAssertEqual(sessionRow.value as? String, "selected, interactive=plain")
    XCTAssertEqual(observeSummaryButton.value as? String, "interactive=plain")

    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.preferencesThemeModePicker,
      optionTitle: "Dark"
    )
    XCTAssertTrue(
      waitUntil {
        preferencesState.label == "mode=dark, section=general, preferencesChrome=native"
      }
    )

    XCTAssertEqual(
      preferencesState.label,
      "mode=dark, section=general, preferencesChrome=native"
    )
    XCTAssertEqual(
      appChromeState.label,
      "contentChrome=native, interactiveRows=plain, controlGlass=system"
    )
    XCTAssertEqual(sessionRow.value as? String, "selected, interactive=plain")
    XCTAssertEqual(observeSummaryButton.value as? String, "interactive=plain")

    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.preferencesThemeModePicker,
      optionTitle: "Light"
    )
    XCTAssertTrue(
      waitUntil {
        preferencesState.label == "mode=light, section=general, preferencesChrome=native"
      }
    )

    XCTAssertEqual(
      preferencesState.label,
      "mode=light, section=general, preferencesChrome=native"
    )
    XCTAssertEqual(
      appChromeState.label,
      "contentChrome=native, interactiveRows=plain, controlGlass=system"
    )
    XCTAssertEqual(sessionRow.value as? String, "selected, interactive=plain")
    XCTAssertEqual(observeSummaryButton.value as? String, "interactive=plain")

    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.preferencesThemeModePicker,
      optionTitle: "Auto"
    )
    XCTAssertTrue(
      waitUntil {
        preferencesState.label == "mode=auto, section=general, preferencesChrome=native"
      }
    )
    XCTAssertEqual(
      appChromeState.label,
      "contentChrome=native, interactiveRows=plain, controlGlass=system"
    )
    XCTAssertEqual(sessionRow.value as? String, "selected, interactive=plain")
    XCTAssertEqual(observeSummaryButton.value as? String, "interactive=plain")
  }
}
