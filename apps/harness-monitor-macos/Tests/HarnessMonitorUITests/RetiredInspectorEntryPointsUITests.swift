import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class RetiredInspectorEntryPointsUITests: HarnessMonitorUITestCase {
  func testCreateTaskEntryPoints() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    verifyCreateTaskSheet(in: app)
  }

  func testAllRetiredInspectorEntryPoints() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    verifySignalDetailSheet(in: app)
    verifyCreateTaskSheet(in: app)
    verifyLeaderTransferSheet(in: app)
    verifyDecisionsObserverFocus(in: app)
    openAgentsWindow(in: app)
    selectFirstAgentsTask(in: app)
    verifyReviewPanelReachable(in: app)
    verifyTaskActionsSheet(in: app)
  }
}

extension RetiredInspectorEntryPointsUITests {
  fileprivate func verifySignalDetailSheet(in app: XCUIApplication) {
    let signalCard = button(in: app, identifier: Accessibility.previewSignalCard)
    XCTAssertTrue(
      signalCard.waitForExistence(timeout: Self.uiTimeout),
      "Cockpit signal card should render in cockpit preview"
    )
    tapButton(in: app, identifier: Accessibility.previewSignalCard)

    let sheet = element(in: app, identifier: Accessibility.signalDetailSheet)
    XCTAssertTrue(
      sheet.waitForExistence(timeout: Self.actionTimeout),
      "Signal detail sheet should appear after tapping the cockpit signal card"
    )

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !sheet.exists },
      "Signal detail sheet should dismiss on Escape"
    )
  }

  fileprivate func verifyCreateTaskSheet(in app: XCUIApplication) {
    let newTaskButton = button(in: app, identifier: Accessibility.createTaskOpenButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        newTaskButton.exists && !newTaskButton.frame.isEmpty
      },
      "Session header should expose a New Task button"
    )
    tapButton(in: app, identifier: Accessibility.createTaskOpenButton)

    let sheet = element(in: app, identifier: Accessibility.createTaskSheet)
    XCTAssertTrue(
      sheet.waitForExistence(timeout: Self.actionTimeout),
      "Create task sheet should appear after tapping New Task"
    )

    let titleField = editableField(in: app, identifier: Accessibility.createTaskTitleField)
    XCTAssertTrue(
      titleField.waitForExistence(timeout: Self.actionTimeout),
      "Create task sheet should expose the title field"
    )

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !sheet.exists },
      "Create task sheet should dismiss on Escape"
    )

    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(
      sheet.waitForExistence(timeout: Self.actionTimeout),
      "Create task sheet should appear after pressing Cmd+T"
    )

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !sheet.exists },
      "Create task sheet should dismiss after the Cmd+T entry point as well"
    )
  }

  fileprivate func verifyLeaderTransferSheet(in app: XCUIApplication) {
    let openButton = button(in: app, identifier: Accessibility.leaderTransferOpenButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        openButton.exists && !openButton.frame.isEmpty
      },
      "Cockpit header should expose a Transfer Leadership button when multiple agents exist"
    )
    tapElement(in: app, identifier: Accessibility.leaderTransferOpenButton)

    let sheet = element(in: app, identifier: Accessibility.leaderTransferSheet)
    XCTAssertTrue(
      sheet.waitForExistence(timeout: Self.actionTimeout),
      "Leader transfer sheet should appear after tapping the header button"
    )

    let picker = popUpButton(in: app, identifier: Accessibility.leaderTransferPicker)
    XCTAssertTrue(
      picker.waitForExistence(timeout: Self.actionTimeout),
      "Leader transfer sheet should expose the new leader picker"
    )

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !sheet.exists },
      "Leader transfer sheet should dismiss on Escape"
    )
  }

  fileprivate func verifyDecisionsObserverFocus(in app: XCUIApplication) {
    let summaryCard = element(in: app, identifier: Accessibility.observeSummaryButton)
    XCTAssertTrue(
      summaryCard.waitForExistence(timeout: Self.actionTimeout),
      "Observer summary card should render in cockpit preview"
    )
    tapElement(in: app, identifier: Accessibility.observeSummaryButton)

    let decisionsWindow = element(in: app, identifier: Accessibility.decisionsWindow)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { decisionsWindow.exists },
      "Decisions window should open after tapping the cockpit observer summary"
    )
    let observerPanel = element(in: app, identifier: Accessibility.decisionsObserverPanel)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { observerPanel.exists },
      "Observer summary panel should render in the decisions window after focus"
    )

    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !decisionsWindow.exists },
      "Decisions window should close on Cmd+W"
    )
  }

  fileprivate func openAgentsWindow(in app: XCUIApplication) {
    app.activate()
    let trigger = button(in: app, identifier: Accessibility.agentsButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        trigger.exists && !trigger.frame.isEmpty
      },
      "Cockpit Agents action button should be visible"
    )
    tapElement(in: app, identifier: Accessibility.agentsButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        self.element(in: app, identifier: Accessibility.agentTuiLaunchPane).exists
          || self.element(in: app, identifier: Accessibility.agentTuiSessionPane).exists
          || self.button(in: app, identifier: Accessibility.agentsTaskTab("task-ui")).exists
      },
      "Agents window should open after tapping the cockpit Agents action"
    )
  }

  fileprivate func selectFirstAgentsTask(in app: XCUIApplication) {
    let taskTab = button(in: app, identifier: Accessibility.agentsTaskTab("task-ui"))
    let deadline = Date.now.addingTimeInterval(Self.actionTimeout)
    while Date.now < deadline, !(taskTab.exists && !taskTab.frame.isEmpty) {
      let scrollTarget = mainWindow(in: app)
      dragUp(in: app, element: scrollTarget, distanceRatio: 0.18)
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
    }
    XCTAssertTrue(
      taskTab.exists && !taskTab.frame.isEmpty,
      "Agents sidebar should expose the preview task row"
    )
    tapElement(in: app, identifier: Accessibility.agentsTaskTab("task-ui"))
    let detailCard = element(in: app, identifier: Accessibility.agentsTaskCard)
    XCTAssertTrue(
      detailCard.waitForExistence(timeout: Self.actionTimeout),
      "Agents task detail pane should render after selecting a task"
    )
  }

  fileprivate func verifyReviewPanelReachable(in app: XCUIApplication) {
    let manageButton = button(in: app, identifier: Accessibility.manageTaskOpenButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        manageButton.exists && !manageButton.frame.isEmpty
      },
      "Manage Task button should be reachable beneath the review panel"
    )
  }

  fileprivate func verifyTaskActionsSheet(in app: XCUIApplication) {
    tapElement(in: app, identifier: Accessibility.manageTaskOpenButton)
    let sheet = element(in: app, identifier: Accessibility.taskActionsSheet)
    XCTAssertTrue(
      sheet.waitForExistence(timeout: Self.actionTimeout),
      "Task actions sheet should appear after tapping Manage Task"
    )

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !sheet.exists },
      "Task actions sheet should dismiss on Escape"
    )
  }
}
