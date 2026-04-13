import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility
private enum CodexFlowSheetAccessibility {
  static let sheet = "harness.sheet.codex-flow"
  static let flowButton = "harness.session.codex-flow"
  static let wipBadge = "harness.session.codex-flow.wip"
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
      "Stopped host bridge recovery should keep the banner visible, "
        + "switch it to the unavailable copy, and show the start command"
    )
    XCTAssertFalse(enableButton.exists)
    XCTAssertTrue(copyButton.exists)
  }
}

@MainActor
final class CodexFlowDockUITests: HarnessMonitorUITestCase {
  func testCodexFlowButtonShowsWIPBadgeAndCannotOpenSheet() throws {
    try skipCodexFlowWhileWIP()

    let app = launchInCockpitPreview()

    app.activate()
    let trigger = button(in: app, identifier: CodexFlowSheetAccessibility.flowButton)
    let wipBadge = element(in: app, identifier: CodexFlowSheetAccessibility.wipBadge)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        trigger.exists && !trigger.frame.isEmpty && wipBadge.exists
      },
      "Codex Flow dock button should stay visible in cockpit preview even while it is disabled"
    )
    XCTAssertFalse(trigger.isEnabled, "Codex Flow should remain disabled while the feature is WIP")

    if let coordinate = centerCoordinate(in: app, for: trigger) {
      coordinate.tap()
    } else {
      XCTFail("Cannot resolve coordinate for codex-flow dock button")
    }

    let sheet = element(in: app, identifier: CodexFlowSheetAccessibility.sheet)
    XCTAssertFalse(
      waitUntil(timeout: Self.fastActionTimeout) { sheet.exists },
      "Tapping the disabled Codex Flow region should not open the sheet"
    )
  }
}

private func skipCodexFlowWhileWIP() throws {
  throw XCTSkip("Codex Flow is temporarily disabled while the feature remains WIP.")
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

extension CodexFlowDockUITests {
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
}
