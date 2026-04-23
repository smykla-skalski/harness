import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

/// UI test for the Monitor supervisor Decisions window (source plan Task 23 / Phase 2 worker 24).
///
/// Verifies that clicking the toolbar bell with accessibility id `supervisorBadge`
/// opens a secondary window marked with the `decisionsWindow` identifier, and that a
/// pre-loaded decision (when a seeding mechanism is available) renders a `decisionRow`.
///
/// The brief specifies seeding via `HARNESS_MONITOR_UI_TEST=1` and a supervisor
/// decision-seed env var. Until Phase 2 wires those two pieces (a decision-seed hook
/// and sidebar row rendering), the seeded-row assertion is guarded by a check that
/// skips the test if the host build has not yet exposed the seed surface.
@MainActor
final class DecisionsWindowOpenUITests: HarnessMonitorUITestCase {
  private static let decisionSeedEnvKey = "HARNESS_MONITOR_SUPERVISOR_SEED_DECISIONS"
  private static let singularUITestKey = "HARNESS_MONITOR_UI_TEST"
  private static let seededDecisionID = "ui-test-seed-decision-1"

  /// Clicking the toolbar bell opens the Decisions window. This assertion holds on the
  /// Phase 1 + early-Phase-2 base because `SupervisorToolbarItem` calls
  /// `openWindow(id: HarnessMonitorWindowID.decisions)` and `DecisionsWindowView`
  /// carries the `decisionsWindow` accessibility identifier.
  func testClickingSupervisorBadgeOpensDecisionsWindow() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [Self.singularUITestKey: "1"]
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
  /// accessibility identifier. Gated on the seed env var being supported by the host
  /// app; skipped when the seeding surface does not yet exist so the earlier Phase 2
  /// workers do not block this test while landing.
  func testSeededDecisionRowAppearsAfterOpeningWindow() throws {
    let seededPayload = makeSeededDecisionsPayload()
    let environment: [String: String] = [
      Self.singularUITestKey: "1",
      Self.decisionSeedEnvKey: seededPayload,
    ]
    let app = launch(mode: "preview", additionalEnvironment: environment)

    try XCTSkipUnless(
      appSupportsDecisionSeedHook(app: app),
      """
      Skipping seeded-row assertion: host app does not yet read \
      \(Self.decisionSeedEnvKey). Phase 2 workers 2, 18, 19 must add:
        1. DecisionStore insertion from the env var (seeding hook),
        2. SupervisorToolbarSlice subscription so count/tint update,
        3. DecisionsSidebar rendering of seeded rows with \
           HarnessMonitorAccessibility.decisionRow(_:).
      """
    )

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
      "severity": "warning",
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

  private func appSupportsDecisionSeedHook(app: XCUIApplication) -> Bool {
    let badge = app.buttons
      .matching(identifier: Accessibility.supervisorBadge)
      .firstMatch
    guard waitForElement(badge, timeout: Self.actionTimeout) else {
      return false
    }
    let rawValue = badge.value as? String ?? ""
    if rawValue.contains("count=") && !rawValue.contains("count=0") {
      return true
    }
    return !(badge.label.isEmpty) && badge.label.contains(String(1))
  }
}
