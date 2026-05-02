import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class WorkspaceToolbarButtonUITests:
  HarnessMonitorUITestCase,
  WorkspaceWindowUITestSupporting
{
  private static let decisionSeedEnvKey = "HARNESS_MONITOR_SUPERVISOR_SEED_DECISIONS"
  private static let uiTestsKey = "HARNESS_MONITOR_UI_TESTS"
  private static let seededSnapshotKey = "HARNESS_MONITOR_SUPERVISOR_SEED_SNAPSHOT"
  private static let decisionID = "stuck-agent:session-ui-stuck:agent-ui-stuck:task-ui-stuck"
  private static let dismissActionID = "dismiss-agent-ui-stuck"
  private static let filteredDecisionID = "ui-test-filter-reset-decision"

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

  func testToolbarOpenClearsPersistedDecisionSeverityFilters() throws {
    let app = launch(
      mode: "empty",
      additionalEnvironment: [
        Self.uiTestsKey: "1",
        Self.decisionSeedEnvKey: makeSeededDecisionPayload(),
      ]
    )

    let badgeState = element(in: app, identifier: Accessibility.workspaceToolbarButtonState)
    XCTAssertTrue(
      waitForElement(badgeState, timeout: Self.actionTimeout),
      "Toolbar state marker should exist before the decision badge is asserted"
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.markerText(for: badgeState) == "count=1 severity=warn tint=orange badge=visible"
      },
      """
      Toolbar badge should expose one warning decision before opening the workspace.
      actual='\(markerText(for: badgeState))'
      """
    )

    tapButton(in: app, identifier: Accessibility.workspaceToolbarButton)

    let workspaceWindow = element(in: app, identifier: Accessibility.workspaceWindow)
    let decisionRow = button(
      in: app,
      identifier: Accessibility.decisionRow(Self.filteredDecisionID)
    )
    let decisionDesk = element(in: app, identifier: Accessibility.workspaceDecisionDesk)
    let filterState = element(in: app, identifier: Accessibility.workspaceDecisionFilterState)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { workspaceWindow.exists },
      "Workspace window should open before the seeded warning row is checked"
    )
    XCTAssertTrue(
      waitForElement(decisionRow, timeout: Self.actionTimeout),
      "Seeded warning decision row should appear before filters are changed"
    )
    XCTAssertTrue(
      waitForElement(filterState, timeout: Self.actionTimeout),
      "Decision filter state marker should appear before the toolbar filter menu is used"
    )

    openAgentsDecisionFilters(in: app)
    tapButton(in: app, title: "Critical")

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        filterState.label.contains("severities=critical")
          && decisionDesk.label.contains("0 of 1 in view")
          && !decisionRow.exists
      },
      """
      Critical-only filtering should hide the seeded warning decision before the toolbar reopen.
      filter='\(filterState.label)' desk='\(decisionDesk.label)' rowExists=\(decisionRow.exists)
      """
    )

    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        !workspaceWindow.exists
      },
      "Workspace window should close before reopening it from the toolbar"
    )

    tapButton(in: app, identifier: Accessibility.workspaceToolbarButton)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        workspaceWindow.exists
          && filterState.label.contains("severities=all")
          && decisionRow.exists
      },
      """
      Reopening from the toolbar should clear persisted severity filters so the pending decision is visible.
      filter='\(filterState.label)' desk='\(decisionDesk.label)' rowExists=\(decisionRow.exists)
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

  private func makeSeededDecisionPayload() -> String {
    let decision: [String: Any] = [
      "id": Self.filteredDecisionID,
      "severity": "warn",
      "ruleID": "stuck-agent",
      "summary": "UI test seeded warning decision",
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
