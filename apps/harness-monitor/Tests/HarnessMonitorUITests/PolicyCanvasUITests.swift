import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class PolicyCanvasUITests: HarnessMonitorUITestCase {
  private static let previewScenarioKey = "HARNESS_MONITOR_PREVIEW_SCENARIO"
  private static let initialRouteKey = "HARNESS_MONITOR_UI_TEST_SESSION_ROUTE"
  private static let previewPolicyCanvasScenario = "policy-canvas"
  private static let policyCanvasRoute = "policyCanvas"
  override nonisolated static var reuseLaunchedApp: Bool { true }

  func testPolicyCanvasSessionRouteRendersCoreChrome() throws {
    let app = openPolicyCanvasSessionRoute()

    let root = element(in: app, identifier: Accessibility.policyCanvasRoot)
    XCTAssertTrue(root.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(element(in: app, identifier: Accessibility.policyCanvasTopBar).exists)
    XCTAssertTrue(element(in: app, identifier: Accessibility.policyCanvasToolRail).exists)
    XCTAssertTrue(element(in: app, identifier: Accessibility.policyCanvasZoomControls).exists)
    XCTAssertTrue(element(in: app, identifier: Accessibility.policyCanvasInspector).exists)
  }

  func testPolicyCanvasScenarioRendersCoreGroups() throws {
    let app = openPolicyCanvasSessionRoute()

    let root = element(in: app, identifier: Accessibility.policyCanvasRoot)
    let entry = element(in: app, identifier: Accessibility.policyCanvasGroup("entry"))
    let merge = element(in: app, identifier: Accessibility.policyCanvasGroup("merge"))
    let terminal = element(in: app, identifier: Accessibility.policyCanvasGroup("terminal"))

    XCTAssertTrue(root.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(entry.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(merge.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(terminal.waitForExistence(timeout: Self.actionTimeout))
  }

  func testPolicyCanvasNodeDragMovesPreviewNode() throws {
    let app = openPolicyCanvasSessionRoute()

    let node = element(in: app, identifier: Accessibility.policyCanvasNode("risk:merge"))
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
      additionalEnvironment: [
        Self.previewScenarioKey: Self.previewPolicyCanvasScenario,
        Self.initialRouteKey: Self.policyCanvasRoute,
      ]
    )

    XCTAssertTrue(
      waitForElement(
        element(in: app, identifier: Accessibility.sessionWindowShell),
        timeout: Self.uiTimeout
      )
    )
    XCTAssertTrue(
      waitForElement(
        element(in: app, identifier: Accessibility.policyCanvasRoot),
        timeout: Self.actionTimeout
      )
    )
    return app
  }
}
