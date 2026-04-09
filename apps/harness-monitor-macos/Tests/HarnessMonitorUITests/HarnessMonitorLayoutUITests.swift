import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorLayoutUITests: HarnessMonitorUITestCase {
  func testPreviewRecentSessionsCardFillsColumn() throws {
    let app = launch(mode: "preview")
    let boardRoot = element(in: app, identifier: Accessibility.sessionsBoardRoot)
    let recentSessionsCard = frameElement(
      in: app, identifier: Accessibility.recentSessionsCardFrame)

    XCTAssertTrue(boardRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(recentSessionsCard.waitForExistence(timeout: Self.actionTimeout))

    assertFillsColumn(
      child: recentSessionsCard,
      in: boardRoot,
      expectedHorizontalInset: 24,
      tolerance: 8
    )
  }

  func testEmptyModeCardsSpanTheirColumns() throws {
    let app = launch(mode: "empty")
    let boardRoot = element(in: app, identifier: Accessibility.sessionsBoardRoot)
    let onboardingCard = frameElement(in: app, identifier: Accessibility.onboardingCardFrame)
    let recentSessionsCard = frameElement(
      in: app, identifier: Accessibility.recentSessionsCardFrame)
    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    let inspectorEmptyState = element(in: app, identifier: Accessibility.inspectorEmptyState)

    XCTAssertTrue(boardRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(onboardingCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(recentSessionsCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(inspectorEmptyState.waitForExistence(timeout: Self.actionTimeout))

    assertFillsColumn(
      child: onboardingCard,
      in: boardRoot,
      expectedHorizontalInset: 24,
      tolerance: 8
    )
    assertFillsColumn(
      child: recentSessionsCard,
      in: boardRoot,
      expectedHorizontalInset: 24,
      tolerance: 8
    )
    XCTAssertEqual(recentSessionsCard.frame.width, onboardingCard.frame.width, accuracy: 8)
    assertFillsColumn(
      child: inspectorEmptyState,
      in: inspectorRoot,
      expectedHorizontalInset: 18,
      tolerance: 8
    )
  }

  func testDashboardUsesToolbarSummaryInsteadOfMetricCards() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )
    let boardRoot = element(in: app, identifier: Accessibility.sessionsBoardRoot)
    let centerpiece = element(in: app, identifier: Accessibility.toolbarCenterpiece)
    let centerpieceState = element(in: app, identifier: Accessibility.toolbarCenterpieceState)
    let boardMetricElements = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "harness.board.metric.")
    )

    XCTAssertTrue(boardRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(centerpiece.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(centerpieceState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      centerpieceState.label,
      "projects=1, worktrees=0, sessions=1, openWork=2, blocked=1"
    )
    XCTAssertEqual(
      boardMetricElements.count,
      0,
      "Expected dashboard summary metrics to render only in the toolbar centerpiece"
    )
  }

  func testOfflineCachedScenarioKeepsSessionsReadableButActionsDisabled() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "offline-cached"]
    )
    let window = mainWindow(in: app)
    let persistedBanner = element(in: app, identifier: Accessibility.persistedDataBanner)
    let persistedBannerFrame = frameElement(
      in: app, identifier: Accessibility.persistedDataBannerFrame)
    let sidebarRoot = element(in: app, identifier: Accessibility.sidebarRoot)
    let sidebarContent = frameElement(in: app, identifier: Accessibility.sidebarShellFrame)
    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    let sessionRow = previewSessionTrigger(in: app)
    let searchField = editableField(in: app, identifier: Accessibility.sidebarSearchField)
    let clearFiltersButton = element(
      in: app,
      identifier: Accessibility.sidebarClearFiltersButton
    )
    let observeButton = button(in: app, title: "Observe")
    let endSessionButton = element(in: app, identifier: Accessibility.endSessionButton)
    let createTaskButton = button(in: app, title: "Create Task")

    XCTAssertTrue(window.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(persistedBanner.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(persistedBannerFrame.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sidebarRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sidebarContent.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(searchField.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(observeButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(endSessionButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(createTaskButton.waitForExistence(timeout: Self.actionTimeout))

    XCTAssertTrue(persistedBanner.label.contains("Daemon is off"))
    XCTAssertTrue(persistedBanner.label.contains("may be stale"))
    XCTAssertEqual(persistedBannerFrame.frame.minX, sidebarContent.frame.maxX, accuracy: 8)
    XCTAssertEqual(persistedBannerFrame.frame.maxX, inspectorRoot.frame.minX, accuracy: 12)
    XCTAssertFalse(observeButton.isEnabled)
    XCTAssertFalse(endSessionButton.isEnabled)
    XCTAssertFalse(createTaskButton.isEnabled)

    tapElement(in: app, identifier: Accessibility.sidebarSearchField)
    app.typeText("offline cockpit\n")
    XCTAssertTrue(clearFiltersButton.waitForExistence(timeout: Self.actionTimeout))
    tapElement(in: app, identifier: Accessibility.sidebarClearFiltersButton)

    let recentSearchChip = button(in: app, title: "offline cockpit")
    let clearSearchHistoryButton = element(
      in: app,
      identifier: Accessibility.sidebarClearSearchHistoryButton
    )
    XCTAssertTrue(recentSearchChip.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(clearSearchHistoryButton.waitForExistence(timeout: Self.actionTimeout))
    tapElement(in: app, identifier: Accessibility.sidebarClearSearchHistoryButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        !recentSearchChip.exists && !clearSearchHistoryButton.exists
      }
    )

    tapButton(in: app, identifier: Accessibility.taskUICard)
    let taskInspector = element(in: app, identifier: Accessibility.taskInspectorCard)
    let noteField = editableField(in: app, identifier: Accessibility.taskNoteField)
    let addNoteButton = element(in: app, identifier: Accessibility.taskNoteAddButton)
    XCTAssertTrue(taskInspector.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(noteField.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(addNoteButton.waitForExistence(timeout: Self.actionTimeout))

    tapElement(in: app, identifier: Accessibility.taskNoteField)
    app.typeText("Offline note")
    tapElement(in: app, identifier: Accessibility.taskNoteAddButton)
    XCTAssertTrue(app.staticTexts["Offline note"].waitForExistence(timeout: Self.actionTimeout))

    tapButton(in: app, identifier: Accessibility.workerAgentCard)
    let signalSendButton = element(in: app, identifier: Accessibility.signalSendButton)
    XCTAssertTrue(signalSendButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(signalSendButton.isEnabled)
  }

  func testInspectorCardsFillTheirColumn() throws {
    let app = launch(mode: "preview")
    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    let sessionInspectorCard = element(in: app, identifier: Accessibility.sessionInspectorCard)
    let sessionRow = previewSessionTrigger(in: app)

    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))

    tapPreviewSession(in: app)

    XCTAssertTrue(sessionInspectorCard.waitForExistence(timeout: Self.actionTimeout))
    assertFillsColumn(
      child: sessionInspectorCard,
      in: inspectorRoot,
      expectedHorizontalInset: 18,
      tolerance: 8
    )
  }

  func testSelectedInspectorCardsFillTheirColumn() throws {
    let app = launch(mode: "preview")
    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    let sessionRow = previewSessionTrigger(in: app)

    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))

    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.taskUICard)

    let taskInspector = element(in: app, identifier: Accessibility.taskInspectorCard)
    XCTAssertTrue(taskInspector.waitForExistence(timeout: Self.actionTimeout))
    assertFillsColumn(
      child: taskInspector,
      in: inspectorRoot,
      expectedHorizontalInset: 18,
      tolerance: 8
    )

    tapButton(in: app, identifier: Accessibility.workerAgentCard)

    let agentInspector = element(in: app, identifier: Accessibility.agentInspectorCard)
    XCTAssertTrue(agentInspector.waitForExistence(timeout: Self.actionTimeout))
    assertFillsColumn(
      child: agentInspector,
      in: inspectorRoot,
      expectedHorizontalInset: 18,
      tolerance: 8
    )

    tapButton(in: app, identifier: Accessibility.observeSummaryButton)

    let observerInspector = element(in: app, identifier: Accessibility.observerInspectorCard)
    XCTAssertTrue(observerInspector.waitForExistence(timeout: Self.actionTimeout))
    assertFillsColumn(
      child: observerInspector,
      in: inspectorRoot,
      expectedHorizontalInset: 18,
      tolerance: 8
    )
  }

  func testInspectorContentStartsBelowToolbarChrome() throws {
    let app = launch(mode: "empty")

    let window = mainWindow(in: app)
    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    let inspectorEmptyState = element(in: app, identifier: Accessibility.inspectorEmptyState)

    XCTAssertTrue(window.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(inspectorEmptyState.waitForExistence(timeout: Self.actionTimeout))

    let cardOffset = inspectorEmptyState.frame.minY - window.frame.minY
    XCTAssertGreaterThan(cardOffset, 40, "Inspector content overlaps toolbar")
    XCTAssertLessThan(cardOffset, 120, "Inspector content too far below toolbar")
  }

  func testInspectorCanBeResizedWiderByDraggingDivider() throws {
    let app = launch(mode: "empty")
    let window = mainWindow(in: app)
    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)

    XCTAssertTrue(window.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.actionTimeout))

    let initialWidth = inspectorRoot.frame.width
    let origin = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
    let dividerOffsetX = max(2, inspectorRoot.frame.minX - window.frame.minX - 2)
    let dividerOffsetY = max(2, inspectorRoot.frame.midY - window.frame.minY)
    let start = origin.withOffset(CGVector(dx: dividerOffsetX, dy: dividerOffsetY))
    let end = start.withOffset(CGVector(dx: -140, dy: 0))

    start.press(forDuration: 0.01, thenDragTo: end)

    let widenedInspector = waitUntil(timeout: Self.actionTimeout) {
      inspectorRoot.frame.width >= initialWidth + 80
    }

    if !widenedInspector {
      attachWindowScreenshot(in: app, named: "inspector-wide-width")
      let attachment = XCTAttachment(
        string: """
          initial inspector width: \(initialWidth)
          final inspector frame: \(inspectorRoot.exists ? String(describing: inspectorRoot.frame) : "missing")
          divider drag start: \(dividerOffsetX), \(dividerOffsetY)
          """
      )
      attachment.name = "inspector-wide-width-diagnostics"
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    XCTAssertTrue(
      widenedInspector,
      "Expected the inspector divider drag to widen the column"
    )
  }

  func testInspectorToolbarControlsStayWithinInspectorColumn() throws {
    let app = launch(mode: "empty")

    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    let inspectorEmptyState = element(in: app, identifier: Accessibility.inspectorEmptyState)
    let refreshButton = toolbarButton(in: app, identifier: Accessibility.refreshButton)
    let hideInspectorButton = toolbarButton(
      in: app, identifier: Accessibility.inspectorToggleButton)

    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(inspectorEmptyState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(refreshButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(hideInspectorButton.waitForExistence(timeout: Self.actionTimeout))

    for control in [refreshButton, hideInspectorButton] {
      XCTAssertGreaterThanOrEqual(control.frame.minX, inspectorRoot.frame.minX - 6)
      XCTAssertLessThanOrEqual(control.frame.maxX, inspectorRoot.frame.maxX + 6)
      XCTAssertLessThan(control.frame.maxY, inspectorEmptyState.frame.minY)
    }
  }

  func testSessionCockpitTaskAndAgentCardsShareHeight() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    let taskUI = element(in: app, identifier: Accessibility.taskUICard)
    let taskRouting = element(in: app, identifier: Accessibility.taskRoutingCard)
    let leaderCard = element(in: app, identifier: Accessibility.leaderAgentCard)
    let workerCard = element(in: app, identifier: Accessibility.workerAgentCard)

    XCTAssertTrue(taskUI.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(taskRouting.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(leaderCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(workerCard.waitForExistence(timeout: Self.actionTimeout))

    assertEqualHeights([taskUI, taskRouting], tolerance: 10)
    assertEqualHeights([leaderCard, workerCard], tolerance: 10)
  }

  func testPreferencesOverviewUsesGroupedFormRowsAndCompactActionButtons() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )

    openSettings(in: app)
    let preferencesPanel = frameElement(in: app, identifier: Accessibility.preferencesPanel)
    XCTAssertTrue(preferencesPanel.waitForExistence(timeout: Self.actionTimeout))

    let endpointCard = element(in: app, identifier: Accessibility.preferencesEndpointCard)
    let versionCard = element(in: app, identifier: Accessibility.preferencesVersionCard)
    let launchdCard = element(in: app, identifier: Accessibility.preferencesLaunchdCard)
    let databaseSizeCard = element(in: app, identifier: Accessibility.preferencesDatabaseSizeCard)
    let liveSessionsCard = element(in: app, identifier: Accessibility.preferencesLiveSessionsCard)

    XCTAssertTrue(endpointCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(versionCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(launchdCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(databaseSizeCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(liveSessionsCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        (launchdCard.value as? String)?.contains("Running") == true
      }
    )

    let overviewRows = [endpointCard, versionCard, launchdCard, databaseSizeCard, liveSessionsCard]
    for row in overviewRows {
      XCTAssertLessThan(row.frame.height, 80)
    }

    for (previousRow, nextRow) in zip(overviewRows, overviewRows.dropFirst()) {
      XCTAssertLessThan(
        previousRow.frame.minY,
        nextRow.frame.minY,
        "Overview rows should stack vertically in the grouped form"
      )
    }

    let reconnect = frameElement(in: app, identifier: "\(Accessibility.reconnectButton).frame")
    let refresh = frameElement(
      in: app, identifier: "\(Accessibility.refreshDiagnosticsButton).frame")
    let start = frameElement(in: app, identifier: "\(Accessibility.startDaemonButton).frame")
    let install = frameElement(
      in: app,
      identifier: "\(Accessibility.installLaunchAgentButton).frame"
    )
    let remove = frameElement(
      in: app,
      identifier: "\(Accessibility.removeLaunchAgentButton).frame"
    )

    XCTAssertTrue(reconnect.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(refresh.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(start.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(install.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(remove.waitForExistence(timeout: Self.actionTimeout))

    assertEqualHeights([reconnect, refresh, start, install, remove], tolerance: 10)
    XCTAssertLessThan(start.frame.height, 62)
    XCTAssertLessThan(refresh.frame.height, 62)
  }

  func testPreferencesSidebarChromeMatchesNativeInsetLayout() throws {
    let app = launch(mode: "preview")

    openSettings(in: app)
    let preferencesPanel = frameElement(in: app, identifier: Accessibility.preferencesPanel)

    XCTAssertTrue(preferencesPanel.waitForExistence(timeout: Self.actionTimeout))

    let settingsWindow = window(in: app, containing: preferencesPanel)
    XCTAssertTrue(settingsWindow.exists)
    let settingsToolbar = settingsWindow.toolbars.firstMatch
    XCTAssertTrue(settingsToolbar.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertGreaterThan(
      settingsToolbar.buttons.count,
      0,
      "Settings split view should expose toolbar controls in native window chrome"
    )
    let leadingToolbarButton = settingsToolbar.buttons.element(boundBy: 0)
    XCTAssertTrue(leadingToolbarButton.exists)
    let generalSection = sidebarSectionElement(
      in: app,
      title: "General",
      within: settingsWindow
    )
    XCTAssertTrue(generalSection.waitForExistence(timeout: Self.actionTimeout))
    let toolbarLeadingInset = leadingToolbarButton.frame.minX - settingsWindow.frame.minX
    let rowTopInset = generalSection.frame.minY - settingsWindow.frame.minY

    XCTAssertLessThan(
      toolbarLeadingInset,
      176,
      "Settings sidebar toggle should stay near the leading window chrome"
    )
    XCTAssertGreaterThan(
      rowTopInset,
      44,
      "Sidebar content should start below the native toolbar controls"
    )
    XCTAssertLessThan(
      rowTopInset,
      120,
      "Sidebar content should stay visually close to the toolbar"
    )
  }

  func testSidebarAndBoardActionButtonsStayCompact() throws {
    let app = launch(mode: "empty")

    let sidebarStart = frameElement(in: app, identifier: Accessibility.sidebarStartButtonFrame)
    let sidebarInstall = frameElement(in: app, identifier: Accessibility.sidebarInstallButtonFrame)
    let boardStart = frameElement(in: app, identifier: Accessibility.onboardingStartButtonFrame)
    let boardInstall = frameElement(
      in: app,
      identifier: Accessibility.onboardingInstallButtonFrame
    )
    let boardRefresh = frameElement(
      in: app,
      identifier: Accessibility.onboardingRefreshButtonFrame
    )

    XCTAssertTrue(sidebarStart.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sidebarInstall.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(boardStart.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(boardInstall.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(boardRefresh.waitForExistence(timeout: Self.actionTimeout))

    assertEqualHeights([boardStart, boardInstall, boardRefresh], tolerance: 10)
    XCTAssertLessThan(sidebarStart.frame.height, 40)
    XCTAssertLessThan(sidebarStart.frame.width, 40)
    XCTAssertLessThan(boardStart.frame.height, 62)
  }
}
