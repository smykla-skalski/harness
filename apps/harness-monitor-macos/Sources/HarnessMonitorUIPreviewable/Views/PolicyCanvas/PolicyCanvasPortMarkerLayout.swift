import SwiftUI

struct PolicyCanvasPortMarker: Identifiable, Hashable, Sendable {
  let id: String
  let axisOffset: CGFloat
  let allowsInteraction: Bool
}

struct PolicyCanvasPortMarkerLayout: Equatable, Sendable {
  private let offsetsByEndpoint: [PolicyCanvasPortEndpoint: [PolicyCanvasPortSide: [CGFloat]]]

  static let empty = Self(offsetsByEndpoint: [:])

  init(offsetsByEndpoint: [PolicyCanvasPortEndpoint: [PolicyCanvasPortSide: [CGFloat]]]) {
    self.offsetsByEndpoint = offsetsByEndpoint.mapValues { offsetsBySide in
      offsetsBySide.mapValues(policyCanvasSortedUniquePortMarkerOffsets)
    }
  }

  func markers(
    for endpoint: PolicyCanvasPortEndpoint,
    side: PolicyCanvasPortSide,
    isVisible: Bool
  ) -> [PolicyCanvasPortMarker] {
    guard isVisible else {
      return []
    }
    let key = policyCanvasCanonicalPortEndpoint(endpoint)
    let offsets = offsetsByEndpoint[key]?[side] ?? [0]
    let primaryIndex = offsets.indices.min { left, right in
      abs(offsets[left]) < abs(offsets[right])
    } ?? offsets.startIndex
    return offsets.enumerated().map { index, offset in
      PolicyCanvasPortMarker(
        id: "\(side.rawValue)-\(Int((offset * 1_000).rounded()))",
        axisOffset: offset,
        allowsInteraction: index == primaryIndex
      )
    }
  }
}

func policyCanvasCanonicalPortEndpoint(
  _ endpoint: PolicyCanvasPortEndpoint
) -> PolicyCanvasPortEndpoint {
  PolicyCanvasPortEndpoint(
    nodeID: endpoint.nodeID,
    portID: endpoint.portID,
    kind: endpoint.kind
  )
}

extension PolicyCanvasRouteWorkerInput {
  func portMarkerLayout(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> PolicyCanvasPortMarkerLayout {
    let orderedEdges = policyCanvasRouteBuildOrder(
      edges: edges,
      portAnchors: portAnchors(nodeIndex: nodeIndex)
    )
    let terminalSlots = policyCanvasRouteEndpointSlots(edges: orderedEdges)
    var offsetsByEndpoint: [PolicyCanvasPortEndpoint: [PolicyCanvasPortSide: [CGFloat]]] = [:]
    for edge in orderedEdges {
      guard let route = routes[edge.id] else {
        continue
      }
      insertMarkerOffset(
        for: edge.source,
        side: policyCanvasRouteSourceSide(route) ?? policyCanvasResolvedPortSide(for: edge.source),
        slot: terminalSlots[edge.id]?.source ?? .single,
        nodeIndex: nodeIndex,
        offsetsByEndpoint: &offsetsByEndpoint
      )
      insertMarkerOffset(
        for: edge.target,
        side: policyCanvasRouteTargetSide(route) ?? policyCanvasResolvedPortSide(for: edge.target),
        slot: terminalSlots[edge.id]?.target ?? .single,
        nodeIndex: nodeIndex,
        offsetsByEndpoint: &offsetsByEndpoint
      )
    }
    return PolicyCanvasPortMarkerLayout(offsetsByEndpoint: offsetsByEndpoint)
  }

  private func insertMarkerOffset(
    for endpoint: PolicyCanvasPortEndpoint,
    side: PolicyCanvasPortSide,
    slot: PolicyCanvasRouteEndpointSlot,
    nodeIndex: [String: PolicyCanvasRouteNode],
    offsetsByEndpoint: inout [PolicyCanvasPortEndpoint: [PolicyCanvasPortSide: [CGFloat]]]
  ) {
    guard let offset = portMarkerOffset(
      for: endpoint,
      side: side,
      slot: slot,
      nodeIndex: nodeIndex
    ) else {
      return
    }
    let key = policyCanvasCanonicalPortEndpoint(endpoint)
    offsetsByEndpoint[key, default: [:]][side, default: []].append(offset)
  }

  private func portMarkerOffset(
    for endpoint: PolicyCanvasPortEndpoint,
    side: PolicyCanvasPortSide,
    slot: PolicyCanvasRouteEndpointSlot,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> CGFloat? {
    guard
      let node = nodeIndex[endpoint.nodeID],
      let point = portAnchor(for: endpoint, side: side, nodeIndex: nodeIndex)
    else {
      return nil
    }
    let spacing = max(
      portSpacing(for: endpoint, side: side, nodeIndex: nodeIndex),
      PolicyCanvasLayout.defaultEdgeLineSpacing + PolicyCanvasVisibilityRouter.channelStep
    )
    let shifted = policyCanvasShiftedRouteAnchor(
      point,
      side: side,
      frame: node.frame,
      spacing: spacing,
      terminalSlot: slot
    )
    switch side {
    case .leading, .trailing:
      return shifted.y - point.y
    case .top, .bottom:
      return shifted.x - point.x
    }
  }
}

private func policyCanvasSortedUniquePortMarkerOffsets(_ offsets: [CGFloat]) -> [CGFloat] {
  offsets.sorted().reduce(into: [CGFloat]()) { unique, offset in
    if unique.last.map({ abs($0 - offset) > 0.001 }) ?? true {
      unique.append(offset)
    }
  }
}
