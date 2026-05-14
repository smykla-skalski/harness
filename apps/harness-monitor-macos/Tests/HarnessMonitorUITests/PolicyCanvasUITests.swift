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

  func testPolicyCanvasOpensFromSessionRoute() throws {
    let app = openPolicyCanvasSessionRoute()

    let topBar = element(in: app, identifier: Accessibility.policyCanvasTopBar)
    let toolRail = element(in: app, identifier: Accessibility.policyCanvasToolRail)
    XCTAssertTrue(
      waitUntil(in: app, timeout: Self.fastActionTimeout) {
        topBar.exists && toolRail.exists
      },
      "Policy Canvas chrome did not become ready quickly"
    )
  }

  func testPolicyCanvasInitialLayoutDoesNotOverlapChromeOrSections() throws {
    let app = openPolicyCanvasSessionRoute()

    let root = element(in: app, identifier: Accessibility.policyCanvasRoot)
    let topBar = element(in: app, identifier: Accessibility.policyCanvasTopBar)
    let toolRail = element(in: app, identifier: Accessibility.policyCanvasToolRail)
    let entry = element(in: app, identifier: Accessibility.policyCanvasGroup("entry"))
    let merge = element(in: app, identifier: Accessibility.policyCanvasGroup("merge"))
    let terminal = element(in: app, identifier: Accessibility.policyCanvasGroup("terminal"))
    let actionNode = element(in: app, identifier: Accessibility.policyCanvasNode("action:router"))
    let evidenceNode = element(
      in: app, identifier: Accessibility.policyCanvasNode("evidence:merge"))
    let riskNode = element(in: app, identifier: Accessibility.policyCanvasNode("risk:merge"))

    let requiredElements = [
      root,
      topBar,
      toolRail,
      entry,
      merge,
      terminal,
      actionNode,
      evidenceNode,
      riskNode,
    ]
    XCTAssertTrue(
      waitUntil(in: app, timeout: Self.fastActionTimeout) {
        requiredElements.allSatisfy(\.exists)
      },
      "Policy Canvas layout elements did not become ready quickly"
    )

    let canvasFrame = CGRect(
      x: toolRail.frame.maxX,
      y: topBar.frame.maxY,
      width: root.frame.maxX - Self.inspectorWidth - toolRail.frame.maxX,
      height: root.frame.maxY - topBar.frame.maxY
    )
    let nodeFrameSummary =
      "canvas=\(canvasFrame) action=\(actionNode.frame) evidence=\(evidenceNode.frame) risk=\(riskNode.frame)"
    let visibleCoreNodes = [evidenceNode, riskNode]

    for node in visibleCoreNodes {
      XCTAssertFalse(node.frame.intersects(topBar.frame), "Policy node overlaps top bar")
      XCTAssertFalse(node.frame.intersects(toolRail.frame), "Policy node overlaps tool rail")
      XCTAssertTrue(
        canvasFrame.insetBy(dx: -1, dy: -1).contains(node.frame.origin),
        "Policy node should start inside the visible canvas viewport. \(nodeFrameSummary)"
      )
    }

    XCTAssertFalse(
      canvasFrame.contains(actionNode.frame.origin),
      "Initial viewport should be centered on the policy graph, "
        + "not pinned to the first group. \(nodeFrameSummary)"
    )

    XCTAssertFalse(
      actionNode.frame.intersects(evidenceNode.frame),
      "Action and evidence nodes overlap. \(nodeFrameSummary)"
    )
    XCTAssertFalse(
      evidenceNode.frame.intersects(riskNode.frame),
      "Evidence and risk nodes overlap. \(nodeFrameSummary)"
    )
    XCTAssertFalse(
      actionNode.frame.intersects(riskNode.frame),
      "Action and risk nodes overlap. \(nodeFrameSummary)"
    )
  }

  func testPolicyCanvasNodeDragMovesPreviewNode() throws {
    let app = openPolicyCanvasSessionRoute()

    let node = element(in: app, identifier: Accessibility.policyCanvasNode("risk:merge"))
    XCTAssertTrue(node.exists || node.waitForExistence(timeout: Self.fastActionTimeout))

    let originalFrame = node.frame
    let start = node.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let end = node.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85))
    start.press(forDuration: 0.1, thenDragTo: end)

    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        node.frame.origin != originalFrame.origin
      },
      "Dragging a policy node should update its canvas position"
    )
  }

  func testPolicyCanvasZoomControlsAndShortcutsUpdateScale() throws {
    let app = openPolicyCanvasSessionRoute()
    let zoomValue = element(in: app, identifier: Accessibility.policyCanvasZoomValue)
    XCTAssertTrue(zoomValue.exists || zoomValue.waitForExistence(timeout: Self.fastActionTimeout))
    let originalValue = zoomValue.label

    tapButton(in: app, identifier: Accessibility.policyCanvasZoomInButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
        zoomValue.label != originalValue
      },
      "Zoom-in control should update the visible zoom value"
    )

    app.typeKey("0", modifierFlags: [.command])
    XCTAssertTrue(
      waitUntil(timeout: Self.fastActionTimeout) {
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
        timeout: Self.fastActionTimeout
      )
    )
    XCTAssertTrue(
      waitForElement(
        element(in: app, identifier: Accessibility.policyCanvasRoot),
        timeout: Self.fastActionTimeout
      )
    )
    return app
  }
}
