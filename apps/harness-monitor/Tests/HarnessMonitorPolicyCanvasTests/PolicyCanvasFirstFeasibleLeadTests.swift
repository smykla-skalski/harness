import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas first-feasible port leads")
struct PolicyCanvasFirstFeasibleLeadTests {
  @Test("unpinned back-edges use flex-anchor routing")
  func unpinnedBackEdgesUseFlexAnchorRouting() {
    let source = policyCanvasMarkerTestNode(
      id: "src",
      position: CGPoint(x: 600, y: 0),
      inputPorts: [],
      outputPorts: [PolicyCanvasPort(id: "out", title: "out", kind: .output)]
    )
    let target = policyCanvasMarkerTestNode(
      id: "tgt",
      position: CGPoint(x: 0, y: 0),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    let edge = PolicyCanvasEdge(
      id: "flex",
      source: PolicyCanvasPortEndpoint(nodeID: "src", portID: "out", kind: .output),
      target: PolicyCanvasPortEndpoint(nodeID: "tgt", portID: "in", kind: .input),
      label: "route",
      pinnedPortSide: false
    )
    let prepared = PolicyCanvasPreparedRouteInput(
      input: PolicyCanvasRouteWorkerInput(
        nodes: [source, target], groups: [], edges: [edge], fontScale: 1
      )
    )

    let routes = PolicyCanvasFirstFeasibleRouteSelection().selectRoutes(
      input: PolicyCanvasRouteSelectionInput(
        prepared: prepared,
        router: PolicyCanvasFlexProofRouter(),
        portMarkerLayout: nil,
        passContext: nil
      )
    )

    let points = routes[edge.id]?.points ?? []
    #expect(points.contains(PolicyCanvasFlexProofRouter.flexRoute.points[0]))
    #expect(points.contains(PolicyCanvasFlexProofRouter.flexRoute.points[1]))
    #expect(!points.contains(PolicyCanvasFlexProofRouter.pinnedRoute.points[0]))
    #expect(!points.contains(PolicyCanvasFlexProofRouter.pinnedRoute.points[1]))
  }

  @Test("a back-edge leaves and enters perpendicular to its ports")
  func backEdgeLeavesPerpendicular() {
    // The source node sits to the RIGHT of the target, so the edge runs
    // backward. Without perpendicular leads the route bolts left straight out of
    // the trailing port and reads as a leading-side departure - which is not a
    // routable side for an output.
    let source = policyCanvasMarkerTestNode(
      id: "src",
      position: CGPoint(x: 600, y: 0),
      inputPorts: [],
      outputPorts: [PolicyCanvasPort(id: "out", title: "out", kind: .output)]
    )
    let target = policyCanvasMarkerTestNode(
      id: "tgt",
      position: CGPoint(x: 0, y: 0),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    let edge = PolicyCanvasEdge(
      id: "back",
      source: PolicyCanvasPortEndpoint(nodeID: "src", portID: "out", kind: .output),
      target: PolicyCanvasPortEndpoint(nodeID: "tgt", portID: "in", kind: .input),
      label: "route",
      pinnedPortSide: true
    )
    let input = PolicyCanvasRouteWorkerInput(
      nodes: [source, target], groups: [], edges: [edge], fontScale: 1
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let routes = PolicyCanvasFirstFeasibleRouteSelection().selectRoutes(
      input: PolicyCanvasRouteSelectionInput(
        prepared: prepared,
        router: PolicyCanvasOrthogonalVisibilityGraphAStarRouter(),
        portMarkerLayout: nil,
        passContext: nil
      )
    )
    guard let route = routes[edge.id] else {
      Issue.record("first-feasible produced no route for the back edge")
      return
    }
    // The output leaves its trailing port square to the right, the input is met
    // square on its leading port - both routable sides for their kind.
    #expect(policyCanvasRouteSourceSide(route) == .trailing)
    #expect(policyCanvasRouteTargetSide(route) == .leading)
  }

  @Test("inbound edges sharing an input port land on separate target terminals")
  func inboundEdgesSharingInputPortLandOnSeparateTargetTerminals() {
    let sources = (0..<3).map { index in
      policyCanvasMarkerTestNode(
        id: "src-\(index)",
        position: CGPoint(x: 0, y: CGFloat(index * 120)),
        inputPorts: [],
        outputPorts: [PolicyCanvasPort(id: "out", title: "out", kind: .output)]
      )
    }
    let target = policyCanvasMarkerTestNode(
      id: "tgt",
      position: CGPoint(x: 460, y: 120),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    let edges = sources.enumerated().map { index, source in
      PolicyCanvasEdge(
        id: "edge-\(index)",
        source: PolicyCanvasPortEndpoint(nodeID: source.id, portID: "out", kind: .output),
        target: PolicyCanvasPortEndpoint(nodeID: target.id, portID: "in", kind: .input),
        label: "route-\(index)",
        pinnedPortSide: false
      )
    }
    let input = PolicyCanvasRouteWorkerInput(
      nodes: sources + [target],
      groups: [],
      edges: edges,
      fontScale: 1
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let nodeIndex = prepared.nodeIndex
    let routes = PolicyCanvasFirstFeasibleRouteSelection().selectRoutes(
      input: PolicyCanvasRouteSelectionInput(
        prepared: prepared,
        router: PolicyCanvasOrthogonalVisibilityGraphAStarRouter(),
        portMarkerLayout: nil,
        passContext: prepared.displayedRoutePassContext(nodeIndex: nodeIndex)
      )
    )
    let targetYs = edges.compactMap { routes[$0.id]?.points.last?.y }.sorted()
    let markerLayout = PolicyCanvasRouteTerminalPortMarkerPlacement().placeMarkers(
      input: PolicyCanvasPortMarkerPlacementInput(
        prepared: prepared,
        routes: routes,
        nodeIndex: nodeIndex
      )
    )
    let targetMarkers = markerLayout.markers(
      for: edges[0].target,
      side: .leading,
      isVisible: true
    )

    #expect(targetYs.count == edges.count)
    #expect(Set(targetYs.map { Int(($0 * 1_000).rounded()) }).count == edges.count)
    #expect(targetMarkers.count == edges.count)
    for pair in zip(targetYs, targetYs.dropFirst()) {
      #expect(pair.1 - pair.0 >= PolicyCanvasLayout.defaultEdgeLineSpacing - 0.001)
    }
    for edge in edges {
      #expect(routes[edge.id].map(policyCanvasRouteTargetSide) == .leading)
    }
  }
}

private struct PolicyCanvasFlexProofRouter: PolicyCanvasEdgeRouter {
  static let pinnedRoute = PolicyCanvasEdgeRoute(
    points: [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 1)],
    labelPosition: CGPoint(x: 1.5, y: 1)
  )
  static let flexRoute = PolicyCanvasEdgeRoute(
    points: [CGPoint(x: 3, y: 3), CGPoint(x: 4, y: 3)],
    labelPosition: CGPoint(x: 3.5, y: 3)
  )

  func route(
    source _: CGPoint,
    target _: CGPoint,
    context _: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    Self.pinnedRoute
  }

  func route(
    sourceCandidates _: [CGPoint],
    targetCandidates _: [CGPoint],
    context _: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    Self.flexRoute
  }
}
