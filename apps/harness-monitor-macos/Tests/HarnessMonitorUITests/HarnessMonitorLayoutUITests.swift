import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorLayoutUITests: HarnessMonitorUITestCase {
  func testPreviewRecentSessionsMoveIntoDashboardSidebar() throws {
    let app = launch(mode: "preview")
    let dashboardSidebar = element(in: app, identifier: Accessibility.dashboardSidebar)
    let previewSessionRow = sessionTrigger(
      in: app,
      identifier: Accessibility.sessionRow(Accessibility.previewSessionID)
    )

    XCTAssertTrue(dashboardSidebar.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(previewSessionRow.waitForExistence(timeout: Self.actionTimeout))
  }

  func testDashboardRemovesSummaryMetricCards() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"]
    )
    let boardMetricElements = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "harness.board.metric.")
    )

    XCTAssertEqual(
      boardMetricElements.count,
      0,
      "Expected dashboard summary metrics to be removed from the dashboard board cards"
    )
  }

  func testRemovingDashboardSessionRowHidesItImmediately() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard-landing"]
    )
    let boardRoot = element(in: app, identifier: Accessibility.sessionsBoardRoot)
    let sessionRow = sessionTrigger(
      in: app,
      identifier: Accessibility.sessionRow(Accessibility.previewSessionID)
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
      sessionRow.waitForExistence(timeout: Self.actionTimeout),
      "Dashboard sidebar session row should be visible before opening its context menu"
    )

    if rightClickElementReliably(in: app, element: sessionRow) == false {
      recordDiagnosticsSnapshot(in: app, named: "dashboard-row-context-menu-target-missing")
      XCTFail("Dashboard sidebar session rows should expose the native remove-session context menu")
    }

    let removeSessionItem = app.menuItems["Remove Session..."].firstMatch
    if removeSessionItem.waitForExistence(timeout: Self.fastActionTimeout) == false {
      recordDiagnosticsSnapshot(in: app, named: "dashboard-row-context-menu-missing-remove")
      XCTFail(
        """
        Dashboard sidebar session row context menu should expose Remove Session...
        rowExists=\(sessionRow.exists)
        """
      )
    }

    XCTAssertTrue(
      removeSessionItem.exists,
      "Dashboard sidebar session rows should expose Remove Session... in the native context menu"
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
      waitUntil(timeout: Self.fastActionTimeout) { !sessionRow.exists },
      "Removed sessions should disappear from the dashboard sidebar immediately"
    )
  }

  func testDashboardSessionRowDoesNotExposeRawSessionID() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard-landing"]
    )
    let sessionRow = sessionTrigger(
      in: app,
      identifier: Accessibility.sessionRow(Accessibility.previewSessionID)
    )

    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertEqual(
      sessionRow.descendants(matching: .any).matching(
        NSPredicate(format: "label CONTAINS %@", Accessibility.previewSessionID)
      ).count,
      0,
      "Dashboard session rows should not surface raw session IDs in the sidebar"
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
        NSPredicate(format: "label CONTAINS %@", Accessibility.previewSessionID)
      ).count,
      0,
      "Cockpit header should not surface raw session IDs below the session title"
    )
  }

}
