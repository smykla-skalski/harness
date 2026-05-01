import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

/// UI tests for the consolidated Workspace toolbar/window flow.
@MainActor
final class WorkspaceWindowOpenUITests: HarnessMonitorUITestCase {
  private static let decisionSeedEnvKey = "HARNESS_MONITOR_SUPERVISOR_SEED_DECISIONS"
  private static let uiTestsKey = "HARNESS_MONITOR_UI_TESTS"
  private static let seededDecisionID = "ui-test-seed-decision-1"

  func testClickingWorkspaceToolbarButtonOpensWorkspaceWindow() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: [Self.uiTestsKey: "1"]
    )

    let badge = app.buttons
      .matching(identifier: Accessibility.workspaceToolbarButton)
      .firstMatch
    XCTAssertTrue(
      waitForElement(badge, timeout: Self.actionTimeout),
      "Workspace toolbar button should exist on first launch"
    )

    if badge.isHittable {
      badge.tap()
    } else if let coordinate = centerCoordinate(in: app, for: badge) {
      coordinate.tap()
    } else {
      XCTFail("Workspace toolbar button is not reachable for tapping")
    }

    let workspaceWindow = element(in: app, identifier: Accessibility.workspaceWindow)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        workspaceWindow.exists
      },
      "Workspace window should open after tapping the workspace toolbar button"
    )
  }

  func testSeededDecisionRowAppearsAfterOpeningWorkspaceWindow() throws {
    let seededPayload = makeSeededDecisionsPayload()
    let environment: [String: String] = [
      Self.uiTestsKey: "1",
      Self.decisionSeedEnvKey: seededPayload,
    ]
    let app = launch(mode: "empty", additionalEnvironment: environment)

    let badge = app.buttons
      .matching(identifier: Accessibility.workspaceToolbarButton)
      .firstMatch
    XCTAssertTrue(
      waitForElement(badge, timeout: Self.actionTimeout),
      "Workspace toolbar button should exist when a decision is seeded"
    )
    if badge.isHittable {
      badge.tap()
    } else if let coordinate = centerCoordinate(in: app, for: badge) {
      coordinate.tap()
    } else {
      XCTFail("Workspace toolbar button is not reachable for tapping")
    }

    let seededRow = button(
      in: app,
      identifier: Accessibility.decisionRow(Self.seededDecisionID)
    )

    XCTAssertTrue(
      waitForElement(seededRow, timeout: Self.uiTimeout),
      "Workspace window should contain the seeded decision row"
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
