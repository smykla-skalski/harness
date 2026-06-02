import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("PolicyCanvasMarqueeSelection")
@MainActor
struct PolicyCanvasMarqueeSelectionTests {
  @Test("normalizes marquee rect on reverse drag")
  func normalizedMarqueeRect() {
    // Drag from (320, 220) to (120, 80) - reversed on both axes
    let state = PolicyCanvasMarqueeSelectionState(
      anchor: CGPoint(x: 320, y: 220),
      current: CGPoint(x: 120, y: 80),
      mode: .replace
    )

    let rect = state.rect

    #expect(rect.origin.x == 120)
    #expect(rect.origin.y == 80)
    #expect(rect.width == 200)
    #expect(rect.height == 140)
  }

  @Test("captures intersected nodes, groups, and edges")
  func hitResolverCapturesIntersections() {
    let fixtures = makeMarqueeTestFixtures()

    // Marquee that intersects policy-source, risk-score, group-intake, and edge-intake-risk
    let marqueeRect = CGRect(x: 90, y: 90, width: 200, height: 150)

    let captured = PolicyCanvasMarqueeSelectionHitResolver.capturedSelections(
      marqueeRect: marqueeRect,
      nodes: fixtures.nodes,
      groups: fixtures.groups,
      edges: fixtures.edges,
      routes: fixtures.routes
    )

    #expect(captured.contains(PolicyCanvasSelection.node("policy-source")))
    #expect(captured.contains(PolicyCanvasSelection.node("risk-score")))
    #expect(captured.contains(PolicyCanvasSelection.group("group-intake")))
    #expect(captured.contains(PolicyCanvasSelection.edge("edge-intake-risk")))
    #expect(!captured.contains(PolicyCanvasSelection.node("outside-node")))
    #expect(!captured.contains(PolicyCanvasSelection.group("group-outside")))
    #expect(!captured.contains(PolicyCanvasSelection.edge("edge-outside")))
  }

  @Test("clearTransientGestureState clears marquee state")
  func clearTransientGestureStateClearsMarquee() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.marqueeSelection = PolicyCanvasMarqueeSelectionState(
      anchor: CGPoint(x: 80, y: 80),
      current: CGPoint(x: 180, y: 180),
      mode: .replace
    )

    viewModel.clearTransientGestureState()

    #expect(viewModel.marqueeSelection == nil)
  }
}

// MARK: - Test Fixtures

private struct MarqueeTestFixtures {
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let routes: [String: PolicyCanvasEdgeRoute]
}

private func makeMarqueeTestFixtures() -> MarqueeTestFixtures {
  let nodes = [
    PolicyCanvasNode(
      id: "policy-source",
      title: "Policy Source",
      kind: .trigger,
      position: CGPoint(x: 100, y: 100)
    ),
    PolicyCanvasNode(
      id: "risk-score",
      title: "Risk Score",
      kind: .riskClassifier,
      position: CGPoint(x: 140, y: 120)
    ),
    PolicyCanvasNode(
      id: "outside-node",
      title: "Outside",
      kind: .finish,
      position: CGPoint(x: 500, y: 500)
    ),
  ]

  let groups = [
    PolicyCanvasGroup(
      id: "group-intake",
      title: "Intake",
      frame: CGRect(x: 80, y: 80, width: 200, height: 180),
      tone: .intake
    ),
    PolicyCanvasGroup(
      id: "group-outside",
      title: "Outside",
      frame: CGRect(x: 400, y: 400, width: 200, height: 180),
      tone: .evaluation
    ),
  ]

  let edges = [
    PolicyCanvasEdge(
      id: "edge-intake-risk",
      source: PolicyCanvasPortEndpoint(
        nodeID: "policy-source",
        portID: "output-out",
        kind: .output,
        side: nil
      ),
      target: PolicyCanvasPortEndpoint(
        nodeID: "risk-score",
        portID: "input-in",
        kind: .input,
        side: nil
      ),
      label: "intake flow",
      condition: "always",
      pinnedPortSide: true
    ),
    PolicyCanvasEdge(
      id: "edge-outside",
      source: PolicyCanvasPortEndpoint(
        nodeID: "outside-node",
        portID: "input-in",
        kind: .input,
        side: nil
      ),
      target: PolicyCanvasPortEndpoint(
        nodeID: "policy-source",
        portID: "output-out",
        kind: .output,
        side: nil
      ),
      label: "outside",
      condition: "always",
      pinnedPortSide: true
    ),
  ]

  let routes: [String: PolicyCanvasEdgeRoute] = [
    "edge-intake-risk": PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 150, y: 110),
        CGPoint(x: 180, y: 110),
        CGPoint(x: 180, y: 130),
      ],
      labelPosition: CGPoint(x: 165, y: 120)
    ),
    "edge-outside": PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 520, y: 520),
        CGPoint(x: 600, y: 600),
      ],
      labelPosition: CGPoint(x: 560, y: 560)
    ),
  ]

  return MarqueeTestFixtures(nodes: nodes, groups: groups, edges: edges, routes: routes)
}
