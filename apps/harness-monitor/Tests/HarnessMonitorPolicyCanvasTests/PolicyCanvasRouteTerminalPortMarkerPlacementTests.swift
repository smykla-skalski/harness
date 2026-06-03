import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas route-terminal port markers")
struct PolicyCanvasRouteTerminalPortMarkerPlacementTests {
  @Test("marker follows a vertical departure off the natural side")
  func markerFollowsVerticalDeparture() {
    let source = policyCanvasMarkerTestNode(
      id: "source",
      position: .zero,
      inputPorts: [],
      outputPorts: [PolicyCanvasPort(id: "out", title: "out", kind: .output)]
    )
    let target = policyCanvasMarkerTestNode(
      id: "target",
      position: CGPoint(x: 320, y: 0),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    let edge = PolicyCanvasEdge(
      id: "edge",
      source: PolicyCanvasPortEndpoint(nodeID: "source", portID: "out", kind: .output),
      target: PolicyCanvasPortEndpoint(nodeID: "target", portID: "in", kind: .input),
      label: "route",
      pinnedPortSide: false
    )
    let input = PolicyCanvasRouteWorkerInput(
      nodes: [source, target], groups: [], edges: [edge], fontScale: 1
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    // The output's natural side is trailing, but this route departs straight up
    // off the top edge, 30pt right of the top-port center, then arrives
    // horizontally into the target's leading port.
    let topCenterX = PolicyCanvasLayout.portX(index: 0, count: 1)
    let leadingCenterY = PolicyCanvasLayout.portY(index: 0, count: 1)
    let route = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: topCenterX + 30, y: 0),
        CGPoint(x: topCenterX + 30, y: -60),
        CGPoint(x: 260, y: -60),
        CGPoint(x: 260, y: leadingCenterY),
        CGPoint(x: 320, y: leadingCenterY),
      ],
      labelPosition: .zero
    )
    let layout = PolicyCanvasRouteTerminalPortMarkerPlacement().placeMarkers(
      input: PolicyCanvasPortMarkerPlacementInput(
        prepared: prepared,
        routes: [edge.id: route],
        nodeIndex: prepared.nodeIndex
      )
    )

    let sourceTerminal = layout.terminal(edgeID: edge.id, role: .source)
    #expect(sourceTerminal?.side == .top)
    #expect(abs((sourceTerminal?.axisOffset ?? .nan) - 30) < 0.001)
    let topMarkers = layout.markers(for: edge.source, side: .top, isVisible: true)
    #expect(topMarkers.contains { abs($0.axisOffset - 30) < 0.5 })

    let targetTerminal = layout.terminal(edgeID: edge.id, role: .target)
    #expect(targetTerminal?.side == .leading)
    #expect(abs(targetTerminal?.axisOffset ?? .nan) < 0.001)
    let leadingMarkers = layout.markers(for: edge.target, side: .leading, isVisible: true)
    #expect(leadingMarkers.contains { abs($0.axisOffset) < 0.5 })
  }

  @Test("a natural horizontal route centers the marker on the port")
  func naturalHorizontalRouteCentersMarker() {
    let source = policyCanvasMarkerTestNode(
      id: "source",
      position: .zero,
      inputPorts: [],
      outputPorts: [PolicyCanvasPort(id: "out", title: "out", kind: .output)]
    )
    let target = policyCanvasMarkerTestNode(
      id: "target",
      position: CGPoint(x: 320, y: 0),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    let edge = PolicyCanvasEdge(
      id: "edge",
      source: PolicyCanvasPortEndpoint(nodeID: "source", portID: "out", kind: .output),
      target: PolicyCanvasPortEndpoint(nodeID: "target", portID: "in", kind: .input),
      label: "route",
      pinnedPortSide: false
    )
    let input = PolicyCanvasRouteWorkerInput(
      nodes: [source, target], groups: [], edges: [edge], fontScale: 1
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let trailingX = PolicyCanvasLayout.nodeSize.width
    let centerY = PolicyCanvasLayout.portY(index: 0, count: 1)
    let route = PolicyCanvasEdgeRoute(
      points: [CGPoint(x: trailingX, y: centerY), CGPoint(x: 320, y: centerY)],
      labelPosition: .zero
    )
    let layout = PolicyCanvasRouteTerminalPortMarkerPlacement().placeMarkers(
      input: PolicyCanvasPortMarkerPlacementInput(
        prepared: prepared,
        routes: [edge.id: route],
        nodeIndex: prepared.nodeIndex
      )
    )

    let sourceTerminal = layout.terminal(edgeID: edge.id, role: .source)
    #expect(sourceTerminal?.side == .trailing)
    #expect(abs(sourceTerminal?.axisOffset ?? .nan) < 0.001)
    let targetTerminal = layout.terminal(edgeID: edge.id, role: .target)
    #expect(targetTerminal?.side == .leading)
    #expect(abs(targetTerminal?.axisOffset ?? .nan) < 0.001)
  }
}
