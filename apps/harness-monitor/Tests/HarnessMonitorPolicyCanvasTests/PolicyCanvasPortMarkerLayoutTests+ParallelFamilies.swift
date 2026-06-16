import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasPortMarkerLayoutTests {
  @Test("parallel families use a separate horizontal marker per edge")
  func parallelFamiliesUseSeparateHorizontalMarkersPerEdge() {
    let source = policyCanvasMarkerTestNode(
      id: "source",
      position: .zero,
      inputPorts: [],
      outputPorts: [
        PolicyCanvasPort(id: "pass", title: "pass", kind: .output),
        PolicyCanvasPort(id: "fail", title: "fail", kind: .output),
      ]
    )
    let passTarget = policyCanvasMarkerTestNode(
      id: "pass-target",
      position: CGPoint(x: 0, y: 220),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    let failTarget = policyCanvasMarkerTestNode(
      id: "fail-target",
      position: CGPoint(x: 260, y: 220),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    let edges = parallelFamilyEdges(source: source, passTarget: passTarget, failTarget: failTarget)
    let input = PolicyCanvasRouteWorkerInput(
      nodes: [source, passTarget, failTarget],
      groups: [],
      edges: edges,
      fontScale: 1
    )
    let routes = parallelFamilyRoutes(source: source)

    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let layout = prepared.portMarkerLayout(routes: routes, nodeIndex: prepared.nodeIndex)
    let trailingPassMarkers = layout.markers(
      for: PolicyCanvasPortEndpoint(nodeID: source.id, portID: "pass", kind: .output),
      side: .trailing,
      isVisible: true
    )
    let leadingPassMarkers = layout.markers(
      for: PolicyCanvasPortEndpoint(nodeID: source.id, portID: "pass", kind: .output),
      side: .leading,
      isVisible: true
    )
    let trailingFailMarkers = layout.markers(
      for: PolicyCanvasPortEndpoint(nodeID: source.id, portID: "fail", kind: .output),
      side: .trailing,
      isVisible: true
    )
    let leadingFailMarkers = layout.markers(
      for: PolicyCanvasPortEndpoint(nodeID: source.id, portID: "fail", kind: .output),
      side: .leading,
      isVisible: true
    )

    #expect(trailingPassMarkers.count + leadingPassMarkers.count == 1)
    // Parallel fail edges are distinctly labelled transitions; each gets its own
    // horizontal dot rather than collapsing onto a single shared marker.
    #expect(trailingFailMarkers.count + leadingFailMarkers.count == 4)
    let failTerminals = ["edge-fail-a", "edge-fail-b", "edge-fail-c", "edge-fail-d"]
      .compactMap { layout.terminal(edgeID: $0, role: .source) }
    #expect(failTerminals.count == 4)
    #expect(Set(failTerminals.map(\.side)).isSubset(of: [.leading, .trailing]))
    let failCoordinates = Set(
      failTerminals.map { terminal in
        let rendered = sourceCoordinate(
          PolicyCanvasPortEndpoint(nodeID: source.id, portID: "fail", kind: .output),
          side: terminal.side
        ) + terminal.axisOffset
        return "\(terminal.side.rawValue):\(Int((rendered * 1_000).rounded()))"
      }
    )
    #expect(failCoordinates.count == 4)
  }

  private func parallelFamilyEdges(
    source: PolicyCanvasNode,
    passTarget: PolicyCanvasNode,
    failTarget: PolicyCanvasNode
  ) -> [PolicyCanvasEdge] {
    let failEdges = ["a", "b", "c", "d"].map { suffix in
      PolicyCanvasEdge(
        id: "edge-fail-\(suffix)",
        source: PolicyCanvasPortEndpoint(nodeID: source.id, portID: "fail", kind: .output),
        target: PolicyCanvasPortEndpoint(nodeID: failTarget.id, portID: "in", kind: .input),
        label: "fail \(suffix)",
        pinnedPortSide: true,
        kind: .error
      )
    }
    return [
      PolicyCanvasEdge(
        id: "edge-pass",
        source: PolicyCanvasPortEndpoint(
          nodeID: source.id, portID: "pass", kind: .output, side: .bottom),
        target: PolicyCanvasPortEndpoint(
          nodeID: passTarget.id, portID: "in", kind: .input, side: .top),
        label: "pass",
        pinnedPortSide: true
      )
    ] + failEdges
  }

  private func parallelFamilyRoutes(source: PolicyCanvasNode) -> [String: PolicyCanvasEdgeRoute] {
    let passSource = CGPoint(
      x: source.position.x + PolicyCanvasLayout.portX(index: 0, count: 2),
      y: source.position.y + PolicyCanvasLayout.nodeSize.height
    )
    let failSource = CGPoint(
      x: source.position.x + PolicyCanvasLayout.portX(index: 1, count: 2),
      y: source.position.y + PolicyCanvasLayout.nodeSize.height
    )
    var routes: [String: PolicyCanvasEdgeRoute] = [
      "edge-pass": PolicyCanvasEdgeRoute(
        points: [passSource, CGPoint(x: passSource.x, y: passSource.y + 80)],
        labelPosition: CGPoint(x: passSource.x, y: passSource.y + 40)
      )
    ]
    let failLengths: [(String, CGFloat)] = [
      ("edge-fail-a", 80), ("edge-fail-b", 92), ("edge-fail-c", 104), ("edge-fail-d", 116),
    ]
    for (id, length) in failLengths {
      routes[id] = PolicyCanvasEdgeRoute(
        points: [failSource, CGPoint(x: failSource.x, y: failSource.y + length)],
        labelPosition: CGPoint(x: failSource.x, y: failSource.y + length / 2)
      )
    }
    return routes
  }
}
