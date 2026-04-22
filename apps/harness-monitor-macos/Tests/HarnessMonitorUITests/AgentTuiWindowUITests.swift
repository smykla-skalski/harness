import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class AgentTuiWindowUITests: HarnessMonitorUITestCase {
  func testAgentTuiWindowDefaultsToCreatePaneWhenNoSessionsExist() throws {
    let app = launchInCockpitPreview()

    openAgentTuiWindow(in: app)

    let createRow = element(in: app, identifier: Accessibility.agentTuiCreateTab)
    let launchPane = element(in: app, identifier: Accessibility.agentTuiLaunchPane)
    let state = element(in: app, identifier: Accessibility.agentTuiState)

    XCTAssertTrue(waitForElement(createRow, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(launchPane, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(state, timeout: Self.fastActionTimeout))
    XCTAssertTrue(state.label.contains("selection=create"))
  }

  func testStartingAgentTuiCreatesAndSelectsSessionRow() throws {
    let app = launchInCockpitPreview()

    openAgentTuiWindow(in: app)
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

  func testCommandNavigationRoutesBackAndForwardWithinActiveAgentTuiWindowHistory() throws {
    let app = launchInCockpitPreview()

    openAgentTuiWindow(in: app)
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
          && commandRoutingState.label.contains("scope=agentTui")
          && commandRoutingState.label.contains("canGoBack=true")
          && commandRoutingState.label.contains("canGoForward=false")
          && backButton.isEnabled
          && !forwardButton.isEnabled
      },
      "Selecting the create tab should move the active Agents window into its create pane"
    )

    invokeHarnessMonitorMenuItem(in: app, title: "Back")

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        state.label.contains("selection=session:preview-agent-tui-1")
          && backButton.isEnabled
          && forwardButton.isEnabled
      },
      """
      Harness Monitor > Back should navigate back inside the active Agents window history while
      preserving the original create pane behind the restored session.
      state=\(state.label)
      routing=\(commandRoutingState.label)
      backEnabled=\(backButton.isEnabled)
      forwardEnabled=\(forwardButton.isEnabled)
      """
    )

    invokeHarnessMonitorMenuItem(in: app, title: "Forward")

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        state.label.contains("selection=create")
          && backButton.isEnabled
          && !forwardButton.isEnabled
      },
      "Harness Monitor > Forward should navigate forward inside the active Agents window history"
    )
  }

  func testSidebarShowsAllSessionsWithoutOverflow() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "agent-tui-overflow"]
    )

    reopenAgentTuiWindow(in: app)

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

  func testCreatePaneSidebarChromeMatchesNativeInsetLayout() throws {
    let app = launchInCockpitPreview()

    openAgentTuiWindow(in: app)

    let createRow = element(in: app, identifier: Accessibility.agentTuiCreateTab)
    XCTAssertTrue(waitForElement(createRow, timeout: Self.actionTimeout))

    let agentWindow = window(in: app, containing: createRow)
    XCTAssertTrue(agentWindow.exists)

    let toolbar = agentWindow.toolbars.firstMatch
    XCTAssertTrue(waitForElement(toolbar, timeout: Self.actionTimeout))
    XCTAssertGreaterThan(
      toolbar.buttons.count,
      0,
      "Agents window should expose toolbar controls in native window chrome"
    )

    let leadingToolbarButton = toolbar.buttons.element(boundBy: 0)
    XCTAssertTrue(leadingToolbarButton.exists)

    let toolbarLeadingInset = leadingToolbarButton.frame.minX - agentWindow.frame.minX
    let rowTopInset = createRow.frame.minY - agentWindow.frame.minY

    XCTAssertLessThan(
      toolbarLeadingInset,
      176,
      "Agents sidebar toggle should stay near the leading window chrome"
    )
    XCTAssertGreaterThan(
      rowTopInset,
      44,
      "Agents sidebar content should start below the native toolbar controls"
    )
    XCTAssertLessThan(
      rowTopInset,
      120,
      "Agents sidebar content should stay visually close to the toolbar"
    )
  }

  func testWrapToggleSwitchesViewportMode() throws {
    let app = launchInCockpitPreview()

    openAgentTuiWindow(in: app)
    startAgentTui(in: app, runtimeTitle: "Codex", prompt: "wrap test")

    let state = element(in: app, identifier: Accessibility.agentTuiState)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        state.label.contains("wrap=false")
      },
      "Session should start with wrap disabled"
    )

    app.typeKey("l", modifierFlags: .command)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        state.label.contains("wrap=true")
      },
      "After Cmd+L, wrap should be enabled"
    )

    app.typeKey("l", modifierFlags: .command)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        state.label.contains("wrap=false")
      },
      "After Cmd+L again, wrap should be disabled"
    )
  }

  func testCommandReturnSendsAgentInputFromEditor() throws {
    let app = launchInCockpitPreview()

    openAgentTuiWindow(in: app)
    startAgentTui(in: app, runtimeTitle: "Codex", prompt: "command return send")

    let inputField = editableField(in: app, identifier: Accessibility.agentTuiInputField)
    XCTAssertTrue(waitForElement(inputField, timeout: Self.actionTimeout))

    inputField.click()
    inputField.typeText("cmd return send")
    app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .command)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        let value = inputField.value as? String
        return value?.isEmpty == true
      },
      "Cmd+Return should send the current input and clear the editor"
    )
  }

  func testDraggingViewportDividerResizesLiveTerminal() throws {
    let app = launchInCockpitPreview()

    openAgentTuiWindow(in: app)
    startAgentTui(in: app, runtimeTitle: "Codex", prompt: "resize with divider")

    let viewport = element(in: app, identifier: Accessibility.agentTuiViewport)
    let controls = element(in: app, identifier: Accessibility.agentTuiControls)
    let state = element(in: app, identifier: Accessibility.agentTuiState)

    XCTAssertTrue(waitForElement(viewport, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(controls, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(state, timeout: Self.actionTimeout))

    guard let initialSize = agentTuiSize(from: state.label) else {
      XCTFail("Expected the Agents state marker to expose the live size")
      return
    }
    let initialHeight = viewport.frame.height

    dragViewportDivider(in: app, viewport: viewport, controls: controls, verticalOffset: 120)

    let didResize = waitUntil(timeout: Self.actionTimeout) {
      guard let updatedSize = self.agentTuiSize(from: state.label) else {
        return false
      }
      return viewport.frame.height >= initialHeight + 24
        && updatedSize.rows > initialSize.rows
    }

    let finalHeight = viewport.frame.height
    let finalState = state.label
    XCTAssertTrue(
      didResize,
      """
      Dragging the viewport divider should resize the output pane and propagate the new terminal rows.
      Initial height: \(initialHeight)
      Final height: \(finalHeight)
      Initial size: \(initialSize.rows)x\(initialSize.cols)
      Final state: \(finalState)
      """
    )
  }

  func testStoppedSessionHidesLiveControlsButKeepsTranscriptAction() throws {
    let app = launchInCockpitPreview()

    openAgentTuiWindow(in: app)
    startAgentTui(in: app, runtimeTitle: "Codex", prompt: "stop after start")

    tapButton(in: app, title: "Stop")

    let state = element(in: app, identifier: Accessibility.agentTuiState)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        state.label.contains("status=stopped")
          && self.agentTuiActionExists(
            in: app,
            title: "Transcript",
            identifier: Accessibility.agentTuiRevealTranscriptButton
          )
          && !self.agentTuiActionExists(
            in: app,
            title: "Stop",
            identifier: Accessibility.agentTuiStopButton
          )
          && !self.agentTuiActionExists(
            in: app,
            title: "Send",
            identifier: Accessibility.agentTuiSendButton
          )
          && !self.agentTuiActionExists(
            in: app,
            title: "Apply Size",
            identifier: Accessibility.agentTuiResizeButton
          )
      }
    )
  }

  func testTerminalSizeRemainsStableAfterStartAndSelection() throws {
    let app = launchInCockpitPreview()

    openAgentTuiWindow(in: app)
    startAgentTui(in: app, runtimeTitle: "Claude", prompt: "viewport size test")

    let state = element(in: app, identifier: Accessibility.agentTuiState)
    XCTAssertTrue(waitForElement(state, timeout: Self.actionTimeout))

    guard let initialSize = agentTuiSize(from: state.label) else {
      XCTFail("State marker should expose terminal size after start")
      return
    }

    XCTAssertNotEqual(
      initialSize.rows,
      30,
      "Terminal should use viewport-derived size, not daemon default 30 rows"
    )

    tapButton(in: app, identifier: Accessibility.agentTuiCreateTab)
    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        state.label.contains("selection=create")
      }
    )

    let sessionRow = element(
      in: app,
      identifier: Accessibility.agentTuiTab("preview-agent-tui-1")
    )
    XCTAssertTrue(waitForElement(sessionRow, timeout: Self.fastActionTimeout))
    sessionRow.click()

    let sizeStable = waitUntil(timeout: Self.actionTimeout) {
      guard let currentSize = self.agentTuiSize(from: state.label) else {
        return false
      }
      return state.label.contains("selection=terminal:preview-agent-tui-1")
        && currentSize.rows == initialSize.rows
        && currentSize.cols == initialSize.cols
    }

    let finalState = state.label
    XCTAssertTrue(
      sizeStable,
      """
      Terminal size should remain stable after switching away and back.
      Initial: \(initialSize.rows)x\(initialSize.cols)
      Final state: \(finalState)
      """
    )
  }

}
