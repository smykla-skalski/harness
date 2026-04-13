import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class AgentTuiWindowUITests: HarnessMonitorUITestCase {
  func testAgentTuiWindowDefaultsToCreatePaneWhenNoSessionsExist() throws {
    let app = launchInCockpitPreview()

    openAgentTuiWindow(in: app)

    let createRow = element(in: app, identifier: Accessibility.agentTuiCreateTab)
    let launchPane = element(in: app, identifier: Accessibility.agentTuiLaunchPane)
    let state = element(in: app, identifier: Accessibility.agentTuiState)

    XCTAssertTrue(waitForElement(createRow, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(launchPane, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(state, timeout: Self.fastActionTimeout))
    XCTAssertTrue(state.label.contains("selection=create"))
  }

  func testStartingAgentTuiCreatesAndSelectsSessionRow() throws {
    let app = launchInCockpitPreview()

    openAgentTuiWindow(in: app)
    startAgentTui(in: app, runtimeTitle: "Codex", prompt: "Inspect the cockpit session")

    let sessionRow = element(
      in: app,
      identifier: Accessibility.agentTuiTab("preview-agent-tui-1")
    )
    let sessionPane = element(in: app, identifier: Accessibility.agentTuiSessionPane)
    let state = element(in: app, identifier: Accessibility.agentTuiState)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        sessionRow.exists
          && sessionPane.exists
          && state.label.contains("selection=session:preview-agent-tui-1")
          && state.label.contains("status=running")
          && self.agentTuiActionExists(
            in: app,
            title: "Stop",
            identifier: Accessibility.agentTuiStopButton
          )
      }
    )
  }

  func testSidebarShowsAllSessionsWithoutOverflow() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "agent-tui-overflow"]
    )

    reopenAgentTuiWindow(in: app)

    for index in 1 ... 6 {
      let sessionRow = element(
        in: app,
        identifier: Accessibility.agentTuiTab("preview-agent-tui-\(index)")
      )
      XCTAssertTrue(
        waitForElement(sessionRow, timeout: Self.actionTimeout),
        "Session row for preview-agent-tui-\(index) should be visible in sidebar"
      )
    }
  }

  func testWrapToggleSwitchesViewportMode() throws {
    let app = launchInCockpitPreview()

    openAgentTuiWindow(in: app)
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

  func testPersonaPickerAppearsBeforeTuiStart() throws {
    let app = launchInCockpitPreview()

    openAgentTuiWindow(in: app)

    // Select runtime and tap start without using the startAgentTui helper
    tapButton(in: app, title: "Codex")
    revealCreateAction(in: app, startTitle: "Start Codex")
    if button(in: app, title: "Start Codex").exists || element(in: app, title: "Start Codex").exists {
      tapButton(in: app, title: "Start Codex")
    } else {
      tapButton(in: app, identifier: Accessibility.agentTuiStartButton)
    }

    let picker = element(in: app, identifier: Accessibility.personaPicker)
    XCTAssertTrue(
      waitForElement(picker, timeout: Self.actionTimeout),
      "Persona picker should appear after tapping Start"
    )
  }

  func testSkippingPersonaStartsTuiWithoutPersona() throws {
    let app = launchInCockpitPreview()

    openAgentTuiWindow(in: app)

    tapButton(in: app, title: "Codex")
    revealCreateAction(in: app, startTitle: "Start Codex")
    if button(in: app, title: "Start Codex").exists || element(in: app, title: "Start Codex").exists {
      tapButton(in: app, title: "Start Codex")
    } else {
      tapButton(in: app, identifier: Accessibility.agentTuiStartButton)
    }

    let skipButton = element(in: app, identifier: Accessibility.personaSkipButton)
    XCTAssertTrue(
      waitForElement(skipButton, timeout: Self.actionTimeout),
      "Skip button should appear in persona picker"
    )
    skipButton.tap()

    let sessionPane = element(in: app, identifier: Accessibility.agentTuiSessionPane)
    XCTAssertTrue(
      waitForElement(sessionPane, timeout: Self.actionTimeout),
      "TUI should start after skipping persona"
    )
  }

  func testSelectingPersonaDismissesPickerAndStartsTui() throws {
    let app = launchInCockpitPreview()

    openAgentTuiWindow(in: app)

    tapButton(in: app, title: "Codex")
    revealCreateAction(in: app, startTitle: "Start Codex")
    if button(in: app, title: "Start Codex").exists || element(in: app, title: "Start Codex").exists {
      tapButton(in: app, title: "Start Codex")
    } else {
      tapButton(in: app, identifier: Accessibility.agentTuiStartButton)
    }

    let codeReviewerCard = element(
      in: app,
      identifier: Accessibility.personaCard("code-reviewer")
    )
    XCTAssertTrue(
      waitForElement(codeReviewerCard, timeout: Self.actionTimeout),
      "Code Reviewer persona card should appear"
    )
    codeReviewerCard.tap()

    let sessionPane = element(in: app, identifier: Accessibility.agentTuiSessionPane)
    XCTAssertTrue(
      waitForElement(sessionPane, timeout: Self.actionTimeout),
      "TUI should start after selecting persona"
    )
  }

  func testStoppedSessionHidesLiveControlsButKeepsTranscriptAction() throws {
    let app = launchInCockpitPreview()

    openAgentTuiWindow(in: app)
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

private extension AgentTuiWindowUITests {
  func launchInCockpitPreview(
    additionalEnvironment: [String: String] = [:]
  ) -> XCUIApplication {
    var environment = [
      "HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit",
      "HARNESS_MONITOR_PREVIEW_HOST_BRIDGE_CAPABILITIES": "agent-tui",
    ]
    environment.merge(additionalEnvironment) { _, new in new }
    return launch(
      mode: "preview",
      additionalEnvironment: environment
    )
  }

  func openAgentTuiWindow(in app: XCUIApplication) {
    tapDockButton(in: app, identifier: Accessibility.agentTuiButton, label: "agent-tui")
    XCTAssertTrue(
      waitForElement(
        element(in: app, identifier: Accessibility.agentTuiLaunchPane),
        timeout: Self.actionTimeout
      )
    )
  }

  func reopenAgentTuiWindow(in app: XCUIApplication) {
    tapDockButton(in: app, identifier: Accessibility.agentTuiButton, label: "agent-tui")
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.element(in: app, identifier: Accessibility.agentTuiLaunchPane).exists
          || self.element(in: app, identifier: Accessibility.agentTuiSessionPane).exists
      }
    )
  }

  func closeAgentTuiWindow(in app: XCUIApplication) {
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        !self.element(in: app, identifier: Accessibility.agentTuiLaunchPane).exists
          && !self.element(in: app, identifier: Accessibility.agentTuiSessionPane).exists
      }
    )
  }

  func startAgentTui(
    in app: XCUIApplication,
    runtimeTitle: String,
    prompt: String
  ) {
    let launchPane = element(in: app, identifier: Accessibility.agentTuiLaunchPane)
    if !waitForElement(launchPane, timeout: Self.fastPollInterval) {
      tapButton(in: app, identifier: Accessibility.agentTuiCreateTab)
      let state = element(in: app, identifier: Accessibility.agentTuiState)
      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) {
          launchPane.exists || state.label.contains("selection=create")
        }
      )
    }

    tapButton(in: app, title: runtimeTitle)
    let promptField = editableField(in: app, identifier: Accessibility.agentTuiPromptField)
    if !prompt.isEmpty,
      waitForElement(promptField, timeout: Self.fastPollInterval)
    {
      tapViaCoordinate(in: app, element: promptField)
      promptField.typeText(prompt)
    }
    let startTitle = "Start \(runtimeTitle)"
    revealCreateAction(in: app, startTitle: startTitle)
    if button(in: app, title: startTitle).exists || element(in: app, title: startTitle).exists {
      tapButton(in: app, title: startTitle)
    } else {
      tapButton(in: app, identifier: Accessibility.agentTuiStartButton)
    }

    // Skip persona picker if it appears
    let skipButton = element(in: app, identifier: Accessibility.personaSkipButton)
    if waitForElement(skipButton, timeout: Self.fastPollInterval) {
      skipButton.tap()
    }

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.element(in: app, identifier: Accessibility.agentTuiSessionPane).exists
      }
    )
  }

  func tapDockButton(
    in app: XCUIApplication,
    identifier: String,
    label: String
  ) {
    app.activate()
    let trigger = button(in: app, identifier: identifier)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        trigger.exists && !trigger.frame.isEmpty
      },
      "\(label) dock button should be visible in cockpit preview"
    )
    if trigger.isHittable {
      trigger.tap()
    } else if let coordinate = centerCoordinate(in: app, for: trigger) {
      coordinate.tap()
    } else {
      XCTFail("Cannot resolve coordinate for \(label) dock button")
    }
  }

  func tapViaCoordinate(in app: XCUIApplication, element: XCUIElement) {
    guard let coordinate = centerCoordinate(in: app, for: element) else {
      XCTFail("Failed to resolve coordinate for \(element)")
      return
    }
    coordinate.tap()
  }

  func revealCreateAction(in app: XCUIApplication, startTitle: String) {
    let launchPane = element(in: app, identifier: Accessibility.agentTuiLaunchPane)

    for _ in 0 ..< 4 {
      let startButton = button(in: app, identifier: Accessibility.agentTuiStartButton)
      let startProbe = element(in: app, identifier: Accessibility.agentTuiStartButton)
      let startFrame = element(in: app, identifier: "\(Accessibility.agentTuiStartButton).frame")
      let titledButton = button(in: app, title: startTitle)
      let titledElement = element(in: app, title: startTitle)

      if startButton.exists || startProbe.exists || startFrame.exists || titledButton.exists
        || titledElement.exists
      {
        return
      }

      dragUp(in: app, element: launchPane, distanceRatio: 0.22)
    }
  }

  func agentTuiActionExists(
    in app: XCUIApplication,
    title: String,
    identifier: String
  ) -> Bool {
    button(in: app, identifier: identifier).exists
      || element(in: app, identifier: identifier).exists
      || element(in: app, identifier: "\(identifier).frame").exists
      || button(in: app, title: title).exists
      || element(in: app, title: title).exists
  }
}
