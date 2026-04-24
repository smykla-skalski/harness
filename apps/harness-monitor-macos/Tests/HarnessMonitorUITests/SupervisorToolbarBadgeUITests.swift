import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class SupervisorToolbarBadgeUITests: HarnessMonitorUITestCase {
  private static let uiTestsKey = "HARNESS_MONITOR_UI_TESTS"
  private static let seededSnapshotKey = "HARNESS_MONITOR_SUPERVISOR_SEED_SNAPSHOT"
  private static let decisionID = "stuck-agent:session-ui-stuck:agent-ui-stuck:task-ui-stuck"
  private static let dismissActionID = "dismiss-agent-ui-stuck"

  func testToolbarBadgeReflectsSeededTickAndClearsAfterResolve() throws {
    let app = launch(
      mode: "empty",
      additionalEnvironment: [
        Self.uiTestsKey: "1",
        Self.seededSnapshotKey: "stuck-agent",
      ]
    )

    let forceTick = button(in: app, identifier: Accessibility.supervisorForceTick)
    XCTAssertTrue(
      waitForElement(forceTick, timeout: Self.actionTimeout),
      "UI test host should expose a force-supervisor-tick control"
    )
    tapButton(in: app, identifier: Accessibility.supervisorForceTick)

    let badge = button(in: app, identifier: Accessibility.supervisorBadge)
    XCTAssertTrue(
      waitForElement(badge, timeout: Self.actionTimeout),
      "Supervisor toolbar badge should exist on launch"
    )
    let badgeState = element(in: app, identifier: Accessibility.supervisorBadgeState)
    XCTAssertTrue(
      waitForElement(badgeState, timeout: Self.actionTimeout),
      "UI test host should publish supervisor badge state"
    )

    let activeBadgeState = "count=1 severity=needsUser tint=orange"
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        badge.exists && self.markerText(for: badgeState) == activeBadgeState
      },
      """
      Badge state should report one orange warning after the forced supervisor tick.
      actual='\(markerText(for: badgeState))'
      """
    )

    tapButton(in: app, identifier: Accessibility.supervisorBadge)

    let decisionsWindow = element(in: app, identifier: Accessibility.decisionsWindow)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { decisionsWindow.exists },
      "Decisions window should open after tapping the toolbar badge"
    )

    let decisionRow = button(
      in: app,
      identifier: Accessibility.decisionRow(Self.decisionID)
    )
    XCTAssertTrue(
      waitForElement(decisionRow, timeout: Self.uiTimeout),
      "Forced tick should open a matching stuck-agent decision row"
    )
    tapButton(in: app, identifier: Accessibility.decisionRow(Self.decisionID))

    let dismissButton = button(
      in: app,
      identifier: Accessibility.decisionAction(Self.dismissActionID)
    )
    XCTAssertTrue(
      waitForElement(dismissButton, timeout: Self.actionTimeout),
      "Decision detail should expose the dismiss action"
    )
    tapButton(in: app, identifier: Accessibility.decisionAction(Self.dismissActionID))

    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        self.markerText(for: badgeState) == "count=0 severity=none tint=secondary"
      },
      """
      Resolving the decision should clear the toolbar badge state.
      actual='\(markerText(for: badgeState))'
      """
    )
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
}
