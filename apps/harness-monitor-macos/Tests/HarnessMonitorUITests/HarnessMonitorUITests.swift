import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorUITests: XCTestCase {
  static let launchModeKey = "HARNESS_MONITOR_LAUNCH_MODE"
  static let uiTimeout: TimeInterval = 10

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

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
    let sessionRow = app.buttons.matching(identifier: Accessibility.previewSessionRow).firstMatch

    XCTAssertTrue(inspectorRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))

    tapButton(in: app, identifier: Accessibility.previewSessionRow)

    XCTAssertTrue(sessionInspectorCard.waitForExistence(timeout: Self.uiTimeout))
    assertFillsColumn(
      child: sessionInspectorCard,
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
    XCTAssertLessThan(daemonCard.frame.height, 320)
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

  func testSessionCockpitTaskAndAgentCardsShareHeight() throws {
    let app = launch(mode: "preview")

    let sessionRow = app.buttons.matching(identifier: Accessibility.previewSessionRow).firstMatch
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    tapButton(in: app, identifier: Accessibility.previewSessionRow)

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

  func testPreferencesOverviewCardsAndActionButtonsShareHeights() throws {
    let app = launch(mode: "preview")

    let preferencesButton = toolbarButton(in: app, identifier: Accessibility.preferencesButton)
    XCTAssertTrue(preferencesButton.waitForExistence(timeout: Self.uiTimeout))
    preferencesButton.tap()

    let endpointCard = element(in: app, identifier: Accessibility.preferencesEndpointCard)
    let versionCard = element(in: app, identifier: Accessibility.preferencesVersionCard)
    let launchdCard = element(in: app, identifier: Accessibility.preferencesLaunchdCard)
    let cachedSessionsCard = element(
      in: app, identifier: Accessibility.preferencesCachedSessionsCard)

    XCTAssertTrue(endpointCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(versionCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(launchdCard.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(cachedSessionsCard.waitForExistence(timeout: Self.uiTimeout))

    assertSameRow([endpointCard, versionCard, launchdCard, cachedSessionsCard], tolerance: 10)
    assertEqualHeights(
      [endpointCard, versionCard, launchdCard, cachedSessionsCard],
      tolerance: 10
    )

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

  func testSidebarAndBoardActionButtonsStayCompact() throws {
    let app = launch(mode: "empty")

    let sidebarStart = frameElement(in: app, identifier: Accessibility.sidebarStartButtonFrame)
    let sidebarInstall = frameElement(in: app, identifier: Accessibility.sidebarInstallButtonFrame)
    let boardStart = frameElement(in: app, identifier: Accessibility.onboardingStartButtonFrame)
    let boardInstall = frameElement(in: app, identifier: Accessibility.onboardingInstallButtonFrame)
    let boardRefresh = frameElement(in: app, identifier: Accessibility.onboardingRefreshButtonFrame)

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
