import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension WorkspaceWindowUITests {
  func testAcpStartUsesSelectedSessionFallbackWhenCreatePaneHasNoCachedSession() throws {
    throw XCTSkip(
      """
      Multi-window create-pane scrolling is still flaky in XCUITest and blocks local iterations. \
      Deterministic fallback coverage lives in \
      HarnessMonitorKitTests/WorkspaceAcpSessionContextTests.
      """
    )
  }

  func testAcpCapabilityPicker() throws {
    let app = launchInCockpitPreview()
    openWorkspaceWindow(in: app)

    let copilotRow = element(in: app, identifier: Accessibility.agentCapabilityRow("copilot"))
    XCTAssertTrue(
      waitForElement(copilotRow, timeout: Self.actionTimeout),
      "GitHub Copilot capability row should be visible in the create pane"
    )
    XCTAssertTrue(copilotRow.label.localizedCaseInsensitiveContains("copilot"))
    XCTAssertFalse(
      copilotRow.label.localizedCaseInsensitiveContains("ACP"),
      "Capability picker should not expose transport jargon to users"
    )
    XCTAssertTrue(
      copilotRow.label.localizedCaseInsensitiveContains("filesystem read"),
      "Capability picker accessibility label should map capability ids to human text"
    )

    let geminiRow = element(in: app, identifier: Accessibility.agentCapabilityRow("gemini"))
    XCTAssertTrue(
      waitForElement(geminiRow, timeout: Self.actionTimeout),
      "Gemini capability row should be visible in the create pane"
    )
    XCTAssertTrue(geminiRow.label.localizedCaseInsensitiveContains("gemini"))
    XCTAssertFalse(
      geminiRow.label.localizedCaseInsensitiveContains("ACP"),
      "Second ACP descriptor row should not expose transport jargon to users"
    )

    let probe = element(in: app, identifier: Accessibility.agentCapabilityProbe("copilot"))
    XCTAssertFalse(
      probe.exists,
      "Doctor probe should stay hidden until diagnostics disclosure is expanded"
    )
    selectWorkspaceCapability(in: app, identifier: "copilot", title: "Copilot")
    tapElement(
      in: app,
      identifier: Accessibility.newSessionDiagnosticsToggle("copilot")
    )
    XCTAssertTrue(
      waitForElement(probe, timeout: Self.actionTimeout),
      "Doctor probe should become visible after opening diagnostics disclosure"
    )
  }

  func testAcpCapabilityPickerShowsInstallHintWhenBinaryMissing() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_ACP_MISSING_BINARIES": "copilot"]
    )
    openWorkspaceWindow(in: app)

    let copilotRow = element(in: app, identifier: Accessibility.agentCapabilityRow("copilot"))
    XCTAssertTrue(waitForElement(copilotRow, timeout: Self.actionTimeout))
    XCTAssertTrue(copilotRow.label.localizedCaseInsensitiveContains("install required"))

    let modelPicker = element(in: app, identifier: Accessibility.workspaceModelPicker)
    XCTAssertTrue(
      waitForElement(modelPicker, timeout: Self.actionTimeout),
      "Missing ACP binary should fall back to the TUI-backed form state"
    )

    selectWorkspaceCapability(in: app, identifier: "copilot", title: "Copilot")

    let installButton = button(
      in: app,
      identifier: Accessibility.agentCapabilityInstallButton("copilot")
    )
    XCTAssertTrue(
      waitForElement(installButton, timeout: Self.actionTimeout),
      "Install CTA should remain visible before the user interacts with the row"
    )

    let acpChoice = element(
      in: app,
      identifier: Accessibility.agentCapabilityTransportButton(
        "copilot",
        transportID: "managed:copilot"
      )
    )
    XCTAssertTrue(
      waitForElement(acpChoice, timeout: Self.actionTimeout),
      "Missing ACP binary should keep ACP mode discoverable while install CTA is shown"
    )
    XCTAssertFalse(acpChoice.isEnabled, "Missing ACP binary should disable the ACP transport")
    XCTAssertTrue(
      acpChoice.label.localizedCaseInsensitiveContains("copilot"),
      "Disabled ACP transport should keep the provider name in its accessible label"
    )
    XCTAssertTrue(
      acpChoice.label.localizedCaseInsensitiveContains("filesystem + terminal tools"),
      "Disabled ACP transport should describe the capability in user-facing language"
    )
    XCTAssertFalse(
      acpChoice.label.localizedCaseInsensitiveContains("ACP"),
      "Disabled ACP transport should not expose transport jargon through accessibility"
    )

    let tuiChoice = element(
      in: app,
      identifier: Accessibility.agentCapabilityTransportButton(
        "copilot",
        transportID: "tui:copilot"
      )
    )
    XCTAssertTrue(
      waitForElement(tuiChoice, timeout: Self.actionTimeout),
      "TUI fallback should remain discoverable when ACP transport is disabled"
    )
    XCTAssertTrue(tuiChoice.isEnabled, "TUI fallback should remain enabled")
  }

  func testPermissionPromptRoutesDirectlyToDecisions() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START": "1"]
    )
    let workspaceWindow = element(in: app, identifier: Accessibility.workspaceWindow)

    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        workspaceWindow.exists
          && self.descendantElement(
            in: workspaceWindow,
            identifier: Accessibility.decisionRow("acp-permission:preview-acp-permission-1")
          ).exists
      },
      "ACP permission prompts should route directly into the Workspace window"
    )

    XCTAssertFalse(
      element(in: app, identifier: Accessibility.acpPermissionModal).exists,
      "ACP permission flow should not present a separate sheet before routing"
    )
  }

  func testDecisionPanelSelectionStatePersistsWithoutSeparateModal() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1",
        "HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START": "1",
        "AppleKeyboardUIMode": "2",
      ]
    )
    let workspaceWindow = element(in: app, identifier: Accessibility.workspaceWindow)

    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        workspaceWindow.exists
      },
      "Permission prompt on start should immediately open the Workspace window"
    )

    let acpDecisionID = "acp-permission:preview-acp-permission-1"
    let decisionRow = descendantButton(
      in: workspaceWindow,
      identifier: Accessibility.decisionRow(acpDecisionID)
    )
    assertDecisionRouteSelection(
      in: app,
      workspaceWindow: workspaceWindow,
      decisionID: acpDecisionID,
      decisionRow: decisionRow
    )

    let terminalToggleIdentifier = Accessibility.decisionAcpRequest("preview-request-terminal")
    let terminalToggleFrame = descendantFrameElement(
      in: workspaceWindow,
      identifier: "\(terminalToggleIdentifier).frame"
    )
    XCTAssertTrue(
      waitForElement(terminalToggleFrame, timeout: Self.actionTimeout),
      "ACP decision panel should expose the terminal request frame marker"
    )
    let decisionDetailScrollView = descendantElement(
      in: workspaceWindow,
      identifier: Accessibility.decisionDetailScrollView
    )
    let terminalVisible = scrollDecisionPanelUntilRequestVisible(
      in: app,
      scrollTarget: decisionDetailScrollView.exists ? decisionDetailScrollView : workspaceWindow,
      terminalToggleFrame: terminalToggleFrame,
      terminalToggleIdentifier: terminalToggleIdentifier
    )
    XCTAssertTrue(
      terminalVisible,
      """
      The decision detail should scroll until the ACP request checkbox is visible.
      terminalFrame=\(terminalToggleFrame.frame)
      """
    )

    let terminalToggles = workspaceWindow.descendants(matching: .checkBox)
    let terminalToggleQuery = terminalToggles.matching(identifier: terminalToggleIdentifier)
    let terminalToggle = terminalToggleQuery.firstMatch
    XCTAssertTrue(
      waitForElement(terminalToggle, timeout: Self.actionTimeout),
      "ACP decision panel should render the request toggle list"
    )
    XCTAssertTrue(
      tapElementReliably(in: app, element: terminalToggle),
      """
      ACP request checkbox should be tappable in the Decisions panel.
      exists=\(terminalToggle.exists)
      hittable=\(terminalToggle.isHittable)
      frame=\(terminalToggle.frame)
      label=\(terminalToggle.label)
      value=\(String(describing: terminalToggle.value))
      """
    )
    let decisionSelectionSummary = descendantElement(
      in: workspaceWindow,
      identifier: Accessibility.decisionAcpSelectionSummary
    )
    assertDecisionSelectionSummary(
      decisionSelectionSummary,
      terminalToggle: terminalToggle
    )

    XCTAssertFalse(
      element(in: app, identifier: Accessibility.acpPermissionModal).exists,
      "ACP decision state should live only in Decisions, without a duplicate modal surface"
    )
  }

  func testPermissionPromptCommandReturnApprovesSelectedRequests() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1",
        "HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START": "1",
      ]
    )
    let workspaceWindow = element(in: app, identifier: Accessibility.workspaceWindow)

    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        workspaceWindow.exists
      },
      "Permission prompt on start should immediately open the Workspace window"
    )

    let acpDecisionID = "acp-permission:preview-acp-permission-1"
    let decisionRow = descendantButton(
      in: workspaceWindow,
      identifier: Accessibility.decisionRow(acpDecisionID)
    )
    XCTAssertTrue(
      waitForElement(decisionRow, timeout: Self.uiTimeout),
      "ACP permission route should preselect the decision row in Workspace"
    )
    XCTAssertTrue(
      tapElementReliably(in: app, element: decisionRow),
      "ACP decision row should be tappable inside the Workspace window"
    )

    let approveButton = descendantButton(
      in: workspaceWindow,
      identifier: Accessibility.decisionAction("approve-selected")
    )
    XCTAssertTrue(
      waitForElement(approveButton, timeout: Self.actionTimeout),
      "ACP permission decision should expose the approve-selected action"
    )

    app.activate()
    app.typeKey(.return, modifierFlags: .command)
    let decisionRowExists = self.descendantElement(
      in: workspaceWindow,
      identifier: Accessibility.decisionRow(acpDecisionID)
    ).exists
    let acpPanelExists = self.descendantElement(
      in: workspaceWindow,
      identifier: Accessibility.decisionAcpPanel
    ).exists

    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        !self.descendantElement(
          in: workspaceWindow,
          identifier: Accessibility.decisionRow(acpDecisionID)
        ).exists
          && !self.descendantElement(
            in: workspaceWindow,
            identifier: Accessibility.decisionAcpPanel
          ).exists
      },
      """
      Command-Return should approve the selected ACP requests from the Workspace decisions desk.
      rowExists=\(decisionRowExists)
      panelExists=\(acpPanelExists)
      """
    )
  }

  private func assertDecisionRouteSelection(
    in app: XCUIApplication,
    workspaceWindow: XCUIElement,
    decisionID: String,
    decisionRow: XCUIElement
  ) {
    XCTAssertTrue(
      waitForElement(decisionRow, timeout: Self.uiTimeout),
      "ACP permission route should preselect the decision row in Workspace"
    )

    let acpPanel = descendantElement(
      in: workspaceWindow,
      identifier: Accessibility.decisionAcpPanel
    )
    XCTAssertTrue(
      waitForElement(acpPanel, timeout: Self.actionTimeout),
      "ACP permission route should open the ACP decision panel without another row click"
    )

    XCTAssertTrue(
      decisionRow.exists,
      "ACP permission route should keep the decision selected in Workspace"
    )
  }

  private func scrollDecisionPanelUntilRequestVisible(
    in app: XCUIApplication,
    scrollTarget: XCUIElement,
    terminalToggleFrame: XCUIElement,
    terminalToggleIdentifier: String
  ) -> Bool {
    var previousTerminalY = terminalToggleFrame.frame.minY
    var terminalVisible = hasVisibleFrameMarker(in: app, identifier: terminalToggleIdentifier)

    for _ in 0..<5 where !terminalVisible {
      scrollDecisionPanelDown(scrollTarget)
      let scrolled = waitUntil(timeout: Self.actionTimeout) {
        terminalToggleFrame.frame.minY < previousTerminalY - 12
      }
      previousTerminalY = terminalToggleFrame.frame.minY
      terminalVisible = hasVisibleFrameMarker(in: app, identifier: terminalToggleIdentifier)
      if !scrolled && !terminalVisible {
        break
      }
    }

    return terminalVisible
  }

  private func scrollDecisionPanelDown(_ scrollTarget: XCUIElement) {
    let scrollDistance = max(160, scrollTarget.frame.height * 0.32)
    scrollTarget.scroll(byDeltaX: 0, deltaY: -scrollDistance)
  }

  private func assertDecisionSelectionSummary(
    _ decisionSelectionSummary: XCUIElement,
    terminalToggle: XCUIElement
  ) {
    let toggleValue = String(describing: terminalToggle.value)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        decisionSelectionSummary.exists
          && decisionSelectionSummary.label.contains("1 of 2 selected")
      },
      """
      The Decisions panel should reflect the updated ACP selection \
      (summaryLabel=\(decisionSelectionSummary.label), \
      toggleLabel=\(terminalToggle.label), \
      toggleValue=\(toggleValue), \
      toggleHittable=\(terminalToggle.isHittable))
      """
    )
  }
}
