import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility
private enum CodexFlowSheetAccessibility {
  static let sheet = "harness.sheet.codex-flow"
  static let promptField = "harness.sheet.codex-flow.prompt"
  static let submitButton = "harness.sheet.codex-flow.submit"
  static let recoveryBanner = "harness.sheet.codex-flow.recovery-banner"
  static let flowButton = "harness.session.codex-flow"
}

@MainActor
final class CodexFlowBannerUITests: HarnessMonitorUITestCase {
  func testAgentTuiSheetUsesWidePresentationFrame() throws {
    let app = launchInCockpitPreview()

    openAgentTuiSheet(in: app)

    let sheet = element(in: app, identifier: Accessibility.agentTuiSheet)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        sheet.exists && sheet.frame.width >= 840
      },
      "Agent TUI sheet should stay wide enough to show a useful terminal viewport"
    )
  }

  func testAgentTuiEnableNowRemovesRecoveryBannerAfterSuccessfulReconfigure() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_HOST_BRIDGE_CAPABILITIES": "codex",
        "HARNESS_MONITOR_PREVIEW_HOST_BRIDGE_RECONFIGURE": "apply",
      ]
    )

    openAgentTuiSheet(in: app)

    let banner = element(in: app, identifier: Accessibility.agentTuiRecoveryBanner)
    let enableButton = button(in: app, identifier: Accessibility.agentTuiEnableBridgeButton)
    let startButton = button(in: app, identifier: Accessibility.agentTuiStartButton)

    XCTAssertTrue(waitForElement(banner, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(enableButton, timeout: Self.fastActionTimeout))

    tapButton(in: app, identifier: Accessibility.agentTuiEnableBridgeButton)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        !banner.exists && startButton.exists
      },
      "Successful host bridge reconfigure should dismiss the recovery banner and restore the start action"
    )
    XCTAssertFalse(enableButton.exists)
  }

  func testAgentTuiEnableNowFallsBackToBridgeStartWhenBridgeStops() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_HOST_BRIDGE_CAPABILITIES": "codex",
        "HARNESS_MONITOR_PREVIEW_HOST_BRIDGE_RECONFIGURE": "bridge-stopped",
      ]
    )

    openAgentTuiSheet(in: app)

    let banner = element(in: app, identifier: Accessibility.agentTuiRecoveryBanner)
    let enableButton = button(in: app, identifier: Accessibility.agentTuiEnableBridgeButton)
    let copyButton = button(in: app, identifier: Accessibility.agentTuiCopyCommandButton)
    let unavailableTitle = app.staticTexts["Agent TUI host bridge is not running"]
    let startCommand = app.staticTexts["harness bridge start"]

    XCTAssertTrue(waitForElement(banner, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(enableButton, timeout: Self.fastActionTimeout))

    tapButton(in: app, identifier: Accessibility.agentTuiEnableBridgeButton)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        banner.exists && unavailableTitle.exists && startCommand.exists
      },
      "Stopped host bridge recovery should keep the banner visible, switch it to the unavailable copy, and show the start command"
    )
    XCTAssertFalse(enableButton.exists)
    XCTAssertTrue(copyButton.exists)
  }
}

@MainActor
final class CodexFlowSheetUITests: HarnessMonitorUITestCase {
  func testStartCodexRunShowsQueuedRunWhenPreviewStartSucceeds() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_HOST_BRIDGE_CAPABILITIES": "codex",
        "HARNESS_MONITOR_PREVIEW_CODEX_START": "success",
      ]
    )

    openCodexFlowSheet(in: app)

    let sheet = element(in: app, identifier: CodexFlowSheetAccessibility.sheet)
    let promptField = element(in: app, identifier: CodexFlowSheetAccessibility.promptField)
    let submitButton = button(in: app, identifier: CodexFlowSheetAccessibility.submitButton)
    let recoveryBanner = element(in: app, identifier: CodexFlowSheetAccessibility.recoveryBanner)
    XCTAssertTrue(waitForElement(sheet, timeout: Self.fastActionTimeout))
    XCTAssertTrue(waitForElement(promptField, timeout: Self.fastActionTimeout))

    promptField.tap()
    app.typeText("Investigate the preview failure.")
    tapButton(in: app, identifier: CodexFlowSheetAccessibility.submitButton)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        !app.staticTexts["No Codex runs yet."].exists
          && app.staticTexts["Queued"].exists
          && submitButton.exists
      },
      "Successful preview Codex start should replace the empty state with a queued run"
    )
    XCTAssertFalse(recoveryBanner.exists)
  }

  func testStartCodexRunShowsRunningBridgeUnavailableBannerWhenPreviewStartFails() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_HOST_BRIDGE_CAPABILITIES": "codex",
        "HARNESS_MONITOR_PREVIEW_CODEX_START": "unavailable-running-bridge",
      ]
    )

    openCodexFlowSheet(in: app)

    let promptField = element(in: app, identifier: CodexFlowSheetAccessibility.promptField)
    let banner = element(in: app, identifier: CodexFlowSheetAccessibility.recoveryBanner)
    XCTAssertTrue(waitForElement(promptField, timeout: Self.fastActionTimeout))

    promptField.tap()
    app.typeText("Investigate the preview failure.")
    tapButton(in: app, identifier: CodexFlowSheetAccessibility.submitButton)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        banner.exists
          && app.staticTexts["Codex host bridge is unavailable"].exists
          && app.staticTexts["harness bridge reconfigure --enable codex"].exists
          && !app.staticTexts["harness bridge start"].exists
      },
      "Running bridge Codex failures should keep the banner visible and narrow recovery to bridge reconfigure"
    )
  }
}

extension CodexFlowBannerUITests {
  fileprivate func launchInCockpitPreview(
    additionalEnvironment: [String: String] = [:]
  ) -> XCUIApplication {
    var environment = ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    environment.merge(additionalEnvironment) { _, new in new }
    return launch(
      mode: "preview",
      additionalEnvironment: environment
    )
  }

  fileprivate func openAgentTuiSheet(in app: XCUIApplication) {
    tapDockButton(in: app, identifier: Accessibility.agentTuiButton, label: "agent-tui")
  }

  fileprivate func openCodexFlowSheet(in app: XCUIApplication) {
    tapDockButton(
      in: app,
      identifier: CodexFlowSheetAccessibility.flowButton,
      label: "codex-flow"
    )
  }

  private func tapDockButton(
    in app: XCUIApplication,
    identifier: String,
    label: String
  ) {
    app.activate()
    let trigger = button(in: app, identifier: identifier)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { trigger.exists && !trigger.frame.isEmpty },
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
}

extension CodexFlowSheetUITests {
  fileprivate func launchInCockpitPreview(
    additionalEnvironment: [String: String] = [:]
  ) -> XCUIApplication {
    var environment = ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    environment.merge(additionalEnvironment) { _, new in new }
    return launch(
      mode: "preview",
      additionalEnvironment: environment
    )
  }

  fileprivate func openCodexFlowSheet(in app: XCUIApplication) {
    tapDockButton(
      in: app,
      identifier: CodexFlowSheetAccessibility.flowButton,
      label: "codex-flow"
    )
  }

  private func tapDockButton(
    in app: XCUIApplication,
    identifier: String,
    label: String
  ) {
    app.activate()
    let trigger = button(in: app, identifier: identifier)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { trigger.exists && !trigger.frame.isEmpty },
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
}
