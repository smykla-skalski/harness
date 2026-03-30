import XCTest

private typealias Accessibility = HarnessUITestAccessibility

@MainActor
final class HarnessLayoutUITests: HarnessUITestCase {
  func testPreviewRecentSessionsCardFillsColumn() throws {
    let app = launch(mode: "preview")

    let boardRoot = element(in: app, identifier: Accessibility.sessionsBoardRoot)
    let recentSessionsCard = element(in: app, identifier: Accessibility.recentSessionsCard)

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
    let onboardingCard = element(in: app, identifier: Accessibility.onboardingCard)
    let recentSessionsCard = element(in: app, identifier: Accessibility.recentSessionsCard)
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
    let sessionRow = element(in: app, identifier: Accessibility.previewSessionRow)

    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))

    tapElement(in: app, identifier: Accessibility.previewSessionRow)

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
    let sessionRow = element(in: app, identifier: Accessibility.previewSessionRow)

    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))

    tapElement(in: app, identifier: Accessibility.previewSessionRow)
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

  func testSidebarDaemonBadgesShareWidth() throws {
    let app = launch(mode: "empty")

    let sidebarRoot = element(in: app, identifier: Accessibility.sidebarRoot)
    let daemonCard = frameElement(in: app, identifier: Accessibility.daemonCardFrame)

    XCTAssertTrue(sidebarRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(daemonCard.waitForExistence(timeout: Self.uiTimeout))
    assertFillsColumn(
      child: daemonCard,
      in: sidebarRoot,
      expectedHorizontalInset: 22,
      tolerance: 12
    )
    XCTAssertLessThan(daemonCard.frame.height, 360)
  }

  func testSidebarContentStartsBelowToolbarChrome() throws {
    let app = launch(mode: "preview")

    let window = mainWindow(in: app)
    let sidebarContent = frameElement(in: app, identifier: Accessibility.sidebarShellFrame)
    let daemonCard = frameElement(in: app, identifier: Accessibility.daemonCardFrame)

    XCTAssertTrue(window.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sidebarContent.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(daemonCard.waitForExistence(timeout: Self.uiTimeout))

    let toolbarOffset = sidebarContent.frame.minY - window.frame.minY
    XCTAssertGreaterThan(toolbarOffset, 40)
    XCTAssertLessThan(toolbarOffset, 84)
    XCTAssertGreaterThanOrEqual(daemonCard.frame.minY - sidebarContent.frame.minY, 0)
    XCTAssertLessThan(daemonCard.frame.minY - sidebarContent.frame.minY, 28)
  }

  func testSidebarProjectHeaderFillsAvailableWidth() throws {
    let app = launch(mode: "preview")

    let sessionList = frameElement(in: app, identifier: Accessibility.sidebarSessionListContent)
    let projectHeader = frameElement(in: app, identifier: Accessibility.previewProjectHeaderFrame)

    XCTAssertTrue(sessionList.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(projectHeader.waitForExistence(timeout: Self.uiTimeout))

    assertFillsColumn(
      child: projectHeader,
      in: sessionList,
      expectedHorizontalInset: 0,
      tolerance: 10
    )
  }

  func testSidebarFilterSliceFillsColumnAndStartsUnfiltered() throws {
    let app = launch(mode: "preview")

    let sidebarRoot = element(in: app, identifier: Accessibility.sidebarRoot)
    let filtersCard = app.staticTexts["Search & Filters"]
    let searchField = element(in: app, identifier: Accessibility.sidebarSearchField)
    let clearButton = element(in: app, identifier: Accessibility.sidebarClearFiltersButton)

    XCTAssertTrue(sidebarRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(filtersCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(searchField.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertFalse(clearButton.exists)
    XCTAssertTrue(sidebarRoot.exists)
    XCTAssertTrue(filtersCard.exists)
  }

  func testSidebarScrollMovesSessionRowsWhenContentOverflows() throws {
    let app = launch(mode: "preview")

    let sidebarRoot = element(in: app, identifier: Accessibility.sidebarRoot)
    let scrollView = sidebarRoot.descendants(matching: .scrollView).firstMatch
    let sessionRow = element(in: app, identifier: Accessibility.previewSessionRow)

    XCTAssertTrue(sidebarRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(scrollView.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))

    let initialMinY = sessionRow.frame.minY

    for _ in 0..<3 {
      dragUp(in: app, element: scrollView, distanceRatio: 0.44)
      if sessionRow.frame.minY < initialMinY - 20 {
        break
      }
    }

    XCTAssertTrue(
      waitUntil {
        sessionRow.frame.minY < initialMinY - 20
      }
    )
  }

  func testFocusFilterSelectionTogglesAccessibilityState() throws {
    let app = launch(mode: "preview")

    let blockedChip = element(in: app, identifier: Accessibility.blockedChip)
    XCTAssertTrue(blockedChip.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertEqual(blockedChip.value as? String, "not selected")

    tapElement(in: app, identifier: Accessibility.blockedChip)

    XCTAssertEqual(blockedChip.value as? String, "selected")
    XCTAssertTrue(
      element(in: app, identifier: Accessibility.sidebarClearFiltersButton).waitForExistence(
        timeout: Self.uiTimeout
      )
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

    let sessionRow = element(in: app, identifier: Accessibility.previewSessionRow)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapElement(in: app, identifier: Accessibility.previewSessionRow)

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

    let reconnect = element(in: app, identifier: Accessibility.reconnectButton)
    let refresh = element(in: app, identifier: Accessibility.refreshDiagnosticsButton)
    let start = element(in: app, identifier: Accessibility.startDaemonButton)
    let install = element(in: app, identifier: Accessibility.installLaunchAgentButton)
    let remove = element(in: app, identifier: Accessibility.removeLaunchAgentButton)

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

    let preferencesRoot = element(in: app, identifier: Accessibility.preferencesRoot)
    let preferencesPanel = frameElement(in: app, identifier: Accessibility.preferencesPanel)
    let preferencesSidebar = element(in: app, identifier: Accessibility.preferencesSidebar)
    let generalSection = element(in: app, identifier: Accessibility.preferencesGeneralSection)

    XCTAssertTrue(preferencesRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(preferencesPanel.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(preferencesSidebar.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(generalSection.waitForExistence(timeout: Self.uiTimeout))

    let settingsWindow = window(in: app, containing: preferencesPanel)
    XCTAssertTrue(settingsWindow.exists)

    let sidebarTopInset = preferencesSidebar.frame.minY - settingsWindow.frame.minY
    let rowTopInset = generalSection.frame.minY - settingsWindow.frame.minY
    let rowLeadingInset = generalSection.frame.minX - settingsWindow.frame.minX
    let rowInsetInsideSidebar = generalSection.frame.minY - preferencesSidebar.frame.minY

    XCTAssertGreaterThan(
      sidebarTopInset,
      44,
      "Native sidebar list content should start below the traffic lights"
    )
    XCTAssertLessThan(
      sidebarTopInset,
      120,
      "Native sidebar list content should stay reasonably close to the titlebar"
    )
    XCTAssertGreaterThan(rowTopInset, 44, "Sidebar content should start below the traffic lights")
    XCTAssertLessThan(rowTopInset, 120, "Sidebar content should not be pushed too far down")
    XCTAssertGreaterThan(rowLeadingInset, 10, "Sidebar content should stay inset from the leading edge")
    XCTAssertGreaterThan(
      rowInsetInsideSidebar,
      0,
      "Sidebar content should appear inside the native sidebar list container"
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
