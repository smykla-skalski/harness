import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

extension AgentsWindowUITests {
  func testPersonaPickerVisibleInCreatePane() throws {
    let app = launchInCockpitPreview()

    openAgentsWindow(in: app)

    let picker = element(in: app, identifier: Accessibility.agentTuiPersonaPicker)
    XCTAssertTrue(
      waitForElement(picker, timeout: Self.uiTimeout),
      "Persona picker should be visible in create pane"
    )
  }

  func testTerminalModelPickerVisibleInCreatePane() throws {
    let app = launchInCockpitPreview()

    openAgentsWindow(in: app)

    let picker = element(in: app, identifier: Accessibility.agentsModelPicker)
    XCTAssertTrue(
      waitForElement(picker, timeout: Self.uiTimeout),
      "Terminal model picker should be visible in create pane"
    )
  }

  func testEffortPickerVisibleForReasoningCapableDefaultModel() throws {
    let app = launchInCockpitPreview()

    openAgentsWindow(in: app)

    let effortPicker = element(in: app, identifier: Accessibility.agentsEffortPicker)
    XCTAssertTrue(
      waitForElement(effortPicker, timeout: Self.uiTimeout),
      "Effort picker should be visible when the default terminal model supports reasoning"
    )
  }

  func testCustomModelOptionRevealsTextField() throws {
    let app = launchInCockpitPreview()

    openAgentsWindow(in: app)

    let picker = element(in: app, identifier: Accessibility.agentsModelPicker)
    XCTAssertTrue(waitForElement(picker, timeout: Self.uiTimeout))
    picker.click()

    let customOption = app.menuItems["Custom..."].firstMatch
    XCTAssertTrue(
      waitForElement(customOption, timeout: Self.uiTimeout),
      "Custom... menu item should appear after opening the model picker"
    )
    customOption.click()

    let customField = element(in: app, identifier: Accessibility.agentsCustomModelField)
    XCTAssertTrue(
      waitForElement(customField, timeout: Self.uiTimeout),
      "Custom model text field should appear after selecting Custom..."
    )
  }

  func testTerminalModelPickerSupportsNativePopupFallback() throws {
    let app = launchInCockpitPreview()

    openAgentsWindow(in: app)

    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.agentsModelPicker,
      optionTitle: "Custom..."
    )

    let customField = element(in: app, identifier: Accessibility.agentsCustomModelField)
    XCTAssertTrue(
      waitForElement(customField, timeout: Self.uiTimeout),
      "Terminal model picker should support the native popup fallback path"
    )
  }

  func testCodexModelPickerSupportsNativePopupFallback() throws {
    let app = launchInCockpitPreview()

    openAgentsWindow(in: app)
    tapButton(
      in: app,
      identifier: Accessibility.segmentedOption(
        Accessibility.agentTuiCreateModePicker,
        option: "Codex"
      )
    )

    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.agentsCodexModelPicker,
      optionTitle: "Custom..."
    )

    let customField = element(in: app, identifier: Accessibility.agentsCodexCustomModelField)
    XCTAssertTrue(
      waitForElement(customField, timeout: Self.uiTimeout),
      "Codex model picker should support the native popup fallback path"
    )
  }

  func testEffortPickerHidesForModelWithoutReasoningSupport() throws {
    let app = launchInCockpitPreview()

    openAgentsWindow(in: app)
    tapButton(
      in: app,
      identifier: Accessibility.segmentedOption(
        Accessibility.agentTuiRuntimePicker,
        option: "Gemini"
      )
    )

    let picker = element(in: app, identifier: Accessibility.agentsModelPicker)
    XCTAssertTrue(waitForElement(picker, timeout: Self.uiTimeout))

    // Pick Gemini 2.5 Flash-Lite which the daemon publishes with
    // effort_kind = none. The effort segmented picker should not render.
    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.agentsModelPicker,
      optionTitle: "Gemini 2.5 Flash-Lite"
    )

    let effortPicker = element(in: app, identifier: Accessibility.agentsEffortPicker)
    XCTAssertFalse(
      waitForElement(effortPicker, timeout: Self.fastActionTimeout),
      "Effort picker should be hidden when the selected model does not support reasoning"
    )
  }

  func testEffortSelectionPersistsAcrossRuntimeSwitch() throws {
    let app = launchInCockpitPreview()

    openAgentsWindow(in: app)
    tapButton(
      in: app,
      identifier: Accessibility.segmentedOption(
        Accessibility.agentTuiRuntimePicker,
        option: "Codex"
      )
    )

    let effortPicker = element(in: app, identifier: Accessibility.agentsEffortPicker)
    XCTAssertTrue(waitForElement(effortPicker, timeout: Self.uiTimeout))

    let high = app.buttons[
      HarnessMonitorUITestAccessibility.segmentedOption(
        Accessibility.agentsEffortPicker,
        option: "high"
      )
    ]
    XCTAssertTrue(waitForElement(high, timeout: Self.fastActionTimeout))
    high.click()

    // Navigate away (switch runtime to Gemini) and back to Codex; the stored
    // Codex effort selection should still be "high" when we return.
    tapButton(
      in: app,
      identifier: Accessibility.segmentedOption(
        Accessibility.agentTuiRuntimePicker,
        option: "Gemini"
      )
    )
    tapButton(
      in: app,
      identifier: Accessibility.segmentedOption(
        Accessibility.agentTuiRuntimePicker,
        option: "Codex"
      )
    )

    let stillHigh = app.buttons[
      HarnessMonitorUITestAccessibility.segmentedOption(
        Accessibility.agentsEffortPicker,
        option: "high"
      )
    ]
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        stillHigh.isSelected || (stillHigh.value as? String) == "1"
      },
      "Previously selected effort level should survive a runtime round-trip"
    )
  }

  func testStartingWithDefaultPersonaStartsTui() throws {
    let app = launchInCockpitPreview()

    openAgentsWindow(in: app)
    startAgentTui(in: app, runtimeTitle: "Codex", prompt: "no persona test")

    let sessionPane = element(in: app, identifier: Accessibility.agentTuiSessionPane)
    XCTAssertTrue(
      waitForElement(sessionPane, timeout: Self.actionTimeout),
      "TUI should start with default persona (None)"
    )
  }

  func testCreatePaneTerminalModeRendersNativeFormSections() throws {
    let app = launchInCockpitPreview()

    openAgentsWindow(in: app)

    let providerHeader = app.staticTexts["Provider"]
    let configurationHeader = app.staticTexts["Configuration"]
    let detailsHeader = app.staticTexts["Details"]
    let sizeHeader = app.staticTexts["Terminal size"]

    XCTAssertTrue(
      waitForElement(providerHeader, timeout: Self.actionTimeout),
      "Terminal mode should expose a Provider section header"
    )
    XCTAssertTrue(
      waitForElement(configurationHeader, timeout: Self.actionTimeout),
      "Terminal mode should expose a Configuration section header"
    )
    XCTAssertTrue(
      waitForElement(detailsHeader, timeout: Self.actionTimeout),
      "Terminal mode should expose a Details section header"
    )
    XCTAssertTrue(
      waitForElement(sizeHeader, timeout: Self.actionTimeout),
      "Terminal mode should expose a Terminal size section header"
    )
  }
}
