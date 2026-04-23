import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

/// Covers chunk 8/9 affordances on the Decisions window: the inspector column with the
/// metadata grid, the ⌘⌥I toggle button, and the bulk-actions menu items. Single-launch per
/// `feedback_narrow_ui_test_runs.md`; uses `.firstMatch` lookups and never resolves elements
/// through Section identifiers.
@MainActor
final class DecisionsInspectorUITests: HarnessMonitorUITestCase {
  private static let decisionSeedEnvKey = "HARNESS_MONITOR_SUPERVISOR_SEED_DECISIONS"
  private static let uiTestsKey = "HARNESS_MONITOR_UI_TESTS"
  private static let infoDecisionID = "ui-inspector-info"
  private static let criticalDecisionID = "ui-inspector-critical"

  func testInspectorTogglesAndExposesMetadataAndBulkMenu() throws {
    let app = launch(
      mode: "empty",
      additionalEnvironment: [
        Self.uiTestsKey: "1",
        Self.decisionSeedEnvKey: makeSeededDecisionsPayload(),
      ]
    )

    tapButton(in: app, identifier: Accessibility.supervisorBadge)

    let row = button(in: app, identifier: Accessibility.decisionRow(Self.criticalDecisionID))
    XCTAssertTrue(waitForElement(row, timeout: Self.uiTimeout))
    tapButton(in: app, identifier: Accessibility.decisionRow(Self.criticalDecisionID))

    let detail = element(in: app, identifier: Accessibility.decisionDetail)
    XCTAssertTrue(waitForElement(detail, timeout: Self.actionTimeout))

    let inspector = element(in: app, identifier: Accessibility.decisionInspector)
    XCTAssertTrue(
      waitForElement(inspector, timeout: Self.actionTimeout),
      "Inspector should be visible by default on first launch (chunk 8 default)"
    )

    let metadata = element(in: app, identifier: Accessibility.decisionInspectorMetadata)
    XCTAssertTrue(
      waitForElement(metadata, timeout: Self.actionTimeout),
      "Inspector metadata grid should be present when a decision is selected"
    )

    let bulkMenu = element(in: app, identifier: Accessibility.decisionBulkActions)
    XCTAssertTrue(
      waitForElement(bulkMenu, timeout: Self.actionTimeout),
      "Bulk-actions toolbar menu should be present in primaryAction slot"
    )

    let toggle = button(in: app, identifier: Accessibility.decisionInspectorToggle)
    XCTAssertTrue(waitForElement(toggle, timeout: Self.actionTimeout))

    app.typeKey("i", modifierFlags: [.command, .option])
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !inspector.exists },
      "Inspector should hide after ⌘⌥I"
    )

    app.typeKey("i", modifierFlags: [.command, .option])
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { inspector.exists },
      "Inspector should restore after a second ⌘⌥I"
    )
  }

  private func makeSeededDecisionsPayload() -> String {
    let info: [String: Any] = [
      "id": Self.infoDecisionID,
      "severity": "info",
      "ruleID": "lint-debt",
      "summary": "Info decision for bulk-dismiss seed",
      "contextJSON": "{}",
      "suggestedActionsJSON": "[]",
    ]
    let critical: [String: Any] = [
      "id": Self.criticalDecisionID,
      "severity": "critical",
      "ruleID": "secret-exposed",
      "summary": "Critical decision for inspector metadata coverage",
      "contextJSON": "{\"snapshotExcerpt\":\"agent=agent-04 severity=critical\"}",
      "suggestedActionsJSON": "[]",
    ]
    return serializeJSONObject(["decisions": [critical, info]])
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
