import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas port marker layout")
struct PolicyCanvasPortMarkerLayoutTests {
  @Test("terminal markers fit four vertical lanes before deterministic overflow")
  func terminalMarkersFitFourVerticalLanesBeforeDeterministicOverflow() {
    let target = policyCanvasMarkerTestNode(
      id: "target",
      position: CGPoint(x: 220, y: 80),
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    let sources = (0..<5).map { index in
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
    let targetTerminals = edges.compactMap { edge in
      layout.terminal(edgeID: edge.id, role: .target)
    }
    let leadingTerminals = targetTerminals.filter { $0.side == .leading }
    let topTerminals = targetTerminals.filter { $0.side == .top }

    #expect(targetTerminals.count == edges.count)
    #expect(leadingTerminals.count == 4)
    #expect(topTerminals.count == 1)
    #expect(leadingMarkers.count == 4)
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
    assertEvenSpacing(leadingCoordinates, extent: PolicyCanvasLayout.nodeSize.height)
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

    #expect(trailing.count == 4)
    #expect(bottom.isEmpty)
    let trailingCoordinates = trailing.map { edge, terminal in
      sourceCoordinate(edge.source, side: .trailing) + terminal.axisOffset
    }.sorted()
    assertEvenSpacing(trailingCoordinates, extent: PolicyCanvasLayout.nodeSize.height)
  }

  @Test("preferred opposite horizontal sides render explicit markers")
  func preferredOppositeHorizontalSidesRenderExplicitMarkers() {
    let source = policyCanvasMarkerTestNode(
      id: "source",
      position: CGPoint(x: 360, y: 0),
      inputPorts: [],
      outputPorts: [PolicyCanvasPort(id: "out", title: "out", kind: .output)]
    )
    let target = policyCanvasMarkerTestNode(
      id: "target",
      position: .zero,
      inputPorts: [PolicyCanvasPort(id: "in", title: "in", kind: .input)],
      outputPorts: []
    )
    let edge = PolicyCanvasEdge(
      id: "back",
      source: PolicyCanvasPortEndpoint(
        nodeID: source.id,
        portID: "out",
        kind: .output,
        side: .leading
      ),
      target: PolicyCanvasPortEndpoint(
        nodeID: target.id,
        portID: "in",
        kind: .input,
        side: .trailing
      ),
      label: "back",
      pinnedPortSide: true
    )
    let input = PolicyCanvasRouteWorkerInput(
      nodes: [source, target],
      groups: [],
      edges: [edge],
      fontScale: 1
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let sourcePoint = CGPoint(
      x: source.position.x,
      y: source.position.y + PolicyCanvasLayout.nodeSize.height / 2
    )
    let targetPoint = CGPoint(
      x: target.position.x + PolicyCanvasLayout.nodeSize.width,
      y: target.position.y + PolicyCanvasLayout.nodeSize.height / 2
    )
    let layout = prepared.portMarkerLayout(
      routes: [
        edge.id: PolicyCanvasEdgeRoute(
          points: [sourcePoint, targetPoint],
          labelPosition: CGPoint(x: 200, y: sourcePoint.y)
        )
      ],
      nodeIndex: prepared.nodeIndex
    )

    #expect(layout.terminal(edgeID: edge.id, role: .source)?.side == .leading)
    #expect(layout.terminal(edgeID: edge.id, role: .target)?.side == .trailing)
    #expect(layout.markers(for: edge.source, side: .leading, isVisible: true).count == 1)
    #expect(layout.markers(for: edge.target, side: .trailing, isVisible: true).count == 1)
  }

  func assertBorderCoordinates(
    markers: [PolicyCanvasPortMarker],
    base: CGFloat,
    extent: CGFloat
  ) {
    let inset = policyCanvasPortMarkerInset()
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

  func assertEvenSpacing(_ coordinates: [CGFloat], extent: CGFloat) {
    guard coordinates.count > 1 else {
      return
    }
    let deltas = zip(coordinates, coordinates.dropFirst()).map { $1 - $0 }
    guard let firstDelta = deltas.first else {
      return
    }
    #expect(deltas.allSatisfy { abs($0 - firstDelta) < 0.001 })
    #expect(abs((coordinates[0] + coordinates[coordinates.count - 1]) - extent) < 0.001)
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
