import XCTest

private typealias Accessibility = HarnessUITestAccessibility

@MainActor
final class HarnessLayoutUITests: HarnessUITestCase {
  func testPreviewRecentSessionsCardFillsColumn() throws {
    let app = launch(mode: "preview")
    let boardRoot = element(in: app, identifier: Accessibility.sessionsBoardRoot)
    let recentSessionsCard = frameElement(in: app, identifier: Accessibility.recentSessionsCardFrame)

    XCTAssertTrue(boardRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(recentSessionsCard.waitForExistence(timeout: Self.uiTimeout))

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
    let recentSessionsCard = frameElement(in: app, identifier: Accessibility.recentSessionsCardFrame)
    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    let inspectorEmptyState = element(in: app, identifier: Accessibility.inspectorEmptyState)

    XCTAssertTrue(boardRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(onboardingCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(recentSessionsCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(inspectorEmptyState.waitForExistence(timeout: Self.uiTimeout))

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

  func testEmptyModeDashboardMetricsStayOnSingleRow() throws {
    let app = launch(mode: "empty")
    let trackedProjects = element(in: app, identifier: Accessibility.trackedProjectsCard)
    let indexedSessions = element(in: app, identifier: Accessibility.indexedSessionsCard)
    let openWork = element(in: app, identifier: Accessibility.openWorkCard)
    let blocked = element(in: app, identifier: Accessibility.blockedCard)

    XCTAssertTrue(trackedProjects.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(indexedSessions.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(openWork.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(blocked.waitForExistence(timeout: Self.uiTimeout))

    assertSameRow([trackedProjects, indexedSessions, openWork, blocked], tolerance: 10)
    assertEqualHeights([trackedProjects, indexedSessions, openWork, blocked], tolerance: 10)
    XCTAssertLessThan(trackedProjects.frame.height, 112)
  }

  func testInspectorCardsFillTheirColumn() throws {
    let app = launch(mode: "preview")
    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    let sessionInspectorCard = element(in: app, identifier: Accessibility.sessionInspectorCard)
    let sessionRow = previewSessionTrigger(in: app)

    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))

    tapPreviewSession(in: app)

    XCTAssertTrue(sessionInspectorCard.waitForExistence(timeout: Self.uiTimeout))
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

    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))

    tapPreviewSession(in: app)
    tapButton(in: app, identifier: Accessibility.taskUICard)

    let taskInspector = element(in: app, identifier: Accessibility.taskInspectorCard)
    XCTAssertTrue(taskInspector.waitForExistence(timeout: Self.uiTimeout))
    assertFillsColumn(
      child: taskInspector,
      in: inspectorRoot,
      expectedHorizontalInset: 18,
      tolerance: 8
    )

    tapButton(in: app, identifier: Accessibility.workerAgentCard)

    let agentInspector = element(in: app, identifier: Accessibility.agentInspectorCard)
    XCTAssertTrue(agentInspector.waitForExistence(timeout: Self.uiTimeout))
    assertFillsColumn(
      child: agentInspector,
      in: inspectorRoot,
      expectedHorizontalInset: 18,
      tolerance: 8
    )

    tapButton(in: app, identifier: Accessibility.observeSummaryButton)

    let observerInspector = element(in: app, identifier: Accessibility.observerInspectorCard)
    XCTAssertTrue(observerInspector.waitForExistence(timeout: Self.uiTimeout))
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

    XCTAssertTrue(window.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(inspectorEmptyState.waitForExistence(timeout: Self.uiTimeout))

    let cardOffset = inspectorEmptyState.frame.minY - window.frame.minY
    XCTAssertGreaterThan(cardOffset, 40, "Inspector content overlaps toolbar")
    XCTAssertLessThan(cardOffset, 120, "Inspector content too far below toolbar")
  }

  func testSessionCockpitTaskAndAgentCardsShareHeight() throws {
    let app = launch(mode: "preview")

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapPreviewSession(in: app)

    let taskUI = element(in: app, identifier: Accessibility.taskUICard)
    let taskRouting = element(in: app, identifier: Accessibility.taskRoutingCard)
    let leaderCard = element(in: app, identifier: Accessibility.leaderAgentCard)
    let workerCard = element(in: app, identifier: Accessibility.workerAgentCard)

    XCTAssertTrue(taskUI.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(taskRouting.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(leaderCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(workerCard.waitForExistence(timeout: Self.uiTimeout))

    assertEqualHeights([taskUI, taskRouting], tolerance: 10)
    assertEqualHeights([leaderCard, workerCard], tolerance: 10)
  }

  func testPreferencesOverviewUsesGroupedFormRowsAndCompactActionButtons() throws {
    let app = launch(mode: "preview")

    let preferencesButton = toolbarButton(in: app, identifier: Accessibility.preferencesButton)
    XCTAssertTrue(preferencesButton.waitForExistence(timeout: Self.uiTimeout))
    preferencesButton.tap()

    let preferencesPanel = frameElement(in: app, identifier: Accessibility.preferencesPanel)
    XCTAssertTrue(preferencesPanel.waitForExistence(timeout: Self.uiTimeout))

    let endpointCard = element(in: app, identifier: Accessibility.preferencesEndpointCard)
    let versionCard = element(in: app, identifier: Accessibility.preferencesVersionCard)
    let launchdCard = element(in: app, identifier: Accessibility.preferencesLaunchdCard)
    let cachedSessionsCard = element(
      in: app,
      identifier: Accessibility.preferencesCachedSessionsCard
    )

    XCTAssertTrue(endpointCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(versionCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(launchdCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(cachedSessionsCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: Self.uiTimeout))

    let overviewRows = [endpointCard, versionCard, launchdCard, cachedSessionsCard]
    XCTAssertLessThan(endpointCard.frame.height, 80)
    XCTAssertLessThan(versionCard.frame.height, 80)
    XCTAssertLessThan(launchdCard.frame.height, 80)
    XCTAssertLessThan(cachedSessionsCard.frame.height, 80)

    for (previousRow, nextRow) in zip(overviewRows, overviewRows.dropFirst()) {
      XCTAssertLessThan(
        previousRow.frame.minY,
        nextRow.frame.minY,
        "Overview rows should stack vertically in the grouped form"
      )
    }

    let reconnect = frameElement(in: app, identifier: "\(Accessibility.reconnectButton).frame")
    let refresh = frameElement(in: app, identifier: "\(Accessibility.refreshDiagnosticsButton).frame")
    let start = frameElement(in: app, identifier: "\(Accessibility.startDaemonButton).frame")
    let install = frameElement(
      in: app,
      identifier: "\(Accessibility.installLaunchAgentButton).frame"
    )
    let remove = frameElement(
      in: app,
      identifier: "\(Accessibility.removeLaunchAgentButton).frame"
    )

    XCTAssertTrue(reconnect.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(refresh.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(start.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(install.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(remove.waitForExistence(timeout: Self.uiTimeout))

    assertEqualHeights([reconnect, refresh, start, install, remove], tolerance: 10)
    XCTAssertLessThan(start.frame.height, 62)
    XCTAssertLessThan(refresh.frame.height, 62)
  }

  func testPreferencesSidebarChromeMatchesNativeInsetLayout() throws {
    let app = launch(mode: "preview")

    let preferencesButton = toolbarButton(in: app, identifier: Accessibility.preferencesButton)
    XCTAssertTrue(preferencesButton.waitForExistence(timeout: Self.uiTimeout))
    preferencesButton.tap()

    let preferencesPanel = frameElement(in: app, identifier: Accessibility.preferencesPanel)

    XCTAssertTrue(preferencesPanel.waitForExistence(timeout: Self.uiTimeout))

    let settingsWindow = window(in: app, containing: preferencesPanel)
    XCTAssertTrue(settingsWindow.exists)
    let settingsToolbar = settingsWindow.toolbars.firstMatch
    XCTAssertTrue(settingsToolbar.waitForExistence(timeout: Self.uiTimeout))
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
    XCTAssertTrue(generalSection.waitForExistence(timeout: Self.uiTimeout))
    let toolbarLeadingInset = leadingToolbarButton.frame.minX - settingsWindow.frame.minX
    let rowTopInset = generalSection.frame.minY - settingsWindow.frame.minY

    XCTAssertLessThan(
      toolbarLeadingInset,
      170,
      "Settings sidebar toggle should stay near the leading window chrome"
    )
    XCTAssertGreaterThan(
      rowTopInset,
      70,
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

    XCTAssertTrue(sidebarStart.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sidebarInstall.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(boardStart.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(boardInstall.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(boardRefresh.waitForExistence(timeout: Self.uiTimeout))

    assertEqualHeights([sidebarStart, sidebarInstall], tolerance: 10)
    assertEqualHeights([boardStart, boardInstall, boardRefresh], tolerance: 10)
    XCTAssertLessThan(sidebarStart.frame.height, 62)
    XCTAssertLessThan(boardStart.frame.height, 62)
  }
}
