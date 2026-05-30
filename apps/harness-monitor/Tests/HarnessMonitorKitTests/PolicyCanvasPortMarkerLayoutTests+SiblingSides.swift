import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

extension PolicyCanvasPortMarkerLayoutTests {
  @Test("single side marker stays centered when sibling outputs use the alternate side")
  func singleSideMarkerStaysCenteredWhenSiblingOutputsUseTheAlternateSide() {
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
    let routes = siblingSideRoutes(source: source)

    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let layout = prepared.portMarkerLayout(routes: routes, nodeIndex: prepared.nodeIndex)
    let trailingEndpoint = PolicyCanvasPortEndpoint(
      nodeID: source.id,
      portID: "consensus",
      kind: .output
    )
    let trailingMarkers = layout.markers(for: trailingEndpoint, side: .trailing, isVisible: true)

    #expect(trailingMarkers.count == 1)
    let renderedY =
      PolicyCanvasLayout.portY(index: 2, count: source.outputPorts.count)
      + trailingMarkers[0].axisOffset
    #expect(abs(renderedY - (PolicyCanvasLayout.nodeSize.height / 2)) < 0.001)
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

  private func siblingSideRoutes(source: PolicyCanvasNode) -> [String: PolicyCanvasEdgeRoute] {
    let trailingSource = CGPoint(
      x: source.position.x + PolicyCanvasLayout.nodeSize.width,
      y: source.position.y + PolicyCanvasLayout.portY(index: 2, count: source.outputPorts.count)
    )
    let bottomPassSource = CGPoint(
      x: source.position.x + PolicyCanvasLayout.portX(index: 0, count: source.outputPorts.count),
      y: source.position.y + PolicyCanvasLayout.nodeSize.height
    )
    let bottomFailSource = CGPoint(
      x: source.position.x + PolicyCanvasLayout.portX(index: 1, count: source.outputPorts.count),
      y: source.position.y + PolicyCanvasLayout.nodeSize.height
    )
    let bottomMissingSource = CGPoint(
      x: source.position.x + PolicyCanvasLayout.portX(index: 3, count: source.outputPorts.count),
      y: source.position.y + PolicyCanvasLayout.nodeSize.height
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
