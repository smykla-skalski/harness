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

  func testDashboardUsesSidebarFooterStatusStripInsteadOfMetricCards() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )
    let sidebarFooterState = element(in: app, identifier: Accessibility.sidebarFooterState)
    let boardMetricElements = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "harness.board.metric.")
    )

    XCTAssertTrue(sidebarFooterState.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      sidebarFooterState.label,
      "bridge=stopped, mcp=unavailable"
    )
    XCTAssertEqual(
      boardMetricElements.count,
      0,
      "Expected dashboard summary metrics to be removed from the dashboard board cards"
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

  func testDashboardSessionCardDoesNotExposeRawSessionID() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard-landing"]
    )
    let sessionCard = sessionTrigger(
      in: app,
      identifier: Accessibility.dashboardSessionCard("sess1234")
    )

    XCTAssertTrue(sessionCard.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      sessionCard.descendants(matching: .any).matching(
        NSPredicate(format: "label CONTAINS %@", "sess1234")
      ).count,
      0,
      "Dashboard session cards should not surface raw session IDs below the session title"
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

  func testCockpitHeaderDoesNotExposeRawSessionID() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )
    let sessionRow = previewSessionTrigger(in: app)
    let headerCard = element(in: app, identifier: Accessibility.sessionHeaderCard)

    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)
    XCTAssertTrue(waitForElement(headerCard, timeout: Self.actionTimeout))
    XCTAssertEqual(
      headerCard.descendants(matching: .any).matching(
        NSPredicate(format: "label CONTAINS %@", "sess1234")
      ).count,
      0,
      "Cockpit header should not surface raw session IDs below the session title"
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

  func testCockpitNewAgentButtonSharesAgentsHeaderRow() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )
    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    let headerCardFrame = frameElement(
      in: app, identifier: Accessibility.sessionHeaderCardFrame)
    let agentsHeaderFrame = frameElement(
      in: app, identifier: Accessibility.sessionAgentListHeaderFrame)
    let createAgentButton = button(in: app, identifier: Accessibility.sessionAgentCreateOpenButton)
    let createAgentButtonFrame = frameElement(
      in: app, identifier: "\(Accessibility.sessionAgentCreateOpenButton).frame")

    XCTAssertTrue(waitForElement(headerCardFrame, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(agentsHeaderFrame, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(createAgentButton, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(createAgentButtonFrame, timeout: Self.actionTimeout))

    XCTAssertGreaterThan(
      createAgentButtonFrame.frame.minY,
      headerCardFrame.frame.maxY,
      "New Agent should render in the agents section instead of the cockpit header"
    )
    XCTAssertEqual(
      createAgentButtonFrame.frame.maxX,
      agentsHeaderFrame.frame.maxX,
      accuracy: 12,
      "New Agent should align with the trailing edge of the agents header row"
    )
    XCTAssertEqual(
      createAgentButtonFrame.frame.midY,
      agentsHeaderFrame.frame.midY,
      accuracy: 18,
      "New Agent should share the agents header row"
    )
  }

  func testCockpitSectionsStayWithinContentColumn() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )
    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    let contentRoot = frameElement(in: app, identifier: Accessibility.contentRootFrame)
    let headerCardFrame = frameElement(
      in: app, identifier: Accessibility.sessionHeaderCardFrame)
    let tasksHeaderFrame = frameElement(
      in: app, identifier: Accessibility.sessionTaskListHeaderFrame)
    let agentsHeaderFrame = frameElement(
      in: app, identifier: Accessibility.sessionAgentListHeaderFrame)
    let createTaskButtonFrame = frameElement(
      in: app, identifier: "\(Accessibility.sessionTaskCreateOpenButton).frame")
    let createAgentButtonFrame = frameElement(
      in: app, identifier: "\(Accessibility.sessionAgentCreateOpenButton).frame")

    XCTAssertTrue(waitForElement(contentRoot, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(headerCardFrame, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(tasksHeaderFrame, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(agentsHeaderFrame, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(createTaskButtonFrame, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(createAgentButtonFrame, timeout: Self.actionTimeout))

    assertFillsColumn(
      child: headerCardFrame,
      in: contentRoot,
      expectedHorizontalInset: 24,
      tolerance: 8
    )

    let trailingLimit = contentRoot.frame.maxX - 24
    XCTAssertLessThanOrEqual(
      tasksHeaderFrame.frame.maxX,
      trailingLimit + 8,
      "Tasks header should stay within the cockpit content column"
    )
    XCTAssertLessThanOrEqual(
      agentsHeaderFrame.frame.maxX,
      trailingLimit + 8,
      "Agents header should stay within the cockpit content column"
    )
    XCTAssertLessThanOrEqual(
      createTaskButtonFrame.frame.maxX,
      trailingLimit + 8,
      "New Task should stay within the cockpit content column"
    )
    XCTAssertLessThanOrEqual(
      createAgentButtonFrame.frame.maxX,
      trailingLimit + 8,
      "New Agent should stay within the cockpit content column"
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

}
