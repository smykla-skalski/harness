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
    let persistedBanner = element(in: app, identifier: Accessibility.persistedDataBanner)
    let persistedBannerFrame = frameElement(
      in: app, identifier: Accessibility.persistedDataBannerFrame)
    let sidebarRoot = element(in: app, identifier: Accessibility.sidebarRoot)
    let sidebarContent = frameElement(in: app, identifier: Accessibility.sidebarShellFrame)
    let inspectorRoot = element(in: app, identifier: Accessibility.inspectorRoot)
    let sessionRow = previewSessionTrigger(in: app)
    let observeButton = button(in: app, title: "Observe")
    let endSessionButton = element(in: app, identifier: Accessibility.endSessionButton)
    let createTaskButton = button(in: app, title: "Create Task")
    let taskCard = element(in: app, identifier: Accessibility.taskUICard)
    let workerCard = element(in: app, identifier: Accessibility.workerAgentCard)

    XCTAssertTrue(waitForElement(persistedBanner, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(persistedBannerFrame, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sidebarRoot, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sidebarContent, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(inspectorRoot, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sessionRow, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(observeButton, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(endSessionButton, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(createTaskButton, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(taskCard, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(workerCard, timeout: Self.fastActionTimeout))

    XCTAssertTrue(persistedBanner.label.contains("Daemon is off"))
    XCTAssertTrue(persistedBanner.label.contains("may be stale"))
    XCTAssertEqual(persistedBannerFrame.frame.minX, sidebarContent.frame.maxX, accuracy: 8)
    XCTAssertEqual(persistedBannerFrame.frame.maxX, inspectorRoot.frame.minX, accuracy: 12)
    XCTAssertTrue(sessionRowIsSelected(sessionRow))
    XCTAssertFalse(observeButton.isEnabled)
    XCTAssertFalse(endSessionButton.isEnabled)
    XCTAssertFalse(createTaskButton.isEnabled)
    XCTAssertTrue(taskCard.exists)
    XCTAssertTrue(workerCard.exists)
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
