import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class WorkspaceWindowUITests: HarnessMonitorUITestCase, WorkspaceWindowUITestSupporting {
  func testWorkspaceWindowDefaultsToCreatePaneWhenNoSessionsExist() throws {
    let app = launchInCockpitPreview()
    openWorkspaceWindow(in: app)
    let createRow = element(in: app, identifier: Accessibility.agentTuiCreateTab)
    let launchPane = element(in: app, identifier: Accessibility.agentTuiLaunchPane)
    let state = element(in: app, identifier: Accessibility.agentTuiState)
    XCTAssertTrue(waitForElement(createRow, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(launchPane, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(state, timeout: Self.fastActionTimeout))
    XCTAssertTrue(state.label.contains("selection=create"))
  }

  func testWorkspaceWindowDisablesStartingWhenNoSessionIsSelected() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard-landing"
      ]
    )
    openWorkspaceWindow(in: app)

    let startButton = button(in: app, identifier: Accessibility.agentTuiStartButton)
    let banner = element(in: app, identifier: Accessibility.agentTuiSessionActionBanner)
    let newSessionButton = button(in: app, identifier: Accessibility.agentTuiNewSessionButton)

    XCTAssertTrue(waitForElement(startButton, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(banner, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(newSessionButton, timeout: Self.actionTimeout))
    XCTAssertFalse(startButton.isEnabled, "Start should stay disabled until a session is available")
  }

  func testWorkspaceWindowSuppressesStaleRunningTerminalUntilRefreshCompletes() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "agent-tui-single",
        "HARNESS_MONITOR_PREVIEW_AGENT_TUI_REFRESH_STATUS": "exited",
        "HARNESS_MONITOR_PREVIEW_AGENT_TUIS_DELAY_MS": "3000",
      ]
    )
    openWorkspaceWindow(in: app)

    let state = element(in: app, identifier: Accessibility.agentTuiState)
    XCTAssertTrue(waitForElement(state, timeout: Self.fastActionTimeout))
    XCTAssertTrue(
      state.label.contains("selection=create"),
      """
      Workspace window should not render stale running terminals before its first refresh finishes.
      state=\(state.label)
      """
    )

    let sessionRow = element(
      in: app,
      identifier: Accessibility.agentTuiTab("preview-agent-tui-1")
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        sessionRow.exists
      },
      """
      Once refresh completes, the stale terminal should reappear as a disconnected row.
      state=\(state.label)
      """
    )
    tapElement(in: app, identifier: Accessibility.agentTuiTab("preview-agent-tui-1"))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        state.label.contains("selection=session:preview-agent-tui-1")
          && state.label.contains("status=exited")
      },
      """
      Opening the reconciled row should show the exited snapshot instead of a stale live session.
      state=\(state.label)
      """
    )
  }

  func testStartingAgentTuiCreatesAndSelectsSessionRow() throws {
    let app = launchInCockpitPreview()
    openWorkspaceWindow(in: app)
    startAgentTui(in: app, runtimeTitle: "Codex", prompt: "Inspect the cockpit session")
    let sessionRow = element(
      in: app,
      identifier: Accessibility.agentTuiTab("preview-agent-tui-1")
    )
    let sessionPane = element(in: app, identifier: Accessibility.agentTuiSessionPane)
    let state = element(in: app, identifier: Accessibility.agentTuiState)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        sessionRow.exists
          && sessionPane.exists
          && state.label.contains("selection=session:preview-agent-tui-1")
          && state.label.contains("status=running")
          && self.agentTuiActionExists(
            in: app,
            title: "Stop",
            identifier: Accessibility.agentTuiStopButton
          )
      }
    )
  }

  func testCodexSubmitButtonStartsRunAfterPromptEntry() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_CODEX_START": "success"]
    )
    openWorkspaceWindow(in: app)

    tapButton(
      in: app,
      identifier: Accessibility.segmentedOption(
        Accessibility.agentTuiCreateModePicker,
        option: "Codex Run"
      )
    )
    let promptField = editableField(in: app, identifier: Accessibility.workspaceCodexPromptField)
    XCTAssertTrue(waitForElement(promptField, timeout: Self.actionTimeout))
    tapElement(in: app, identifier: Accessibility.workspaceCodexPromptField)
    app.typeKey("a", modifierFlags: .command)
    app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
    promptField.typeText("Start from the explicit click path")
    let submitButton = button(in: app, identifier: Accessibility.workspaceCodexSubmitButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        submitButton.exists && submitButton.isEnabled
      },
      "Start Codex should enable once the prompt field contains non-whitespace text"
    )
    tapButton(in: app, identifier: Accessibility.workspaceCodexSubmitButton)

    let state = element(in: app, identifier: Accessibility.agentTuiState)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        state.label.contains("selection=codex:")
      },
      """
      Clicking Start Codex should launch the run once the prompt has propagated.
      state=\(state.label)
      """
    )
  }

  func testCommandNavigationRoutesBackAndForwardWithinActiveWorkspaceWindowHistory() throws {
    let app = launchInCockpitPreview()
    openWorkspaceWindow(in: app)
    startAgentTui(in: app, runtimeTitle: "Codex", prompt: "exercise command navigation")
    let state = element(in: app, identifier: Accessibility.agentTuiState)
    let createTab = element(in: app, identifier: Accessibility.agentTuiCreateTab)
    let commandRoutingState = element(
      in: app,
      identifier: Accessibility.agentTuiCommandRoutingState
    )
    let backButton = element(in: app, identifier: Accessibility.agentTuiNavigateBackButton)
    let forwardButton = element(in: app, identifier: Accessibility.agentTuiNavigateForwardButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        state.label.contains("selection=session:preview-agent-tui-1")
          && createTab.exists
          && commandRoutingState.exists
          && backButton.exists
          && forwardButton.exists
      }
    )
    tapButton(in: app, identifier: Accessibility.agentTuiCreateTab)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        state.label.contains("selection=create")
          && commandRoutingState.label.contains("scope=agents")
          && commandRoutingState.label.contains("canGoBack=true")
          && commandRoutingState.label.contains("canGoForward=false")
          && backButton.isEnabled
          && !forwardButton.isEnabled
      },
      "Selecting the create tab should move the active Workspace window into its create pane"
    )
    invokeMenuItem(in: app, menu: "Go", title: "Back")
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        state.label.contains("selection=session:preview-agent-tui-1")
          && backButton.isEnabled
          && forwardButton.isEnabled
      },
      """
      Harness Monitor > Back should navigate back inside the active Workspace window history while
      preserving the original create pane behind the restored session.
      state=\(state.label)
      routing=\(commandRoutingState.label)
      backEnabled=\(backButton.isEnabled)
      forwardEnabled=\(forwardButton.isEnabled)
      """
    )
    invokeMenuItem(in: app, menu: "Go", title: "Forward")
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        state.label.contains("selection=create")
          && backButton.isEnabled
          && !forwardButton.isEnabled
      },
      "Harness Monitor > Forward should navigate forward inside the active Workspace window history"
    )
  }
  func testSidebarShowsAllSessionsWithoutOverflow() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "agent-tui-overflow"]
    )
    reopenWorkspaceWindow(in: app)
    for index in 1...6 {
      let sessionRow = element(
        in: app,
        identifier: Accessibility.agentTuiTab("preview-agent-tui-\(index)")
      )
      XCTAssertTrue(
        waitForElement(sessionRow, timeout: Self.actionTimeout),
        "Session row for preview-agent-tui-\(index) should be visible in sidebar"
      )
    }
  }
}
