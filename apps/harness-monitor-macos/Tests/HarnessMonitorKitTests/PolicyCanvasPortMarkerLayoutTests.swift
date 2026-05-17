import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas port marker layout")
struct PolicyCanvasPortMarkerLayoutTests {
  @Test("terminal markers stay on borders and overflow to alternate side")
  func terminalMarkersStayOnBordersAndOverflowToAlternateSide() {
    let target = policyCanvasMarkerTestNode(
      id: "target",
      position: CGPoint(x: 220, y: 80),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    let sources = (0..<4).map { index in
      policyCanvasMarkerTestNode(
        id: "source-\(index)",
        position: CGPoint(x: 0, y: CGFloat(index * 80)),
        inputPorts: [],
        outputPorts: [PolicyCanvasPort(id: "out", title: "out", kind: .output)]
      )
    }
    let edges = sources.map { source in
      PolicyCanvasEdge(
        id: "edge-\(source.id)",
        source: PolicyCanvasPortEndpoint(nodeID: source.id, portID: "out", kind: .output),
        target: PolicyCanvasPortEndpoint(nodeID: target.id, portID: "in", kind: .input),
        label: "route",
        pinnedPortSide: false
      )
    }
    let input = PolicyCanvasRouteWorkerInput(
      nodes: sources + [target],
      groups: [],
      edges: edges,
      fontScale: 1
    )
    let targetPoint = CGPoint(x: target.position.x, y: target.position.y + PolicyCanvasLayout.nodeSize.height / 2)
    let routes = Dictionary(uniqueKeysWithValues: edges.map { edge in
      (
        edge.id,
        PolicyCanvasEdgeRoute(
          points: [CGPoint(x: targetPoint.x - 160, y: targetPoint.y), targetPoint],
          labelPosition: targetPoint
        )
      )
    })

    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let layout = prepared.portMarkerLayout(routes: routes, nodeIndex: prepared.nodeIndex)
    let endpoint = edges[0].target
    let leadingMarkers = layout.markers(for: endpoint, side: .leading, isVisible: true)
    let topMarkers = layout.markers(for: endpoint, side: .top, isVisible: true)

    #expect(leadingMarkers.count == 3)
    #expect(topMarkers.count == 1)
    assertBorderCoordinates(
      markers: leadingMarkers,
      base: PolicyCanvasLayout.nodeSize.height / 2,
      extent: PolicyCanvasLayout.nodeSize.height
    )
    assertBorderCoordinates(
      markers: topMarkers,
      base: PolicyCanvasLayout.nodeSize.width / 2,
      extent: PolicyCanvasLayout.nodeSize.width
    )
    let leadingCoordinates = leadingMarkers.map {
      PolicyCanvasLayout.nodeSize.height / 2 + $0.axisOffset
    }.sorted()
    #expect(abs((leadingCoordinates[1] - leadingCoordinates[0])
      - (leadingCoordinates[2] - leadingCoordinates[1])) < 0.001)
  }

  private func assertBorderCoordinates(
    markers: [PolicyCanvasPortMarker],
    base: CGFloat,
    extent: CGFloat
  ) {
    let inset = PolicyCanvasLayout.portDiameter / 2 + 4
    for marker in markers {
      let coordinate = base + marker.axisOffset
      #expect(coordinate >= inset - 0.001)
      #expect(coordinate <= extent - inset + 0.001)
    }
  }
}

private func policyCanvasMarkerTestNode(
  id: String,
  position: CGPoint,
  inputPorts: [PolicyCanvasPort],
  outputPorts: [PolicyCanvasPort]
) -> PolicyCanvasNode {
  var node = PolicyCanvasNode(id: id, title: id, kind: .condition, position: position)
  node.inputPorts = inputPorts
  node.outputPorts = outputPorts
  return node
}
