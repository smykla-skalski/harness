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

  func testDashboardUsesSidebarFooterSummaryInsteadOfMetricCards() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )
    let boardRoot = element(in: app, identifier: Accessibility.sessionsBoardRoot)
    let sidebarFooterState = element(in: app, identifier: Accessibility.sidebarFooterState)
    let boardMetricElements = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "harness.board.metric.")
    )

    XCTAssertTrue(boardRoot.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sidebarFooterState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      sidebarFooterState.label,
      "projects=1, sessions=1, openWork=2, blocked=1"
    )
    XCTAssertEqual(
      boardMetricElements.count,
      0,
      "Expected dashboard summary metrics to render only in the sidebar footer"
    )
  }

  func testRemovingDashboardSessionCardHidesItImmediately() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard-landing"]
    )
    let boardRoot = element(in: app, identifier: Accessibility.sessionsBoardRoot)
    let sessionCard = sessionTrigger(
      in: app,
      identifier: Accessibility.dashboardSessionCard("sess1234")
    )
    let sessionCardFrame = frameElement(
      in: app,
      identifier: Accessibility.dashboardSessionCardFrame("sess1234")
    )
    let cockpitScrollView = frameElement(
      in: app,
      identifier: Accessibility.sessionCockpitScrollView
    )

    XCTAssertTrue(
      boardRoot.waitForExistence(timeout: Self.actionTimeout),
      """
      Dashboard root should be visible before exercising dashboard card actions
      cockpitVisible=\(cockpitScrollView.exists)
      """
    )
    XCTAssertTrue(
      sessionCardFrame.waitForExistence(timeout: Self.actionTimeout),
      "Dashboard session card frame should be visible before opening its context menu"
    )

    let contextMenuTarget = sessionCard.exists ? sessionCard : sessionCardFrame
    if rightClickElementReliably(in: app, element: contextMenuTarget) == false {
      recordDiagnosticsSnapshot(in: app, named: "dashboard-card-context-menu-target-missing")
      XCTFail("Dashboard session cards should expose the native remove-session context menu")
    }

    let removeSessionItem = app.menuItems["Remove Session..."].firstMatch
    if removeSessionItem.waitForExistence(timeout: Self.fastActionTimeout) == false {
      recordDiagnosticsSnapshot(in: app, named: "dashboard-card-context-menu-missing-remove")
      XCTFail(
        """
        Dashboard session card context menu should expose Remove Session...
        buttonExists=\(sessionCard.exists)
        frameExists=\(sessionCardFrame.exists)
        """
      )
    }

    XCTAssertTrue(
      removeSessionItem.exists,
      "Dashboard session cards should expose Remove Session... in the native context menu"
    )
    removeSessionItem.tap()

    let confirmButton = confirmationDialogButton(in: app, title: "Remove Session Now")
    XCTAssertTrue(confirmButton.waitForExistence(timeout: Self.fastActionTimeout))
    XCTAssertTrue(app.staticTexts["Remove Session?"].exists)
    confirmButton.tap()

    XCTAssertTrue(
      waitForAppTraceEvents(
        ["confirm-tapped", "dismissed", "dispatch-remove-session"],
        timeout: Self.fastActionTimeout
      ),
      "Dashboard remove-session flow should dispatch the destructive action after dialog dismissal"
    )

    XCTAssertTrue(waitForElement(boardRoot, timeout: Self.fastActionTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) { !sessionCardFrame.exists },
      "Removed sessions should disappear from the dashboard card list immediately"
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
    let sessionRow = previewSessionTrigger(in: app)
    let observeButton = button(in: app, title: "Observe")
    let endSessionButton = element(in: app, identifier: Accessibility.endSessionButton)
    let createTaskButton = button(in: app, identifier: Accessibility.sessionTaskCreateOpenButton)
    let taskCard = element(in: app, identifier: Accessibility.taskUICard)
    let workerCard = element(in: app, identifier: Accessibility.workerAgentCard)

    XCTAssertTrue(waitForElement(persistedBanner, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(persistedBannerFrame, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sidebarRoot, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sidebarContent, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(sessionRow, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(observeButton, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(endSessionButton, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(createTaskButton, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(taskCard, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(workerCard, timeout: Self.fastActionTimeout))

    XCTAssertTrue(persistedBanner.label.contains("Daemon is off"))
    XCTAssertTrue(persistedBanner.label.contains("may be stale"))
    XCTAssertEqual(persistedBannerFrame.frame.minX, sidebarContent.frame.maxX, accuracy: 8)
    XCTAssertTrue(sessionRowIsSelected(sessionRow))
    XCTAssertFalse(observeButton.isEnabled)
    XCTAssertFalse(endSessionButton.isEnabled)
    XCTAssertFalse(createTaskButton.isEnabled)
    XCTAssertTrue(taskCard.exists)
    XCTAssertTrue(workerCard.exists)
  }

  func testEmptyCockpitKeepsControlPlaneActionsAvailable() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "empty-cockpit"]
    )
    let observeButton = button(in: app, title: "Observe")
    let endSessionButton = button(in: app, title: "End Session")
    let createTaskTitleField = editableField(
      in: app,
      identifier: Accessibility.createTaskTitleField
    )
    let createTaskButton = button(in: app, identifier: Accessibility.createTaskButton)

    XCTAssertTrue(waitForElement(observeButton, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(endSessionButton, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(createTaskTitleField, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(createTaskButton, timeout: Self.fastActionTimeout))

    XCTAssertTrue(observeButton.isEnabled)
    XCTAssertTrue(endSessionButton.isEnabled)

    tapElement(in: app, identifier: Accessibility.createTaskTitleField)
    app.typeText("Actorless task should enable")

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) { createTaskButton.isEnabled }
    )
  }

  func testCockpitNewTaskButtonSharesTasksHeaderRow() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )
    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    let headerCardFrame = frameElement(
      in: app, identifier: Accessibility.sessionHeaderCardFrame)
    let tasksHeaderFrame = frameElement(
      in: app, identifier: Accessibility.sessionTaskListHeaderFrame)
    let createTaskButton = button(in: app, identifier: Accessibility.sessionTaskCreateOpenButton)
    let createTaskButtonFrame = frameElement(
      in: app, identifier: "\(Accessibility.sessionTaskCreateOpenButton).frame")

    XCTAssertTrue(waitForElement(headerCardFrame, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(tasksHeaderFrame, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(createTaskButton, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(createTaskButtonFrame, timeout: Self.actionTimeout))

    XCTAssertGreaterThan(
      createTaskButtonFrame.frame.minY,
      headerCardFrame.frame.maxY,
      "New Task should render in the tasks section instead of the cockpit header"
    )
    XCTAssertEqual(
      createTaskButtonFrame.frame.maxX,
      tasksHeaderFrame.frame.maxX,
      accuracy: 12,
      "New Task should align with the trailing edge of the tasks header row"
    )
    XCTAssertEqual(
      createTaskButtonFrame.frame.midY,
      tasksHeaderFrame.frame.midY,
      accuracy: 18,
      "New Task should share the tasks header row"
    )
  }

  func testCockpitSessionStatusCornerFollowsContentScroll() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )
    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    let statusCorner = element(in: app, identifier: Accessibility.sessionStatusCorner)
    let statusCornerFrame = frameElement(
      in: app, identifier: Accessibility.sessionStatusCornerFrame)
    let headerCardFrame = frameElement(
      in: app, identifier: Accessibility.sessionHeaderCardFrame)
    let contentRoot = frameElement(in: app, identifier: Accessibility.contentRootFrame)

    XCTAssertTrue(waitForElement(statusCorner, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(statusCornerFrame, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(headerCardFrame, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(contentRoot, timeout: Self.actionTimeout))

    let initialHeaderFrame = headerCardFrame.frame
    let initialFrame = statusCornerFrame.frame

    XCTAssertEqual(
      initialFrame.minX,
      contentRoot.frame.minX,
      accuracy: 4,
      "Status corner should start at the detail content leading edge"
    )
    XCTAssertEqual(
      initialFrame.minY,
      contentRoot.frame.minY,
      accuracy: 4,
      "Status corner should start at the detail content top edge"
    )
    XCTAssertGreaterThan(
      initialHeaderFrame.minY,
      initialFrame.minY + 20,
      "Cockpit header should sit below the status corner instead of underneath it"
    )
    XCTAssertLessThan(
      initialHeaderFrame.minY,
      initialFrame.minY + 40,
      "Cockpit header should stay close to the status corner instead of leaving a large empty gap"
    )
    XCTAssertTrue(
      statusCorner.label.contains("Session status"),
      "Status corner should carry session status accessibility label"
    )

    for _ in 0..<6 {
      dragUp(in: app, element: headerCardFrame, distanceRatio: 0.4)
      if headerCardFrame.frame.minY < initialHeaderFrame.minY - 40 {
        break
      }
    }

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        let currentHeaderFrame = headerCardFrame.frame
        let currentStatusFrame = statusCornerFrame.frame
        return currentHeaderFrame.minY < initialHeaderFrame.minY - 40
          && currentStatusFrame.minY < initialFrame.minY - 40
      },
      "Status corner should scroll away with the cockpit content"
    )
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

  func testTaskDropPreviewTaskCardHidesContextAndKeepsStatusRowVisible() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "task-drop"]
    )

    let taskCard = element(in: app, identifier: Accessibility.taskDropQueueCard)
    let workerCard = element(in: app, identifier: Accessibility.workerAgentCard)
    let context = app.staticTexts["Drag this open task onto the busy worker card."]

    XCTAssertTrue(taskCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(workerCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertFalse(
      context.exists,
      "Cockpit task cards should keep the compact two-row layout and hide task context"
    )
    XCTAssertLessThan(
      taskCard.frame.height,
      workerCard.frame.height,
      "Compact task cards should stay shorter than the full worker cards in the same cockpit grid"
    )
  }

}
