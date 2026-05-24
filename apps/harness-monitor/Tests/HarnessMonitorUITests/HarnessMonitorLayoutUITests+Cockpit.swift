import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

extension HarnessMonitorLayoutUITests {
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

  func testSessionCreateHeaderStartsBelowToolbarChrome() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )
    let sessionRow = previewSessionTrigger(in: app)
    let sessionWindow = element(in: app, identifier: Accessibility.sessionWindowShell)
    recordDiagnosticsTrace(
      event: "session-create-mode-picker.preflight",
      app: app,
      details: [
        "session_window_exists_initial": String(sessionWindow.exists),
        "preview_session_row_exists_initial": String(sessionRow.exists),
      ]
    )

    if !waitForElement(sessionWindow, timeout: Self.fastActionTimeout) {
      if sessionRow.waitForExistence(timeout: Self.actionTimeout) == false {
        recordDiagnosticsSnapshot(in: app, named: "session-create-mode-picker-session-row-missing")
        XCTFail("Preview session row should exist before opening the session window")
      }
      tapPreviewSession(in: app)
      recordDiagnosticsTrace(
        event: "session-create-mode-picker.session-opened",
        app: app,
        details: [
          "session_window_exists_after_open": String(sessionWindow.exists)
        ]
      )
      if waitForElement(sessionWindow, timeout: Self.actionTimeout) == false {
        recordDiagnosticsSnapshot(
          in: app, named: "session-create-mode-picker-session-window-missing")
        XCTFail("Session window should open before entering create mode")
      }
    }

    app.activate()
    recordDiagnosticsTrace(
      event: "session-create-mode-picker.shortcut.begin",
      app: app
    )
    app.typeKey("a", modifierFlags: [.command, .option])
    recordDiagnosticsTrace(
      event: "session-create-mode-picker.shortcut.end",
      app: app
    )

    let createProviderPane = element(
      in: app,
      identifier: Accessibility.sessionWindowCreateProviderPane
    )
    if waitForElement(createProviderPane, timeout: Self.actionTimeout) == false {
      recordDiagnosticsSnapshot(in: app, named: "session-create-provider-pane-missing")
      XCTFail("Provider pane should appear after opening the New Agent flow")
    }

    let window = mainWindow(in: app)
    let topInset = createProviderPane.frame.minY - window.frame.minY
    let diagnostics = """
      window: \(window.frame)
      createProviderPane: \(createProviderPane.frame)
      topInset: \(topInset)
      """
    XCTAssertGreaterThan(topInset, 72, diagnostics)
    XCTAssertLessThan(topInset, 140, diagnostics)
  }
}
