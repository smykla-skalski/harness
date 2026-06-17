import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasPortMarkerLayoutTests {
  @Test("vertical route requests stay balanced on horizontal output sides")
  func verticalRouteRequestsStayBalancedOnHorizontalOutputSides() {
    let source = policyCanvasMarkerTestNode(
      id: "source",
      position: .zero,
      inputPorts: [],
      outputPorts: [
        PolicyCanvasPort(id: "pass", title: "pass", kind: .output),
        PolicyCanvasPort(id: "fail", title: "fail", kind: .output),
        PolicyCanvasPort(id: "consensus", title: "consensus", kind: .output),
        PolicyCanvasPort(id: "missing", title: "missing", kind: .output),
      ]
    )
    let trailingTarget = policyCanvasMarkerTestNode(
      id: "trailing-target",
      position: CGPoint(x: 240, y: 0),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    let bottomTargets = (0..<3).map { index in
      policyCanvasMarkerTestNode(
        id: "bottom-target-\(index)",
        position: CGPoint(x: CGFloat(index * 140), y: 240),
        inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
        outputPorts: []
      )
    }
    let edges = siblingSideEdges(
      source: source, trailingTarget: trailingTarget, bottomTargets: bottomTargets)
    let input = PolicyCanvasRouteWorkerInput(
      nodes: [source, trailingTarget] + bottomTargets,
      groups: [],
      edges: edges,
      fontScale: 1
    )

    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let sourceHeight = prepared.nodeIndex[source.id]?.size.height ?? PolicyCanvasLayout.nodeSize.height
    let routes = siblingSideRoutes(source: source, sourceHeight: sourceHeight)
    let layout = prepared.portMarkerLayout(routes: routes, nodeIndex: prepared.nodeIndex)
    var coordinatesBySide: [PolicyCanvasPortSide: [CGFloat]] = [:]
    for port in source.outputPorts {
      let endpoint = PolicyCanvasPortEndpoint(nodeID: source.id, portID: port.id, kind: .output)
      #expect(layout.markers(for: endpoint, side: .top, isVisible: true).isEmpty)
      #expect(layout.markers(for: endpoint, side: .bottom, isVisible: true).isEmpty)
      let portIndex = source.outputPorts.firstIndex(where: { $0.id == port.id }) ?? 0
      let base = PolicyCanvasLayout.portY(
        index: portIndex,
        count: source.outputPorts.count,
        nodeHeight: sourceHeight
      )
      for side in [PolicyCanvasPortSide.leading, .trailing] {
        for marker in layout.markers(for: endpoint, side: side, isVisible: true) {
          coordinatesBySide[side, default: []].append(base + marker.axisOffset)
        }
      }
    }

    #expect(coordinatesBySide.values.reduce(0) { $0 + $1.count } == edges.count)
    for coordinates in coordinatesBySide.values {
      assertEvenSpacing(coordinates.sorted(), extent: sourceHeight)
      assertCornerClearance(coordinates.sorted(), extent: sourceHeight)
    }
  }

  private func siblingSideEdges(
    source: PolicyCanvasNode,
    trailingTarget: PolicyCanvasNode,
    bottomTargets: [PolicyCanvasNode]
  ) -> [PolicyCanvasEdge] {
    [
      PolicyCanvasEdge(
        id: "edge-right",
        source: PolicyCanvasPortEndpoint(nodeID: source.id, portID: "consensus", kind: .output),
        target: PolicyCanvasPortEndpoint(nodeID: trailingTarget.id, portID: "in", kind: .input),
        label: "consensus",
        pinnedPortSide: false
      ),
      PolicyCanvasEdge(
        id: "edge-bottom-pass",
        source: PolicyCanvasPortEndpoint(nodeID: source.id, portID: "pass", kind: .output),
        target: PolicyCanvasPortEndpoint(nodeID: bottomTargets[0].id, portID: "in", kind: .input),
        label: "pass",
        pinnedPortSide: false
      ),
      PolicyCanvasEdge(
        id: "edge-bottom-fail",
        source: PolicyCanvasPortEndpoint(nodeID: source.id, portID: "fail", kind: .output),
        target: PolicyCanvasPortEndpoint(nodeID: bottomTargets[1].id, portID: "in", kind: .input),
        label: "fail",
        pinnedPortSide: false
      ),
      PolicyCanvasEdge(
        id: "edge-bottom-missing",
        source: PolicyCanvasPortEndpoint(nodeID: source.id, portID: "missing", kind: .output),
        target: PolicyCanvasPortEndpoint(nodeID: bottomTargets[2].id, portID: "in", kind: .input),
        label: "missing",
        pinnedPortSide: false
      ),
    ]
  }

  private func siblingSideRoutes(
    source: PolicyCanvasNode,
    sourceHeight: CGFloat
  ) -> [String: PolicyCanvasEdgeRoute] {
    let trailingSource = CGPoint(
      x: source.position.x + PolicyCanvasLayout.nodeSize.width,
      y: source.position.y
        + PolicyCanvasLayout.portY(
          index: 2,
          count: source.outputPorts.count,
          nodeHeight: sourceHeight
        )
    )
    let bottomPassSource = CGPoint(
      x: source.position.x + PolicyCanvasLayout.portX(index: 0, count: source.outputPorts.count),
      y: source.position.y + sourceHeight
    )
    let bottomFailSource = CGPoint(
      x: source.position.x + PolicyCanvasLayout.portX(index: 1, count: source.outputPorts.count),
      y: source.position.y + sourceHeight
    )
    let bottomMissingSource = CGPoint(
      x: source.position.x + PolicyCanvasLayout.portX(index: 3, count: source.outputPorts.count),
      y: source.position.y + sourceHeight
    )
    return [
      "edge-right": PolicyCanvasEdgeRoute(
        points: [trailingSource, CGPoint(x: trailingSource.x + 80, y: trailingSource.y)],
        labelPosition: CGPoint(x: trailingSource.x + 40, y: trailingSource.y)
      ),
      "edge-bottom-pass": PolicyCanvasEdgeRoute(
        points: [bottomPassSource, CGPoint(x: bottomPassSource.x, y: bottomPassSource.y + 80)],
        labelPosition: CGPoint(x: bottomPassSource.x, y: bottomPassSource.y + 40)
      ),
      "edge-bottom-fail": PolicyCanvasEdgeRoute(
        points: [bottomFailSource, CGPoint(x: bottomFailSource.x, y: bottomFailSource.y + 80)],
        labelPosition: CGPoint(x: bottomFailSource.x, y: bottomFailSource.y + 40)
      ),
      "edge-bottom-missing": PolicyCanvasEdgeRoute(
        points: [
          bottomMissingSource,
          CGPoint(x: bottomMissingSource.x, y: bottomMissingSource.y + 80),
        ],
        labelPosition: CGPoint(x: bottomMissingSource.x, y: bottomMissingSource.y + 40)
      ),
    ]
  }
}
