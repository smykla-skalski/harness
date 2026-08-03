import XCTest

@MainActor
final class HarnessMonitorAgentsE2ETests: HarnessMonitorUITestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    guard ProcessInfo.processInfo.environment["HARNESS_MONITOR_ENABLE_AGENTS_E2E"] == "1"
    else {
      throw XCTSkip("Agents e2e requires the isolated live harness")
    }
  }

  func testTerminalAgentStartsAndStopsThroughSandboxedBridge() throws {
    let harness = try HarnessMonitorAgentsE2ELiveHarness.setUp(for: self, purpose: "terminal")
    let app = launch(mode: "live", additionalEnvironment: harness.appLaunchEnvironment)

    tapButton(in: app, title: "Agents")
    XCTAssertTrue(
      waitForElement(
        in: app,
        element(in: app, identifier: HarnessMonitorUITestAccessibility.dashboardAgentsRoot),
        timeout: Self.uiTimeout
      ),
      harness.diagnosticsSummary()
    )
    tapElement(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.dashboardTerminalCreateButton
    )

    let prompt = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.dashboardTerminalPromptField
    )
    XCTAssertTrue(waitForElement(in: app, prompt, timeout: Self.uiTimeout))
    prompt.click()
    prompt.typeText("Wait for terminal input before responding")
    tapElement(in: app, identifier: HarnessMonitorUITestAccessibility.dashboardTerminalStartButton)

    let input = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.dashboardTerminalInputField
    )
    XCTAssertTrue(waitForElement(in: app, input, timeout: 60), harness.diagnosticsSummary())
    input.click()
    input.typeText("Reply with the uppercase form of terminal_ui_ok")
    tapElement(in: app, identifier: HarnessMonitorUITestAccessibility.dashboardTerminalSendButton)

    let output = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.dashboardTerminalOutput
    )
    XCTAssertTrue(
      waitUntil(in: app, timeout: 60) {
        output.exists && output.label.contains("TERMINAL_UI_OK")
      },
      harness.diagnosticsSummary()
    )

    let stop = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.dashboardTerminalStopButton
    )
    XCTAssertTrue(waitForElement(in: app, stop, timeout: Self.uiTimeout))
    stop.click()
    XCTAssertTrue(
      waitUntil(in: app, timeout: Self.uiTimeout) { !stop.exists },
      harness.diagnosticsSummary()
    )
  }

  func testCodexThreadSteersAndApprovesThroughSandboxedBridge() throws {
    let harness = try HarnessMonitorAgentsE2ELiveHarness.setUp(for: self, purpose: "codex")
    let app = launch(mode: "live", additionalEnvironment: harness.appLaunchEnvironment)

    tapButton(in: app, title: "Agents")
    XCTAssertTrue(
      waitForElement(
        in: app,
        element(in: app, identifier: HarnessMonitorUITestAccessibility.dashboardAgentsRoot),
        timeout: Self.uiTimeout
      ),
      harness.diagnosticsSummary()
    )
    tapElement(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.dashboardCodexCreateButton
    )

    let prompt = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.dashboardCodexPromptField
    )
    XCTAssertTrue(waitForElement(in: app, prompt, timeout: Self.uiTimeout))
    prompt.click()
    prompt.typeText("Wait for follow-up context before changing the workspace")
    tapElement(in: app, identifier: HarnessMonitorUITestAccessibility.dashboardCodexStartButton)

    let steer = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.dashboardCodexSteerField
    )
    XCTAssertTrue(waitForElement(in: app, steer, timeout: 60), harness.diagnosticsSummary())
    revealElementInContainer(
      in: app,
      containerIdentifier: HarnessMonitorUITestAccessibility.dashboardAgentDetail,
      identifier: HarnessMonitorUITestAccessibility.dashboardCodexSteerField,
      scrollTargetIdentifier: HarnessMonitorUITestAccessibility.dashboardAgentDetail
    )
    steer.click()
    steer.typeText(
      "Run a shell command that writes exactly UI_APPROVAL_OK to approved.txt, then wait"
    )
    tapElement(in: app, identifier: HarnessMonitorUITestAccessibility.dashboardCodexSteerButton)

    let accept = app.buttons["Accept"].firstMatch
    XCTAssertTrue(waitForElement(in: app, accept, timeout: 60), harness.diagnosticsSummary())
    accept.click()

    let approvalFile = try harness.approvalFileURL()
    XCTAssertTrue(
      waitUntil(timeout: 60) {
        (try? String(contentsOf: approvalFile, encoding: .utf8))?
          .trimmingCharacters(in: .whitespacesAndNewlines) == "UI_APPROVAL_OK"
      },
      harness.diagnosticsSummary()
    )

    let stop = element(
      in: app,
      identifier: HarnessMonitorUITestAccessibility.dashboardCodexStopButton
    )
    XCTAssertTrue(waitForElement(in: app, stop, timeout: Self.uiTimeout))
    stop.click()
    XCTAssertTrue(
      waitUntil(in: app, timeout: Self.uiTimeout) { !stop.exists || !stop.isEnabled },
      harness.diagnosticsSummary()
    )
  }
}
