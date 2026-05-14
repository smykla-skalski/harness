import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class PolicyCanvasUITests: HarnessMonitorUITestCase {
  private static let previewSessionID = "sess1234"
  override nonisolated static var reuseLaunchedApp: Bool { true }

  func testPolicyCanvasOpensFromDashboardWithPromoteGated() throws {
    let app = openPolicyCanvasSessionRoute()

    let root = element(in: app, identifier: Accessibility.policyCanvasRoot)
    XCTAssertTrue(root.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(element(in: app, identifier: Accessibility.policyCanvasViewport).exists)
    XCTAssertTrue(element(in: app, identifier: Accessibility.policyCanvasToolRail).exists)
    XCTAssertTrue(element(in: app, identifier: Accessibility.policyCanvasInspector).exists)
    XCTAssertFalse(button(in: app, identifier: Accessibility.policyCanvasPromoteButton).isEnabled)
  }

  func testPolicyCanvasNodeDragMovesPreviewNode() throws {
    let app = openPolicyCanvasSessionRoute()

    let node = element(in: app, identifier: Accessibility.policyCanvasNode("risk-score"))
    XCTAssertTrue(node.waitForExistence(timeout: Self.actionTimeout))

    let originalFrame = node.frame
    let start = node.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let end = node.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85))
    start.press(forDuration: 0.1, thenDragTo: end)

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        node.frame.origin != originalFrame.origin
      },
      "Dragging a policy node should update its canvas position"
    )
  }

  private func openPolicyCanvasSessionRoute() -> XCUIApplication {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard-landing"]
    )

    if !element(in: app, identifier: Accessibility.sessionWindowShell).exists {
      let openRecentWindow = element(in: app, identifier: Accessibility.openRecentRoot)
      XCTAssertTrue(waitForElement(openRecentWindow, timeout: Self.uiTimeout))
      tapButton(
        in: app,
        identifier: Accessibility.openRecentSessionRow(Self.previewSessionID)
      )
      XCTAssertTrue(
        waitForElement(
          element(in: app, identifier: Accessibility.sessionWindowShell),
          timeout: Self.actionTimeout
        )
      )
    }

    tapButton(in: app, identifier: Accessibility.sessionWindowRoute("policyCanvas"))
    return app
  }
}
