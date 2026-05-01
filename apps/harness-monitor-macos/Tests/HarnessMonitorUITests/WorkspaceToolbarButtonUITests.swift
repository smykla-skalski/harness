import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class WorkspaceToolbarButtonUITests: HarnessMonitorUITestCase {
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

    let forceTick = button(in: app, identifier: Accessibility.workspaceToolbarForceTick)
    XCTAssertTrue(
      waitForElement(forceTick, timeout: Self.actionTimeout),
      "UI test host should expose a workspace toolbar force-tick control"
    )
    tapButton(in: app, identifier: Accessibility.workspaceToolbarForceTick)

    let badge = button(in: app, identifier: Accessibility.workspaceToolbarButton)
    XCTAssertTrue(
      waitForElement(badge, timeout: Self.actionTimeout),
      "Workspace toolbar button should exist on launch"
    )
    let badgeState = element(in: app, identifier: Accessibility.workspaceToolbarButtonState)
    XCTAssertTrue(
      waitForElement(badgeState, timeout: Self.actionTimeout),
      "UI test host should publish workspace toolbar state"
    )

    let activeBadgeState =
      "count=1 severity=needsUser tint=orange badge=visible"
    XCTAssertTrue(
      waitUntil(timeout: Self.uiTimeout) {
        badge.exists && self.markerText(for: badgeState) == activeBadgeState
      },
      """
      Toolbar state should report one orange warning after the forced tick.
      actual='\(markerText(for: badgeState))'
      """
    )

    tapButton(in: app, identifier: Accessibility.workspaceToolbarButton)

    let workspaceWindow = element(in: app, identifier: Accessibility.workspaceWindow)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { workspaceWindow.exists },
      "Workspace window should open after tapping the toolbar button"
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
        self.markerText(for: badgeState)
          == "count=0 severity=none tint=secondary badge=hidden"
      },
      """
      Resolving the decision should clear the workspace toolbar state.
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
