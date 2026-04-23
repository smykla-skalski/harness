import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

/// UI test for the Monitor supervisor Decisions window (source plan Task 23 / Phase 2 worker 24).
///
/// Verifies that clicking the toolbar bell with accessibility id `supervisorBadge`
/// opens a secondary window marked with the `decisionsWindow` identifier, and that a
/// pre-loaded decision (when a seeding mechanism is available) renders a `decisionRow`.
///
/// The brief specifies seeding via `HARNESS_MONITOR_UI_TESTS=1` and a supervisor
/// decision-seed env var. The host must load the seeded row into the Decisions window.
@MainActor
final class DecisionsWindowOpenUITests: HarnessMonitorUITestCase {
  private static let decisionSeedEnvKey = "HARNESS_MONITOR_SUPERVISOR_SEED_DECISIONS"
  private static let uiTestsKey = "HARNESS_MONITOR_UI_TESTS"
  private static let seededDecisionID = "ui-test-seed-decision-1"

  /// Clicking the toolbar bell opens the Decisions window. This assertion holds on the
  /// Phase 1 + early-Phase-2 base because `SupervisorToolbarItem` calls
  /// `openWindow(id: HarnessMonitorWindowID.decisions)` and `DecisionsWindowView`
  /// carries the `decisionsWindow` accessibility identifier.
  func testClickingSupervisorBadgeOpensDecisionsWindow() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [Self.uiTestsKey: "1"]
    )

    let badge = app.buttons
      .matching(identifier: Accessibility.supervisorBadge)
      .firstMatch
    XCTAssertTrue(
      waitForElement(badge, timeout: Self.actionTimeout),
      "Supervisor toolbar badge should exist on first launch"
    )

    if badge.isHittable {
      badge.tap()
    } else if let coordinate = centerCoordinate(in: app, for: badge) {
      coordinate.tap()
    } else {
      XCTFail("Supervisor badge is not reachable for tapping")
    }

    let decisionsWindow = app.windows["Decisions"]

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        decisionsWindow.exists
      },
      "Decisions window should open after tapping the supervisor bell badge"
    )
  }

  /// With a seeded decision the sidebar must render a row carrying the `decisionRow`
  /// accessibility identifier.
  func testSeededDecisionRowAppearsAfterOpeningWindow() throws {
    let seededPayload = makeSeededDecisionsPayload()
    let environment: [String: String] = [
      Self.uiTestsKey: "1",
      Self.decisionSeedEnvKey: seededPayload,
    ]
    let app = launch(mode: "preview", additionalEnvironment: environment)

    let badge = app.buttons
      .matching(identifier: Accessibility.supervisorBadge)
      .firstMatch
    XCTAssertTrue(
      waitForElement(badge, timeout: Self.actionTimeout),
      "Supervisor toolbar badge should exist when a decision is seeded"
    )
    if badge.isHittable {
      badge.tap()
    } else if let coordinate = centerCoordinate(in: app, for: badge) {
      coordinate.tap()
    } else {
      XCTFail("Supervisor badge is not reachable for tapping")
    }

    let seededRow = app.otherElements
      .matching(identifier: Accessibility.decisionRow(Self.seededDecisionID))
      .firstMatch

    XCTAssertTrue(
      waitForElement(seededRow, timeout: Self.uiTimeout),
      "Decisions window should contain the seeded decision row"
    )
  }

  private func makeSeededDecisionsPayload() -> String {
    let decision: [String: Any] = [
      "id": Self.seededDecisionID,
      "severity": "warn",
      "ruleID": "stuck-agent",
      "summary": "UI test seeded decision",
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
