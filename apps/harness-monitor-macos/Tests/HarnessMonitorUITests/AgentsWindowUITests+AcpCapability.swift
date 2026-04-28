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
  }
}
