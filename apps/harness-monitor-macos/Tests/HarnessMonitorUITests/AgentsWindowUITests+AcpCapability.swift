import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension AgentsWindowUITests {
  func testAcpCapabilityPicker() throws {
    let app = launchInCockpitPreview()
    openAgentsWindow(in: app)

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
    tapButton(in: app, title: "Copilot")
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
    openAgentsWindow(in: app)

    let copilotRow = element(in: app, identifier: Accessibility.agentCapabilityRow("copilot"))
    XCTAssertTrue(waitForElement(copilotRow, timeout: Self.actionTimeout))
    XCTAssertTrue(copilotRow.label.localizedCaseInsensitiveContains("install required"))

    let modelPicker = element(in: app, identifier: Accessibility.agentsModelPicker)
    XCTAssertTrue(
      waitForElement(modelPicker, timeout: Self.actionTimeout),
      "Missing ACP binary should fall back to the TUI-backed form state"
    )

    tapButton(in: app, title: "Copilot")

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
    openAgentsWindow(in: app)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.element(in: app, identifier: Accessibility.decisionsWindow).exists
          && self.element(
            in: app,
            identifier: Accessibility.decisionRow("acp-permission:preview-acp-permission-1")
          ).exists
      },
      "ACP permission prompts should route directly into the Decisions window"
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
      ]
    )
    openAgentsWindow(in: app)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.element(in: app, identifier: Accessibility.decisionsWindow).exists
      },
      "Permission prompt on start should immediately open the Decisions window"
    )

    let acpDecisionID = "acp-permission:preview-acp-permission-1"
    let decisionRow = button(in: app, identifier: Accessibility.decisionRow(acpDecisionID))
    XCTAssertTrue(waitForElement(decisionRow, timeout: Self.uiTimeout))
    tapButton(in: app, identifier: Accessibility.decisionRow(acpDecisionID))

    let acpPanel = element(in: app, identifier: Accessibility.decisionAcpPanel)
    XCTAssertTrue(waitForElement(acpPanel, timeout: Self.actionTimeout))

    let terminalToggle = element(
      in: app,
      identifier: Accessibility.decisionAcpRequest("preview-request-terminal")
    )
    XCTAssertTrue(waitForElement(terminalToggle, timeout: Self.actionTimeout))
    tapElement(
      in: app,
      identifier: Accessibility.decisionAcpRequest("preview-request-terminal")
    )
    let decisionSelectionSummary = element(
      in: app,
      identifier: Accessibility.decisionAcpSelectionSummary
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        decisionSelectionSummary.exists
          && decisionSelectionSummary.label.contains("1 of 2 selected")
      },
      """
      The Decisions panel should reflect the updated ACP selection \
      (summaryLabel=\(decisionSelectionSummary.label), \
      toggleValue=\(String(describing: terminalToggle.value)))
      """
    )

    XCTAssertFalse(
      element(in: app, identifier: Accessibility.acpPermissionModal).exists,
      "ACP decision state should live only in Decisions, without a duplicate modal surface"
    )
  }
}
