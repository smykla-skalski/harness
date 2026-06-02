import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas

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
    let targetPoint = CGPoint(
      x: target.position.x, y: target.position.y + PolicyCanvasLayout.nodeSize.height / 2)
    let routes = Dictionary(
      uniqueKeysWithValues: edges.map { edge in
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
    #expect(
      abs(
        (leadingCoordinates[1] - leadingCoordinates[0])
          - (leadingCoordinates[2] - leadingCoordinates[1])) < 0.001)
  }

  @Test("terminal markers share capacity and spacing across logical ports")
  func terminalMarkersShareCapacityAndSpacingAcrossLogicalPorts() {
    let source = policyCanvasMarkerTestNode(
      id: "source",
      position: .zero,
      inputPorts: [],
      outputPorts: [
        PolicyCanvasPort(id: "pass", title: "pass", kind: .output),
        PolicyCanvasPort(id: "fail", title: "fail", kind: .output),
      ]
    )
    let targets = (0..<4).map { index in
      policyCanvasMarkerTestNode(
        id: "target-\(index)",
        position: CGPoint(x: 240, y: CGFloat(index * 70)),
        inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
        outputPorts: []
      )
    }
    let edges = targets.enumerated().map { index, target in
      PolicyCanvasEdge(
        id: "edge-\(index)",
        source: PolicyCanvasPortEndpoint(
          nodeID: source.id,
          portID: index < 2 ? "pass" : "fail",
          kind: .output
        ),
        target: PolicyCanvasPortEndpoint(nodeID: target.id, portID: "in", kind: .input),
        label: "route-\(index)",
        pinnedPortSide: false
      )
    }
    let input = PolicyCanvasRouteWorkerInput(
      nodes: [source] + targets,
      groups: [],
      edges: edges,
      fontScale: 1
    )
    let routes = Dictionary(
      uniqueKeysWithValues: edges.map { edge in
        (
          edge.id,
          PolicyCanvasEdgeRoute(points: [.zero, CGPoint(x: 80, y: 0)], labelPosition: .zero)
        )
      })

    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let layout = prepared.portMarkerLayout(routes: routes, nodeIndex: prepared.nodeIndex)
    let sourceTerminals = edges.compactMap { edge in
      layout.terminal(edgeID: edge.id, role: .source).map { (edge, $0) }
    }
    let trailing = sourceTerminals.filter { $0.1.side == .trailing }
    let bottom = sourceTerminals.filter { $0.1.side == .bottom }

    #expect(trailing.count == 3)
    #expect(bottom.count == 1)
    let trailingCoordinates = trailing.map { edge, terminal in
      sourceCoordinate(edge.source, side: .trailing) + terminal.axisOffset
    }.sorted()
    #expect(
      abs(
        (trailingCoordinates[1] - trailingCoordinates[0])
          - (trailingCoordinates[2] - trailingCoordinates[1])) < 0.001)
    #expect(
      abs(
        (trailingCoordinates[0] + trailingCoordinates[2])
          - PolicyCanvasLayout.nodeSize.height) < 0.001)
  }

  func assertBorderCoordinates(
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

  func sourceCoordinate(
    _ endpoint: PolicyCanvasPortEndpoint,
    side: PolicyCanvasPortSide
  ) -> CGFloat {
    let index = endpoint.portID == "pass" ? 0 : 1
    switch side {
    case .leading, .trailing:
      return PolicyCanvasLayout.portY(index: index, count: 2)
    case .top, .bottom:
      return PolicyCanvasLayout.portX(index: index, count: 2)
    }
  }
}

func policyCanvasMarkerTestNode(
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
