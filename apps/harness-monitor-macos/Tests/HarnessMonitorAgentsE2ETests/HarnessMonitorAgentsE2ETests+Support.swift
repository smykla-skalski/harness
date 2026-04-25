import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension HarnessMonitorAgentsE2ETests {
  static let liveActionTimeout: TimeInterval = 8
  static let liveStartupTimeout: TimeInterval = 20
  static let codexCompletionTimeout: TimeInterval = 120
  static let liveCodexModelEnvKey = "HARNESS_MONITOR_E2E_CODEX_MODEL"
  static let liveCodexEffortEnvKey = "HARNESS_MONITOR_E2E_CODEX_EFFORT"
  static let codexModelDisplayNameByID: [String: String] = [
    "gpt-5.5": "GPT-5.5",
    "gpt-5.4": "GPT-5.4",
    "gpt-5.4-mini": "GPT-5.4 mini",
    "gpt-5.3-codex": "GPT-5.3 Codex",
    "gpt-5.3-codex-spark": "GPT-5.3 Codex Spark",
    "gpt-5.2": "GPT-5.2",
  ]

  /// Display name of the cheapest/fastest model exposed by each runtime's
  /// catalog. E2E runs use these to keep token spend and turnaround low.
  /// Keep in sync with `src/agents/runtime/models/catalogs.rs::cheapest_fastest`.
  static let e2eFastModelDisplayName: [String: String] = [
    "codex": "GPT-5.3 Codex Spark",
    "claude": "Haiku 4.5",
    "gemini": "Gemini 2.5 Flash-Lite",
    "copilot": "GPT-5.4 mini",
    "vibe": "Mistral Small 4",
    "opencode": "Claude Haiku 4.5",
  ]

  static let e2eLowestEffortTitle: [String: String] = [
    "codex": "Low",
    "claude": "Off",
    "opencode": "Off",
  ]

  func selectFastModelForTerminal(in app: XCUIApplication, runtime: String) {
    guard let displayName = Self.e2eFastModelDisplayName[runtime] else { return }
    revealAction(
      in: app,
      containerIdentifier: Accessibility.agentTuiLaunchPane,
      identifier: Accessibility.agentsModelPicker,
      title: "Model"
    )
    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.agentsModelPicker,
      optionTitle: displayName
    )
    if let effortTitle = Self.e2eLowestEffortTitle[runtime] {
      selectSegment(
        in: app,
        controlIdentifier: Accessibility.agentsEffortPicker,
        title: effortTitle
      )
    }
  }

  func selectFastModelForCodex(in app: XCUIApplication) {
    if let customModel = ProcessInfo.processInfo.environment[Self.liveCodexModelEnvKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !customModel.isEmpty
    {
      if let displayName = Self.codexModelDisplayNameByID[customModel] {
        selectMenuOption(
          in: app,
          controlIdentifier: Accessibility.agentsCodexModelPicker,
          optionTitle: displayName
        )
        if let effort = ProcessInfo.processInfo.environment[Self.liveCodexEffortEnvKey]?
          .trimmingCharacters(in: .whitespacesAndNewlines),
          !effort.isEmpty
        {
          selectSegment(
            in: app,
            controlIdentifier: Accessibility.agentsCodexEffortPicker,
            title: effort.capitalized
          )
        }
        return
      }
      selectMenuOption(
        in: app,
        controlIdentifier: Accessibility.agentsCodexModelPicker,
        optionTitle: "Custom..."
      )
      replaceText(
        in: app,
        identifier: Accessibility.agentsCodexCustomModelField,
        text: customModel
      )
      if let effort = ProcessInfo.processInfo.environment[Self.liveCodexEffortEnvKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !effort.isEmpty
      {
        selectSegment(
          in: app,
          controlIdentifier: Accessibility.agentsCodexEffortPicker,
          title: effort.capitalized
        )
      }
      return
    }
    guard let displayName = Self.e2eFastModelDisplayName["codex"] else { return }
    revealAction(
      in: app,
      containerIdentifier: Accessibility.agentTuiLaunchPane,
      identifier: Accessibility.agentsCodexModelPicker,
      title: "Model"
    )
    selectMenuOption(
      in: app,
      controlIdentifier: Accessibility.agentsCodexModelPicker,
      optionTitle: displayName
    )
    selectSegment(
      in: app,
      controlIdentifier: Accessibility.agentsCodexEffortPicker,
      title: Self.e2eLowestEffortTitle["codex"] ?? "Low"
    )
  }

  func setUpLiveHarness(purpose: String) throws -> HarnessMonitorAgentsE2ELiveHarness {
    try HarnessMonitorAgentsE2ELiveHarness.setUp(for: self, purpose: purpose)
  }

  func launchLiveAgentsApp(
    using harness: HarnessMonitorAgentsE2ELiveHarness,
    additionalEnvironment: [String: String] = [:]
  ) -> XCUIApplication {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    terminateIfRunning(app)
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment = harness.appLaunchEnvironment
      .merging(additionalEnvironment) { _, new in new }
    guard armRecordingStartIfConfigured(context: harness.diagnosticsSummary()) else {
      return app
    }
    app.launch()

    XCTAssertTrue(
      waitUntil(timeout: Self.liveStartupTimeout) {
        if app.state != .runningForeground {
          app.activate()
        }
        return app.state == .runningForeground || self.mainWindow(in: app).exists
      },
      harness.diagnosticsSummary()
    )
    guard waitForRecordingStartIfConfigured(context: harness.diagnosticsSummary()) else {
      return app
    }
    XCTAssertTrue(
      waitUntil(timeout: Self.liveStartupTimeout) {
        let window = self.mainWindow(in: app)
        return window.exists && window.frame.width > 0 && window.frame.height > 0
      },
      harness.diagnosticsSummary()
    )
    return app
  }

  func openLiveSessionCockpit(
    in app: XCUIApplication,
    sessionID: String,
    harness: HarnessMonitorAgentsE2ELiveHarness
  ) {
    let sessionIdentifier = Accessibility.sessionRow(sessionID)
    let sessionRow = sessionTrigger(in: app, identifier: sessionIdentifier)
    XCTAssertTrue(
      waitForElement(sessionRow, timeout: Self.liveStartupTimeout),
      "Expected live session row \(sessionIdentifier)\n\(harness.diagnosticsSummary())"
    )
    let toolbarState = element(in: app, identifier: Accessibility.toolbarChromeState)
    let selectionReachedCockpit = {
      self.sessionRowIsSelected(sessionRow)
        || toolbarState.label.contains("windowTitle=Cockpit")
    }
    let attemptSelection = {
      self.tapSession(in: app, identifier: sessionIdentifier)
      return self.waitUntil(timeout: 1.5) {
        selectionReachedCockpit()
      }
    }

    if !selectionReachedCockpit() {
      let selected = attemptSelection() || attemptSelection() || attemptSelection()
      XCTAssertTrue(
        selected,
        """
        Live session row never reported selection.
        rowValue=\(String(describing: sessionRow.value))
        toolbarState=\(toolbarState.label)
        \(harness.diagnosticsSummary())
        """
      )
    }

    let agentsButton = button(in: app, identifier: Accessibility.agentsButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.liveStartupTimeout) {
        toolbarState.label.contains("windowTitle=Cockpit")
          && agentsButton.exists
      },
      """
      Session cockpit did not load for \(sessionID)
      toolbarState=\(toolbarState.label)
      rowValue=\(String(describing: sessionRow.value))
      \(harness.diagnosticsSummary())
      """
    )
  }

  func openAgentsWindow(
    in app: XCUIApplication,
    harness: HarnessMonitorAgentsE2ELiveHarness
  ) {
    tapDockButton(in: app, identifier: Accessibility.agentsButton, label: "agents")
    let launchPane = element(in: app, identifier: Accessibility.agentTuiLaunchPane)
    let sessionPane = element(in: app, identifier: Accessibility.agentTuiSessionPane)
    let state = element(in: app, identifier: Accessibility.agentTuiState)
    XCTAssertTrue(
      waitUntil(timeout: Self.liveActionTimeout) {
        launchPane.exists || sessionPane.exists
      },
      """
      Agents window did not appear.
      state=\(state.label)
      \(harness.diagnosticsSummary())
      """
    )

    if !launchPane.exists {
      tapButton(in: app, identifier: Accessibility.agentTuiCreateTab)
      XCTAssertTrue(
        waitForElement(launchPane, timeout: Self.liveActionTimeout),
        """
        Agents window never reached the create pane.
        state=\(state.label)
        \(harness.diagnosticsSummary())
        """
      )
    }
  }

  func tapDockButton(in app: XCUIApplication, identifier: String, label: String) {
    app.activate()
    let trigger = button(in: app, identifier: identifier)
    XCTAssertTrue(
      waitUntil(timeout: Self.liveActionTimeout) {
        trigger.exists && !trigger.frame.isEmpty
      },
      "\(label) button should be visible"
    )
    if trigger.isHittable {
      trigger.tap()
      return
    }
    if let coordinate = centerCoordinate(in: app, for: trigger) {
      coordinate.tap()
      return
    }
    XCTFail("Cannot resolve coordinate for \(label) button")
  }

  func replaceText(
    in app: XCUIApplication,
    identifier: String,
    text: String
  ) {
    let field = editableField(in: app, identifier: identifier)
    XCTAssertTrue(waitForElement(field, timeout: Self.liveActionTimeout))
    if field.isHittable {
      field.tap()
    } else if let coordinate = centerCoordinate(in: app, for: field) {
      coordinate.tap()
    } else {
      XCTFail("Cannot resolve editable field \(identifier)")
      return
    }
    app.typeKey("a", modifierFlags: .command)
    app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
    if !text.isEmpty {
      field.typeText(text)
    }
  }

  func revealAction(
    in app: XCUIApplication,
    containerIdentifier: String,
    identifier: String,
    title: String
  ) {
    let container = element(in: app, identifier: containerIdentifier)
    let scrollTarget = container.exists ? container : mainWindow(in: app)
    let deadline = Date.now.addingTimeInterval(Self.liveActionTimeout)

    while Date.now < deadline {
      let candidates = [
        button(in: app, identifier: identifier),
        element(in: app, identifier: identifier),
        element(in: app, identifier: "\(identifier).frame"),
        button(in: app, title: title),
      ]
      if candidates.contains(where: \.exists) {
        return
      }

      dragUp(in: app, element: scrollTarget, distanceRatio: 0.18)
      RunLoop.current.run(until: Date.now.addingTimeInterval(Self.fastPollInterval))
    }
  }

  func selectSegment(
    in app: XCUIApplication,
    controlIdentifier: String,
    title: String
  ) {
    let optionIdentifier = Accessibility.segmentedOption(controlIdentifier, option: title)
    let option = button(in: app, identifier: optionIdentifier)
    if waitForElement(option, timeout: Self.liveActionTimeout) {
      if option.isHittable {
        option.tap()
      } else if let coordinate = centerCoordinate(in: app, for: option) {
        coordinate.tap()
      } else {
        XCTFail("Cannot resolve segment option \(title) in \(controlIdentifier)")
      }
      return
    }

    let control = segmentedControl(in: app, identifier: controlIdentifier)
    XCTAssertTrue(waitForElement(control, timeout: Self.liveActionTimeout))

    let candidates: [XCUIElement] = [
      control.buttons[title],
      control.radioButtons[title],
      control.staticTexts[title],
      control.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title))
        .firstMatch,
    ]

    for candidate in candidates where candidate.exists {
      if candidate.isHittable {
        candidate.tap()
        return
      }
      if let coordinate = centerCoordinate(in: app, for: candidate) {
        coordinate.tap()
        return
      }
    }

    XCTFail("Failed to select segment \(title) in \(controlIdentifier)")
  }
}
