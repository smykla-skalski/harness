import XCTest

extension AgentsWindowUITests {
  func testCreatePaneSidebarChromeMatchesNativeInsetLayout() throws {
    let app = launchInCockpitPreview()
    openAgentsWindow(in: app)
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
    let buttonLeadingInset =
      toolbar.buttons.allElementsBoundByIndex
      .filter { $0.exists && !$0.frame.isEmpty }
      .map { $0.frame.minX - agentWindow.frame.minX }
      .min()
      ?? .greatestFiniteMagnitude
    let searchLeadingInset =
      agentWindow.searchFields.allElementsBoundByIndex
      .filter { $0.exists && !$0.frame.isEmpty }
      .map { $0.frame.minX - agentWindow.frame.minX }
      .min()
      ?? .greatestFiniteMagnitude
    let leadingChromeInset = min(buttonLeadingInset, searchLeadingInset)
    let rowTopInset = createRow.frame.minY - agentWindow.frame.minY
    XCTAssertLessThan(
      leadingChromeInset,
      .greatestFiniteMagnitude,
      "Agents window should expose a visible leading toolbar control"
    )
    XCTAssertLessThan(
      leadingChromeInset,
      176,
      "Agents window chrome should stay near the leading window edge"
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

  func testDecisionDeskUsesNativeSearchFieldAndToolbarFilterMenu() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1"]
    )
    openAgentsWindow(in: app)

    let createRow = element(in: app, identifier: Accessibility.agentTuiCreateTab)
    XCTAssertTrue(waitForElement(createRow, timeout: Self.actionTimeout))

    let agentWindow = window(in: app, containing: createRow)
    let toolbar = agentWindow.toolbars.firstMatch
    let nativeSearchField = agentWindow.searchFields.firstMatch
    let filterButton = button(in: app, identifier: Accessibility.agentsDecisionFiltersMenu)
    let decisionDesk = element(in: app, identifier: Accessibility.agentsDecisionDesk)
    let legacyScopeMenu = element(
      in: app,
      identifier: Accessibility.decisionsSidebarSearchScopeMenu
    )
    let legacyFilterToggle = element(
      in: app,
      identifier: Accessibility.decisionsSidebarFilterToggle
    )

    XCTAssertTrue(waitForElement(toolbar, timeout: Self.fastActionTimeout))
    XCTAssertTrue(
      waitForElement(nativeSearchField, timeout: Self.fastActionTimeout),
      "Agents decision search should use SwiftUI searchable instead of a custom in-list text field"
    )
    XCTAssertTrue(waitForElement(filterButton, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(decisionDesk, timeout: Self.fastActionTimeout))
    XCTAssertTrue(
      filterButton.isEnabled,
      "Agents decision filter menu should stay enabled when the preview seeds decisions"
    )
    XCTAssertTrue(
      filterButton.label.contains("Severity"),
      "Agents decision toolbar control should expose the severity dimension, not a generic filter label"
    )
    XCTAssertFalse(
      legacyScopeMenu.exists,
      "Agents decision scope menu should come from native search scopes, not a custom sidebar row"
    )
    XCTAssertFalse(
      legacyFilterToggle.exists,
      "Agents decision severity filters should no longer use the old custom sidebar toggle row"
    )

    XCTAssertGreaterThanOrEqual(filterButton.frame.minY, toolbar.frame.minY - 4)
    XCTAssertLessThanOrEqual(filterButton.frame.maxY, toolbar.frame.maxY + 4)
    XCTAssertLessThanOrEqual(
      nativeSearchField.frame.maxY,
      createRow.frame.minY + 2,
      "Agents decision search should render in native sidebar chrome above the list content"
    )
  }

  func testDecisionFilterMenuUpdatesSidebarFilterState() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1"]
    )
    openAgentsWindow(in: app)

    let filterState = element(in: app, identifier: Accessibility.agentsDecisionFilterState)
    let decisionDesk = element(in: app, identifier: Accessibility.agentsDecisionDesk)
    XCTAssertTrue(waitForElement(filterState, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(decisionDesk, timeout: Self.fastActionTimeout))
    resetAgentsDecisionSeveritiesIfNeeded(in: app)
    XCTAssertTrue(
      filterState.label.contains("severities=all"),
      "Agents decision filters should start with the full severity set visible"
    )

    openAgentsDecisionFilters(in: app)
    tapButton(in: app, title: "Critical")

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        filterState.label.contains("severities=critical")
      },
      """
      Selecting Critical from the toolbar menu should update the agents decision filter state.
      state=\(filterState.label)
      """
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        decisionDesk.label.contains("Severity: Critical")
      },
      """
      Selecting Critical should update the visible Decision Desk summary with the active severity filter.
      label=\(decisionDesk.label)
      """
    )

    openAgentsDecisionFilters(in: app)
    tapButton(in: app, title: "All severities")

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        filterState.label.contains("severities=all")
      },
      """
      Resetting the toolbar menu should restore the unfiltered agents decision state.
      state=\(filterState.label)
      """
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        decisionDesk.label.contains("Severity:") == false
      },
      """
      Clearing severity filters should remove the explicit severity summary from the Decision Desk row.
      label=\(decisionDesk.label)
      """
    )
  }

  func testWrapToggleSwitchesViewportMode() throws {
    let app = launchInCockpitPreview()
    openAgentsWindow(in: app)
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
    openAgentsWindow(in: app)
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
    openAgentsWindow(in: app)
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
    openAgentsWindow(in: app)
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
    openAgentsWindow(in: app)
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
    openAgentsWindow(in: app)
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
