import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorAgentsE2ETests: HarnessMonitorUITestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    guard ProcessInfo.processInfo.environment["HARNESS_MONITOR_ENABLE_AGENTS_E2E"] == "1" else {
      throw XCTSkip(
        "Agents e2e is explicit-only. Run apps/harness-monitor-macos/Scripts/test-agents-e2e.sh."
      )
    }
  }

  func testTerminalAgentStartsAndStopsThroughSandboxedBridge() throws {
    let harness = try setUpLiveHarness(purpose: "terminal")
    let app = launchLiveAgentsApp(using: harness)

    openLiveSessionCockpit(in: app, sessionID: harness.sessionID, harness: harness)
    openAgentsWindow(in: app, harness: harness)

    selectSegment(
      in: app,
      controlIdentifier: Accessibility.agentTuiCreateModePicker,
      title: "Terminal"
    )
    selectSegment(
      in: app,
      controlIdentifier: Accessibility.agentTuiRuntimePicker,
      title: "Codex"
    )
    selectFastModelForTerminal(in: app, runtime: "codex")
    replaceText(
      in: app,
      identifier: Accessibility.agentTuiPromptField,
      text: "Reply with exactly UI_TERMINAL_E2E_OK and stop."
    )
    revealAction(
      in: app,
      containerIdentifier: Accessibility.agentTuiLaunchPane,
      identifier: Accessibility.agentTuiStartButton,
      title: "Start Codex"
    )
    tapButton(in: app, identifier: Accessibility.agentTuiStartButton)

    let state = element(in: app, identifier: Accessibility.agentTuiState)
    let viewport = element(in: app, identifier: Accessibility.agentTuiViewport)
    XCTAssertTrue(
      waitUntil(timeout: Self.codexCompletionTimeout) {
        state.label.contains("selection=terminal:")
          && state.label.contains("status=running")
          && viewport.exists
      },
      """
      Terminal agent never reached a running viewport.
      state=\(state.label)
      \(harness.diagnosticsSummary())
      """
    )

    tapButton(in: app, identifier: Accessibility.agentTuiStopButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.liveActionTimeout) {
        state.label.contains("status=stopped") || state.label.contains("status=exited")
      },
      """
      Terminal agent did not stop cleanly.
      state=\(state.label)
      \(harness.diagnosticsSummary())
      """
    )
  }

  func testCodexThreadSteersAndApprovesThroughSandboxedBridge() throws {
    let harness = try setUpLiveHarness(purpose: "codex")
    let app = launchLiveAgentsApp(using: harness)

    openLiveSessionCockpit(in: app, sessionID: harness.sessionID, harness: harness)
    openAgentsWindow(in: app, harness: harness)

    let state = element(in: app, identifier: Accessibility.agentTuiState)
    launchSteeredCodexRun(in: app)
    assertCodexRunBecomesActive(state: state, harness: harness)
    steerCodexRun(in: app)
    assertSteeredCodexRunCompletes(in: app, state: state, harness: harness)
    launchApprovalCodexRun(in: app)
    assertApprovalCodexRunCompletes(in: app, state: state, harness: harness)
  }
}
