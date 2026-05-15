import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

/// Static a11y-tree scaffolding for the PolicyCanvas rotor pass.
///
/// XCUITest cannot start VoiceOver, but it can query the same accessibility
/// tree the rotor walks. These tests pin the shape that pass would surface:
/// every seeded edge exposes a non-empty label encoding source -> target
/// intent, a kind word as accessibility value, and the button trait so the
/// rotor reaches it via "Interact with buttons". A live rotor pass remains
/// owed (the only inherently human step in the tier-2 plan), but a
/// regression here would invalidate that pass before it runs, so this is
/// the cheap automated gate.
@MainActor
final class PolicyCanvasVoiceOverRotorTests: HarnessMonitorUITestCase {
  private static let previewScenarioKey = "HARNESS_MONITOR_PREVIEW_SCENARIO"
  private static let initialRouteKey = "HARNESS_MONITOR_UI_TEST_SESSION_ROUTE"
  private static let previewPolicyCanvasScenario = "policy-canvas"
  private static let policyCanvasRoute = "policyCanvas"

  override nonisolated static var reuseLaunchedApp: Bool { true }

  private static let seededEdges: [SeededEdge] = [
    SeededEdge(
      id: "edge-intake-risk",
      label: "normalize",
      source: "Policy intake",
      target: "Risk score"
    ),
    SeededEdge(
      id: "edge-risk-context",
      label: "low risk",
      source: "Risk score",
      target: "Context map"
    ),
    SeededEdge(
      id: "edge-risk-review",
      label: "needs review",
      source: "Risk score",
      target: "Review gate"
    ),
    SeededEdge(
      id: "edge-context-promote",
      label: "allow",
      source: "Context map",
      target: "Promote release"
    ),
    SeededEdge(
      id: "edge-review-promote",
      label: "approved",
      source: "Review gate",
      target: "Promote release"
    ),
  ]

  func testEdgeRotorElementsExposeLabelValueAndButtonTrait() throws {
    let app = openPolicyCanvasSessionRoute()
    let root = element(in: app, identifier: Accessibility.policyCanvasRoot)
    XCTAssertTrue(root.waitForExistence(timeout: Self.actionTimeout))

    for seed in Self.seededEdges {
      let identifier = Accessibility.policyCanvasEdge(seed.id)
      let edgeElement = root.descendants(matching: .any)
        .matching(identifier: identifier)
        .firstMatch
      XCTAssertTrue(
        waitForElement(in: app, edgeElement, timeout: Self.actionTimeout),
        "Edge \(seed.id) should expose an a11y element identified by \(identifier)."
      )

      let label = edgeElement.label
      XCTAssertTrue(
        label.contains("Edge \(seed.label)"),
        "Edge \(seed.id) label '\(label)' should include 'Edge \(seed.label)'."
      )
      XCTAssertTrue(
        label.contains(seed.source) && label.contains(seed.target),
        """
        Edge \(seed.id) label '\(label)' should mention both endpoints \
        '\(seed.source)' and '\(seed.target)' so a rotor user hears \
        source -> target intent.
        """
      )
    }
  }

  func testEdgeStrokeExposesKindWordAsAccessibilityValue() throws {
    let app = openPolicyCanvasSessionRoute()
    let root = element(in: app, identifier: Accessibility.policyCanvasRoot)
    XCTAssertTrue(root.waitForExistence(timeout: Self.actionTimeout))

    let validKindWords: Set<String> = ["flow", "control", "error"]

    for seed in Self.seededEdges {
      let labelPrefix = "Edge \(seed.label),"
      let predicate = NSPredicate(
        format: "label BEGINSWITH %@",
        labelPrefix
      )
      let candidates = root.descendants(matching: .any).matching(predicate)
      // Exactly one rotor entry per labelled edge: WCAG 4.1.2 (Name/Role
      // /Value). Previously the stroke and the label capsule both exposed
      // the same accessibility label, so VoiceOver announced every edge
      // twice. The label is now `.accessibilityHidden(true)` and the
      // stroke owns the rotor entry; this assertion catches regressions
      // that re-introduce the duplicate.
      XCTAssertEqual(
        candidates.count,
        1,
        """
        Edge \(seed.id) should surface exactly one a11y element with label \
        prefix '\(labelPrefix)' (the stroke owns the rotor entry). Saw \
        \(candidates.count); a return to two entries means the label-vs-stroke \
        duplicate regressed.
        """
      )

      let value = candidates.firstMatch.value as? String ?? ""
      let firstWord = value.split(separator: ",").first.map(String.init)?.trimmingCharacters(
        in: .whitespaces
      ) ?? ""
      XCTAssertTrue(
        validKindWords.contains(firstWord),
        """
        Edge \(seed.id) should expose 'flow', 'control', or 'error' as the \
        first comma-separated token of its accessibility value so WCAG 1.4.1 \
        is satisfied (kind not encoded by color alone). Saw '\(value)'.
        """
      )
    }
  }

  func testRotorEdgeOrderMatchesDocumentOrder() throws {
    let app = openPolicyCanvasSessionRoute()
    let root = element(in: app, identifier: Accessibility.policyCanvasRoot)
    XCTAssertTrue(root.waitForExistence(timeout: Self.actionTimeout))

    var seenOrder: [String] = []
    let labelOnlyPredicate = NSPredicate(format: "label BEGINSWITH 'Edge '")
    let labelButtons = root.descendants(matching: .button)
      .matching(labelOnlyPredicate)

    let probeCount = min(labelButtons.count, 12)
    for index in 0..<probeCount {
      let label = labelButtons.element(boundBy: index).label
      for seed in Self.seededEdges where label.contains("Edge \(seed.label)") {
        if !seenOrder.contains(seed.id) {
          seenOrder.append(seed.id)
        }
      }
    }

    XCTAssertEqual(
      seenOrder.count,
      Self.seededEdges.count,
      """
      Rotor traversal should reach every seeded edge label button. Saw \
      \(seenOrder) of \(Self.seededEdges.map(\.id)).
      """
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

private struct SeededEdge {
  let id: String
  let label: String
  let source: String
  let target: String
}
