import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class DecisionsDetailUITests: HarnessMonitorUITestCase {
  private static let decisionSeedEnvKey = "HARNESS_MONITOR_SUPERVISOR_SEED_DECISIONS"
  private static let uiTestsKey = "HARNESS_MONITOR_UI_TESTS"
  private static let decisionID = "decision-detail-ui-seed"
  private static let dismissActionID = "dismiss-decision-detail-ui-seed"
  private static let fallbackDecisionID = "decision-detail-ui-fallback"

  func testSeededDecisionOpensDetailAndAuditTrail() throws {
    let app = launch(
      mode: "empty",
      additionalEnvironment: [
        Self.uiTestsKey: "1",
        Self.decisionSeedEnvKey: makeSeededDecisionsPayload(),
      ]
    )

    tapButton(in: app, identifier: Accessibility.workspaceToolbarButton)

    let decisionRow = button(in: app, identifier: Accessibility.decisionRow(Self.decisionID))
    XCTAssertTrue(waitForElement(decisionRow, timeout: Self.uiTimeout))
    tapButton(in: app, identifier: Accessibility.decisionRow(Self.decisionID))

    let detail = element(in: app, identifier: Accessibility.decisionDetail)
    XCTAssertTrue(waitForElement(detail, timeout: Self.actionTimeout))

    let dismissButton = button(
      in: app,
      identifier: Accessibility.decisionAction(Self.dismissActionID)
    )
    XCTAssertTrue(waitForElement(dismissButton, timeout: Self.actionTimeout))

    let auditTab = element(
      in: app,
      identifier: Accessibility.segmentedOption(
        Accessibility.decisionDetailTabs,
        option: "Audit Trail"
      )
    )
    XCTAssertTrue(waitForElement(auditTab, timeout: Self.actionTimeout))
    auditTab.tap()

    let auditTrail = element(in: app, identifier: Accessibility.decisionAuditTrail)
    XCTAssertTrue(waitForElement(auditTrail, timeout: Self.actionTimeout))
  }

  private func makeSeededDecisionsPayload() -> String {
    let decision: [String: Any] = [
      "id": Self.decisionID,
      "severity": "warn",
      "ruleID": "stuck-agent",
      "summary": "UI test seeded decision detail",
      "contextJSON": "{\"agentID\":\"agent-detail-ui\"}",
      "suggestedActionsJSON": serializeJSONObject([
        [
          "id": Self.dismissActionID,
          "title": "Dismiss",
          "kind": "dismiss",
          "payloadJSON": "{}",
        ]
      ]),
    ]
    return serializeJSONObject(["decisions": [decision]])
  }

  func testNonAcpDecisionWithoutPersistedActionsStillShowsDismiss() throws {
    let app = launch(
      mode: "empty",
      additionalEnvironment: [
        Self.uiTestsKey: "1",
        Self.decisionSeedEnvKey: makeFallbackSeededDecisionsPayload(),
      ]
    )

    tapButton(in: app, identifier: Accessibility.workspaceToolbarButton)
    XCTAssertTrue(
      waitForElement(
        button(in: app, identifier: Accessibility.decisionRow(Self.fallbackDecisionID)),
        timeout: Self.uiTimeout
      )
    )
    tapButton(in: app, identifier: Accessibility.decisionRow(Self.fallbackDecisionID))
    XCTAssertTrue(
      waitForElement(
        button(
          in: app,
          identifier: Accessibility.decisionAction("dismiss-\(Self.fallbackDecisionID)")
        ),
        timeout: Self.actionTimeout
      )
    )
  }

  private func makeFallbackSeededDecisionsPayload() -> String {
    let decision: [String: Any] = [
      "id": Self.fallbackDecisionID,
      "severity": "warn",
      "ruleID": "stuck-agent",
      "summary": "Fallback action decision",
      "contextJSON": "{\"agentID\":\"agent-fallback-ui\"}",
      "suggestedActionsJSON": "[]",
    ]
    return serializeJSONObject(["decisions": [decision]])
  }

  private func serializeJSONObject(_ object: Any) -> String {
    guard
      let data = try? JSONSerialization.data(withJSONObject: object, options: []),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{\"decisions\":[]}"
    }
    return string
  }
}
