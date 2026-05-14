import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class PolicyCanvasUITests: HarnessMonitorUITestCase {
  private static let previewScenarioKey = "HARNESS_MONITOR_PREVIEW_SCENARIO"
  private static let initialRouteKey = "HARNESS_MONITOR_UI_TEST_SESSION_ROUTE"
  private static let previewPolicyCanvasScenario = "policy-canvas"
  private static let policyCanvasRoute = "policyCanvas"
  private static let inspectorWidth: CGFloat = 280
  override nonisolated static var reuseLaunchedApp: Bool { true }

  func testPolicyCanvasOpensFromSessionRouteWithPromoteGated() throws {
    let app = openPolicyCanvasSessionRoute()

    let root = element(in: app, identifier: Accessibility.policyCanvasRoot)
    XCTAssertTrue(root.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(element(in: app, identifier: Accessibility.policyCanvasToolRail).exists)
    XCTAssertFalse(button(in: app, identifier: Accessibility.policyCanvasPromoteButton).isEnabled)
  }

  func testPolicyCanvasInitialLayoutDoesNotOverlapChromeOrSections() throws {
    let app = openPolicyCanvasSessionRoute()

    let root = element(in: app, identifier: Accessibility.policyCanvasRoot)
    let topBar = element(in: app, identifier: Accessibility.policyCanvasTopBar)
    let toolRail = element(in: app, identifier: Accessibility.policyCanvasToolRail)
    let entry = element(in: app, identifier: Accessibility.policyCanvasGroup("entry"))
    let merge = element(in: app, identifier: Accessibility.policyCanvasGroup("merge"))
    let terminal = element(in: app, identifier: Accessibility.policyCanvasGroup("terminal"))

    XCTAssertTrue(root.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(topBar.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(toolRail.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(entry.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(merge.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(terminal.waitForExistence(timeout: Self.actionTimeout))

    let canvasFrame = CGRect(
      x: toolRail.frame.maxX,
      y: topBar.frame.maxY,
      width: root.frame.maxX - Self.inspectorWidth - toolRail.frame.maxX,
      height: root.frame.maxY - topBar.frame.maxY
    )

    for group in [entry, merge, terminal] {
      XCTAssertFalse(group.frame.intersects(topBar.frame), "Policy group overlaps top bar")
      XCTAssertFalse(group.frame.intersects(toolRail.frame), "Policy group overlaps tool rail")
      XCTAssertTrue(
        canvasFrame.insetBy(dx: -1, dy: -1).contains(group.frame.origin),
        "Policy group should start inside the visible canvas viewport"
      )
    }

    XCTAssertFalse(entry.frame.intersects(merge.frame), "Entry and merge groups overlap")
    XCTAssertFalse(merge.frame.intersects(terminal.frame), "Merge and terminal groups overlap")
    XCTAssertFalse(entry.frame.intersects(terminal.frame), "Entry and terminal groups overlap")
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

  func testPolicyCanvasZoomControlsAndShortcutsUpdateScale() throws {
    let app = openPolicyCanvasSessionRoute()
    let zoomValue = element(in: app, identifier: Accessibility.policyCanvasZoomValue)
    XCTAssertTrue(zoomValue.waitForExistence(timeout: Self.actionTimeout))
    let originalValue = zoomValue.label

    tapButton(in: app, identifier: Accessibility.policyCanvasZoomInButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        zoomValue.label != originalValue
      },
      "Zoom-in control should update the visible zoom value"
    )

    app.typeKey("0", modifierFlags: [.command])
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        zoomValue.label == "100%"
      },
      "Command-0 should reset the policy canvas zoom"
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
