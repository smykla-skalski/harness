import CoreGraphics
import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

extension WorkspaceWindowUITests {
  func testWrapToggleSwitchesViewportMode() throws {
    let app = launchInCockpitPreview()
    openWorkspaceWindow(in: app)
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
    openWorkspaceWindow(in: app)
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

  func testRapidKeyStripTapsShowPendingHintBeforeIdleFlush() throws {
    let app = launchInCockpitPreview()
    openWorkspaceWindow(in: app)
    startAgentTui(in: app, runtimeTitle: "Codex", prompt: "buffer key strip input")
    tapButton(in: app, identifier: Accessibility.agentTuiKeyButton("enter"))
    tapButton(in: app, identifier: Accessibility.agentTuiKeyButton("arrow-down"))
    let pendingHint = element(in: app, identifier: Accessibility.agentTuiKeyQueueHint)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        pendingHint.exists
          && pendingHint.label.contains("↩")
          && pendingHint.label.contains("↓")
      },
      "Rapid key-strip taps should show a pending queue hint before the idle flush runs"
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        !pendingHint.exists
          && self.agentTuiViewportContainsText(in: app, text: "[Enter]")
          && self.agentTuiViewportContainsText(in: app, text: "[Arrow Down]")
      },
      "After the idle window expires the queued keys should replay in order into the viewport"
    )
  }

  func testSelectionChangeFlushesPendingKeySequenceImmediately() throws {
    let app = launchInCockpitPreview()
    openWorkspaceWindow(in: app)
    startAgentTui(in: app, runtimeTitle: "Codex", prompt: "flush pending keys on selection change")
    tapButton(in: app, identifier: Accessibility.agentTuiKeyButton("enter"))
    let pendingHint = element(in: app, identifier: Accessibility.agentTuiKeyQueueHint)
    XCTAssertTrue(waitForElement(pendingHint, timeout: Self.fastActionTimeout))
    tapButton(in: app, identifier: Accessibility.agentTuiCreateTab)
    let sessionRow = element(in: app, identifier: Accessibility.agentTuiTab("preview-agent-tui-1"))
    XCTAssertTrue(waitForElement(sessionRow, timeout: Self.actionTimeout))
    tapViaCoordinate(in: app, element: sessionRow)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        !pendingHint.exists && self.agentTuiViewportContainsText(in: app, text: "[Enter]")
      },
      """
      Switching away from the session should flush the buffered key sequence immediately instead of
      waiting for the idle timer.
      """
    )
  }

  func testDraggingViewportDividerResizesLiveTerminal() throws {
    let app = launchInCockpitPreview()
    openWorkspaceWindow(in: app)
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
    openWorkspaceWindow(in: app)
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
}
