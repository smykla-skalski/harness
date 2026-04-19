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

    selectSegment(
      in: app,
      controlIdentifier: Accessibility.agentTuiCreateModePicker,
      title: "Codex"
    )
    replaceText(
      in: app,
      identifier: Accessibility.agentsCodexPromptField,
      text: "Execute the shell command `sleep 5`, then reply with exactly SHOULD_NOT_APPEAR."
    )
    revealAction(
      in: app,
      containerIdentifier: Accessibility.agentTuiLaunchPane,
      identifier: Accessibility.agentsCodexSubmitButton,
      title: "Start Codex"
    )
    tapButton(in: app, identifier: Accessibility.agentsCodexSubmitButton)

    let state = element(in: app, identifier: Accessibility.agentTuiState)
    XCTAssertTrue(
      waitUntil(timeout: Self.liveActionTimeout) {
        state.label.contains("selection=codex:") && state.label.contains("status=running")
      },
      """
      Codex run never became active.
      state=\(state.label)
      \(harness.diagnosticsSummary())
      """
    )

    replaceText(
      in: app,
      identifier: Accessibility.agentsCodexContextField,
      text: "Instead, when the command finishes, reply with exactly UI_CODEX_STEERED and stop."
    )
    revealAction(
      in: app,
      containerIdentifier: Accessibility.agentTuiSessionPane,
      identifier: Accessibility.agentsCodexSteerButton,
      title: "Send Context"
    )
    tapButton(in: app, identifier: Accessibility.agentsCodexSteerButton)

    let steeredFinalMessage = element(in: app, identifier: Accessibility.agentsCodexFinalMessage)
    XCTAssertTrue(
      waitUntil(timeout: Self.codexCompletionTimeout) {
        steeredFinalMessage.exists
          && steeredFinalMessage.label == "UI_CODEX_STEERED"
          && state.label.contains("status=completed")
      },
      """
      Codex steer result did not complete with the expected final message.
      state=\(state.label)
      \(harness.diagnosticsSummary())
      """
    )

    tapButton(in: app, identifier: Accessibility.agentTuiCreateTab)
    XCTAssertTrue(
      waitUntil(timeout: Self.liveActionTimeout) {
        self.element(in: app, identifier: Accessibility.agentTuiLaunchPane).exists
      }
    )

    selectSegment(
      in: app,
      controlIdentifier: Accessibility.agentTuiCreateModePicker,
      title: "Codex"
    )
    selectSegment(
      in: app,
      controlIdentifier: Accessibility.agentsCodexModePicker,
      title: "Approval"
    )
    replaceText(
      in: app,
      identifier: Accessibility.agentsCodexPromptField,
      text:
        "Create a file named approved.txt in the current workspace containing exactly UI_APPROVAL_OK. After the write completes, reply with exactly UI_APPROVAL_OK and stop."
    )
    revealAction(
      in: app,
      containerIdentifier: Accessibility.agentTuiLaunchPane,
      identifier: Accessibility.agentsCodexSubmitButton,
      title: "Start Codex"
    )
    tapButton(in: app, identifier: Accessibility.agentsCodexSubmitButton)

    var sawApproval = false
    let approvalFinalMessage = element(in: app, identifier: Accessibility.agentsCodexFinalMessage)
    XCTAssertTrue(
      waitUntil(timeout: Self.codexCompletionTimeout, pollInterval: 0.25) {
        if approvalFinalMessage.exists
          && approvalFinalMessage.label == "UI_APPROVAL_OK"
          && state.label.contains("status=completed")
        {
          return true
        }

        let approveButton = self.button(in: app, title: "Approve")
        if approveButton.exists {
          sawApproval = true
          if approveButton.isHittable {
            approveButton.tap()
          } else if let coordinate = self.centerCoordinate(in: app, for: approveButton) {
            coordinate.tap()
          }
        }
        return false
      },
      """
      Approval-mode Codex run did not finish after surfacing approvals.
      sawApproval=\(sawApproval)
      state=\(state.label)
      \(harness.diagnosticsSummary())
      """
    )
    XCTAssertTrue(
      sawApproval,
      """
      Approval-mode Codex run completed without showing any approval request.
      state=\(state.label)
      \(harness.diagnosticsSummary())
      """
    )
  }
}
