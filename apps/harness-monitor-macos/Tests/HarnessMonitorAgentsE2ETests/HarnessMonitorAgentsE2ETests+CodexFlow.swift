import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

extension HarnessMonitorAgentsE2ETests {
  func launchSteeredCodexRun(in app: XCUIApplication) {
    selectSegment(
      in: app,
      controlIdentifier: Accessibility.agentTuiCreateModePicker,
      title: "Codex"
    )
    selectFastModelForCodex(in: app)
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
  }

  func assertCodexRunBecomesActive(
    state: XCUIElement,
    harness: HarnessMonitorAgentsE2ELiveHarness
  ) {
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
  }

  func steerCodexRun(in app: XCUIApplication) {
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
  }

  func assertSteeredCodexRunCompletes(
    in app: XCUIApplication,
    state: XCUIElement,
    harness: HarnessMonitorAgentsE2ELiveHarness
  ) {
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
  }

  func launchApprovalCodexRun(in app: XCUIApplication) {
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
        """
        Create a file named approved.txt in the current workspace containing exactly UI_APPROVAL_OK.
        After the write completes, reply with exactly UI_APPROVAL_OK and stop.
        """
    )
    revealAction(
      in: app,
      containerIdentifier: Accessibility.agentTuiLaunchPane,
      identifier: Accessibility.agentsCodexSubmitButton,
      title: "Start Codex"
    )
    tapButton(in: app, identifier: Accessibility.agentsCodexSubmitButton)
  }

  func assertApprovalCodexRunCompletes(
    in app: XCUIApplication,
    state: XCUIElement,
    harness: HarnessMonitorAgentsE2ELiveHarness
  ) {
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
