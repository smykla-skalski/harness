import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class AttentionInfrastructureUITests_SidebarBadge:
  HarnessMonitorUITestCase,
  AgentsWindowUITestSupporting
{
  private static let decisionSeedEnvKey = "HARNESS_MONITOR_SUPERVISOR_SEED_DECISIONS"
  private static let uiTestsKey = "HARNESS_MONITOR_UI_TESTS"
  private static let previewAcpKey = "HARNESS_MONITOR_PREVIEW_ACP_PENDING"
  private static let agentID = "worker-codex"
  private static let decisionID = "ui-test-acp-decision-worker-codex"

  func testSidebarBadgeAndDetailStripRouteToDecisions() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        Self.uiTestsKey: "1",
        Self.previewAcpKey: "1",
        Self.decisionSeedEnvKey: makeSeededDecisionsPayload(),
      ]
    )

    openAgentsWindow(in: app)

    let badge = element(in: app, identifier: Accessibility.agentPendingDecisionBadge(Self.agentID))
    XCTAssertTrue(
      waitForElement(badge, timeout: Self.uiTimeout),
      "Sidebar badge should appear for agent with pending ACP permission requests"
    )

    tapButton(in: app, identifier: Accessibility.agentTuiExternalTab(Self.agentID))

    let strip = element(
      in: app,
      identifier: Accessibility.agentDetailAwaitingDecisionStrip(Self.agentID)
    )
    XCTAssertTrue(
      waitForElement(strip, timeout: Self.uiTimeout),
      "Agent detail should surface the awaiting-decision strip"
    )

    let stripState = element(
      in: app,
      identifier: Accessibility.agentsWindowDetailAwaitingDecisionState
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.markerText(for: stripState).contains("count=2")
      },
      "Strip state marker should publish the pending request count"
    )

    tapButton(in: app, identifier: Accessibility.agentDetailOpenDecisionsButton(Self.agentID))

    let decisionsWindow = element(in: app, identifier: Accessibility.decisionsWindow)
    XCTAssertTrue(waitForElement(decisionsWindow, timeout: Self.uiTimeout))

    let decisionRow = button(
      in: app,
      identifier: Accessibility.decisionRow(Self.decisionID)
    )
    XCTAssertTrue(
      waitForElement(decisionRow, timeout: Self.uiTimeout),
      "Open in Decisions should route to a decision row for the same agent"
    )
    XCTAssertEqual(decisionRow.value as? String, "selected")
  }

  private func markerText(for element: XCUIElement) -> String {
    if !element.label.isEmpty {
      return element.label
    }
    if let value = element.value as? String, !value.isEmpty {
      return value
    }
    return element.debugDescription
  }

  private func makeSeededDecisionsPayload() -> String {
    let decision: [String: Any] = [
      "id": Self.decisionID,
      "severity": "warn",
      "ruleID": "stuck-agent",
      "sessionID": "sess-harness",
      "agentID": Self.agentID,
      "summary": "Worker codex requires approval",
    ]
    let payload: [String: Any] = ["decisions": [decision]]
    guard
      let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
      let serialized = String(data: data, encoding: .utf8)
    else {
      return "{\"decisions\":[]}"
    }
    return serialized
  }
}
