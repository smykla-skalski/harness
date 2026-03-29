import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorLayoutUITests: HarnessMonitorUITestCase {
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

  func testPreferencesOverviewCardsAndActionButtonsShareHeights() throws {
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
