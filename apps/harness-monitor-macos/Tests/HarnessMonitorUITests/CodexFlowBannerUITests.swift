import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class CodexFlowBannerUITests: HarnessMonitorUITestCase {
  func testAgentTuiInlineCopyButtonExists() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_FORCE_BRIDGE_ISSUES": "agent-tui"]
    )

    openAgentTuiSheet(in: app)

    let sheet = element(in: app, identifier: Accessibility.agentTuiSheet)
    XCTAssertTrue(
      sheet.waitForExistence(timeout: Self.actionTimeout),
      "Agent TUI sheet should appear after tapping the dock button"
    )

    let banner = element(in: app, identifier: Accessibility.agentTuiRecoveryBanner)
    XCTAssertTrue(
      banner.waitForExistence(timeout: Self.actionTimeout),
      "Agent TUI recovery banner should appear when bridge excludes agent-tui"
    )

    let copyButton = button(in: app, identifier: Accessibility.agentTuiCopyCommandButton)
    XCTAssertTrue(
      copyButton.waitForExistence(timeout: Self.actionTimeout),
      "Inline copy command button should exist inside the agent-tui recovery banner"
    )
  }

  func testCodexInlineCopyButtonExists() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_FORCE_BRIDGE_ISSUES": "codex"]
    )

    openCodexFlowSheet(in: app)

    let sheet = element(in: app, identifier: Accessibility.codexFlowSheet)
    XCTAssertTrue(
      sheet.waitForExistence(timeout: Self.actionTimeout),
      "Codex Flow sheet should appear after tapping the dock button"
    )

    let banner = element(in: app, identifier: Accessibility.codexFlowRecoveryBanner)
    XCTAssertTrue(
      banner.waitForExistence(timeout: Self.actionTimeout),
      "Codex recovery banner should appear when bridge excludes codex"
    )

    let copyButton = button(in: app, identifier: Accessibility.codexFlowCopyCommandButton)
    XCTAssertTrue(
      copyButton.waitForExistence(timeout: Self.actionTimeout),
      "Inline copy command button should exist inside the codex recovery banner"
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
    tapDockButton(in: app, identifier: Accessibility.codexFlowButton, label: "codex-flow")
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
