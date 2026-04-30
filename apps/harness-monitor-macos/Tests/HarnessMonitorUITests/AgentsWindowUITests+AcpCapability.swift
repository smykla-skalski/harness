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
  }

  func testPermissionModalIsReaderOnlyAndRoutesToDecisions() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START": "1"]
    )
    openAgentsWindow(in: app)

    let modal = element(in: app, identifier: Accessibility.acpPermissionModal)
    XCTAssertTrue(waitForElement(modal, timeout: Self.actionTimeout))
    XCTAssertTrue(
      waitForElement(
        element(in: app, identifier: Accessibility.acpPermissionModalItem("preview-request-write")),
        timeout: Self.actionTimeout
      )
    )
    XCTAssertTrue(
      waitForElement(
        element(
          in: app,
          identifier: Accessibility.acpPermissionModalItem("preview-request-terminal")
        ),
        timeout: Self.actionTimeout
      )
    )

    XCTAssertFalse(
      button(in: app, title: "Approve Selected").exists,
      "Reader-only modal must not expose independent resolve actions"
    )
    XCTAssertFalse(
      button(in: app, title: "Approve All").exists,
      "Reader-only modal must not expose independent resolve actions"
    )
    XCTAssertFalse(
      button(in: app, title: "Deny All").exists,
      "Reader-only modal must not expose independent resolve actions"
    )

    tapButton(in: app, identifier: Accessibility.acpPermissionModalOpenDecisions)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.element(in: app, identifier: Accessibility.decisionsWindow).exists
          && self.element(
            in: app,
            identifier: Accessibility.decisionRow("acp-permission:preview-acp-permission-1")
          ).exists
      },
      "Reader-only modal should route to Decisions instead of resolving directly"
    )
  }

  func testDecisionPanelAndModalShareSelectionState() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1",
        "HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START": "1",
      ]
    )

    tapButton(in: app, identifier: Accessibility.supervisorBadge)

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

    openAgentsWindow(in: app)

    let modal = element(in: app, identifier: Accessibility.acpPermissionModal)
    XCTAssertTrue(waitForElement(modal, timeout: Self.actionTimeout))
    let modalSelectionSummary = element(
      in: app,
      identifier: Accessibility.acpPermissionModalSelectionSummary
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        modalSelectionSummary.exists && modalSelectionSummary.label.contains("1 of 2 selected")
      },
      """
      The legacy ACP modal should mirror the shared selection state from the Decisions window \
      (summaryLabel=\(modalSelectionSummary.label))
      """
    )
  }
}
