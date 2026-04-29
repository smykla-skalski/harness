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
    XCTAssertTrue(
      waitForElement(probe, timeout: Self.actionTimeout),
      "Doctor probe should be visible in the capability row at rest"
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

    let acpButton = button(
      in: app,
      identifier: Accessibility.agentCapabilityTransportButton(
        "copilot",
        transportID: "managed:copilot"
      )
    )
    XCTAssertTrue(waitForElement(acpButton, timeout: Self.actionTimeout))
    XCTAssertFalse(
      acpButton.isEnabled,
      "Missing ACP binary should disable the ACP transport choice"
    )
  }

  func testPermissionModalCoalesce() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START": "1"]
    )
    openAgentsWindow(in: app)

    let modal = element(in: app, identifier: "harness.acp-permission.modal")
    XCTAssertTrue(waitForElement(modal, timeout: Self.actionTimeout))
    XCTAssertTrue(app.staticTexts["2 of 2 selected"].exists)
    XCTAssertTrue(
      element(in: app, identifier: "harness.acp-permission.item.preview-request-write").exists
    )
    XCTAssertTrue(
      element(in: app, identifier: "harness.acp-permission.item.preview-request-terminal").exists
    )

    tapButton(in: app, title: "Approve Selected")
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        !modal.exists
      },
      "Approving the coalesced batch should resolve and dismiss the modal"
    )
  }
}
