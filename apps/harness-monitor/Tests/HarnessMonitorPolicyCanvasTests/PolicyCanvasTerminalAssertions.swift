import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

struct PolicyCanvasTerminalScenario {
  let viewModel: PolicyCanvasViewModel
  let edges: [PolicyCanvasEdge]
  let routes: [String: PolicyCanvasEdgeRoute]
}

struct PolicyCanvasTerminalAssertion {
  let role: PolicyCanvasRouteEndpointRole
  let endpoint: KeyPath<PolicyCanvasEdge, PolicyCanvasPortEndpoint>
  let routePoint: (PolicyCanvasEdgeRoute) -> CGPoint?
  let routeSide: (PolicyCanvasEdgeRoute) -> PolicyCanvasPortSide?
  let label: String
}

/// Marker-dots contract shared by the live routing-quality suite: every route
/// terminal must land on a visible marker dot belonging to its endpoint + side
/// (or, in the fan-collapse case, on a neighbouring port's dot within a radius),
/// so no line end floats free of the rendered dot grid.
@MainActor
struct PolicyCanvasTerminalAssertions {
  func assertMarkerOffsets(
    scenario: PolicyCanvasTerminalScenario,
    markerLayout: PolicyCanvasPortMarkerLayout,
    assertion: PolicyCanvasTerminalAssertion
  ) {
    for edge in scenario.edges {
      guard
        let route = scenario.routes[edge.id],
        let point = assertion.routePoint(route),
        let side = assertion.routeSide(route),
        let base = scenario.viewModel.portAnchorCandidates(for: edge[keyPath: assertion.endpoint])
          .first(where: { $0.side == side })?.point
      else {
        continue
      }
      let offset = axisOffset(from: base, to: point, side: side)
      let endpoint = edge[keyPath: assertion.endpoint]
      let markers = markerLayout.markers(for: endpoint, side: side, isVisible: true)
      if markers.contains(where: { abs($0.axisOffset - offset) < 0.5 }) {
        continue
      }
      // Fan-collapse case: when a single-edge port's route escapes onto a
      // sibling port's lane (e.g. action:router's "unsafe" line leaves on the
      // same dot as "mutate"), the terminal still lands on a drawn dot - just
      // one owned by a neighbouring port. Accept the route as long as its
      // terminal sits within a dot radius of some visible marker on the same
      // node + side, so no line end floats free of the dot grid.
      let axis = (side == .leading || side == .trailing) ? point.y : point.x
      let dotPositions = markerAxisPositionsOnNodeSide(
        scenario: scenario,
        markerLayout: markerLayout,
        endpoint: endpoint,
        side: side
      )
      #expect(
        dotPositions.contains { abs($0 - axis) <= PolicyCanvasLayout.portDiameter / 2 },
        """
        \(assertion.label) terminal \(edge.id) at \(axis) lands on no visible \
        dot on side \(side); dots \(dotPositions)
        """
      )
    }
  }

  func markerAxisPositionsOnNodeSide(
    scenario: PolicyCanvasTerminalScenario,
    markerLayout: PolicyCanvasPortMarkerLayout,
    endpoint: PolicyCanvasPortEndpoint,
    side: PolicyCanvasPortSide
  ) -> [CGFloat] {
    guard let node = scenario.viewModel.node(endpoint.nodeID) else {
      return []
    }
    let ports = endpoint.kind == .output ? node.outputPorts : node.inputPorts
    return ports.flatMap { port -> [CGFloat] in
      let portEndpoint = PolicyCanvasPortEndpoint(
        nodeID: endpoint.nodeID,
        portID: port.id,
        kind: endpoint.kind
      )
      guard
        let base = scenario.viewModel.portAnchorCandidates(for: portEndpoint)
          .first(where: { $0.side == side })?.point
      else {
        return []
      }
      let baseAxis = (side == .leading || side == .trailing) ? base.y : base.x
      return markerLayout.markers(for: portEndpoint, side: side, isVisible: true)
        .map { baseAxis + $0.axisOffset }
    }
  }

  func axisOffset(
    from base: CGPoint,
    to point: CGPoint,
    side: PolicyCanvasPortSide
  ) -> CGFloat {
    switch side {
    case .leading, .trailing:
      point.y - base.y
    case .top, .bottom:
      point.x - base.x
    }
  }
}
