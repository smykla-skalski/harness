import SwiftUI

extension PolicyCanvasPreparedRouteInput {
  private func edgeLaneSortKey(
    _ edge: PolicyCanvasEdge,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> String {
    let sourceAnchor = portAnchor(for: edge.source, nodeIndex: nodeIndex) ?? .zero
    let targetAnchor = portAnchor(for: edge.target, nodeIndex: nodeIndex) ?? .zero
    return [
      edgeRouteBucket(edge, nodeIndex: nodeIndex),
      String(Int(sourceAnchor.y.rounded())),
      String(Int(targetAnchor.y.rounded())),
      String(Int(targetAnchor.x.rounded())),
      edge.source.portID,
      edge.target.nodeID,
      edge.target.portID,
    ].joined(separator: "|")
  }

  func edgeRouteBucket(
    _ edge: PolicyCanvasEdge,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> String {
    let sourceSide = policyCanvasResolvedPortSide(for: edge.source).rawValue
    let targetSide = policyCanvasResolvedPortSide(for: edge.target).rawValue
    let targetScope = nodeIndex[edge.target.nodeID]?.groupID ?? edge.target.nodeID
    return [
      edge.source.nodeID,
      sourceSide,
      targetScope,
      targetSide,
    ].joined(separator: "|")
  }

  func edgeRouteSortKey(
    _ edge: PolicyCanvasEdge,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> String {
    edgeLaneSortKey(edge, nodeIndex: nodeIndex)
  }

  func edgeSourceFanoutBucket(_ edge: PolicyCanvasEdge) -> String {
    let side = policyCanvasResolvedPortSide(for: edge.source).rawValue
    return "\(edge.source.nodeID)|\(side)"
  }

  func edgeTargetFanoutBucket(_ edge: PolicyCanvasEdge) -> String {
    let side = policyCanvasResolvedPortSide(for: edge.target).rawValue
    return "\(edge.target.nodeID)|\(side)"
  }

  func edgeSourceFanoutSortKey(
    _ edge: PolicyCanvasEdge,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> String {
    fanoutSortKey(
      bucket: edgeSourceFanoutBucket(edge),
      anchor: portAnchor(for: edge.target, nodeIndex: nodeIndex) ?? .zero,
      nodeID: edge.target.nodeID,
      portID: edge.target.portID
    )
  }

  func edgeTargetFanoutSortKey(
    _ edge: PolicyCanvasEdge,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> String {
    let sourceAnchor = portAnchor(for: edge.source, nodeIndex: nodeIndex) ?? .zero
    let targetCenterX = nodeIndex[edge.target.nodeID]?.frame.midX ?? sourceAnchor.x
    return policyCanvasTargetFanoutNestingSortKey(
      bucket: edgeTargetFanoutBucket(edge),
      sourceX: sourceAnchor.x,
      targetCenterX: targetCenterX,
      sourceY: sourceAnchor.y,
      edgeID: edge.id
    )
  }

  func routeEndpointSlots(
    edges: [PolicyCanvasEdge],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [String: PolicyCanvasRouteEndpointSlots] {
    policyCanvasRouteEndpointSlots(
      edges: edges,
      sourceSortKey: {
        edgeRouteEndpointSlotSortKey($0, role: .source, nodeIndex: nodeIndex)
      },
      targetSortKey: {
        edgeRouteEndpointSlotSortKey($0, role: .target, nodeIndex: nodeIndex)
      }
    )
  }

  private func fanoutSortKey(
    bucket: String,
    anchor: CGPoint,
    nodeID: String,
    portID: String
  ) -> String {
    [
      bucket,
      String(policyCanvasFanoutBucketCoordinate(anchor.y)),
      String(policyCanvasFanoutBucketCoordinate(anchor.x)),
      nodeID,
      portID,
    ]
    .joined(separator: "|")
  }

  private func edgeRouteEndpointSlotSortKey(
    _ edge: PolicyCanvasEdge,
    role: PolicyCanvasRouteEndpointRole,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> String {
    let endpoint: PolicyCanvasPortEndpoint
    let farEndpoint: PolicyCanvasPortEndpoint
    switch role {
    case .source:
      endpoint = edge.source
      farEndpoint = edge.target
    case .target:
      endpoint = edge.target
      farEndpoint = edge.source
    }
    guard let node = nodeIndex[endpoint.nodeID] else {
      return policyCanvasPortMarkerSortKey(edge: edge, role: role)
    }
    let side = policyCanvasResolvedPortSide(for: endpoint)
    let farAnchor = portAnchor(for: farEndpoint, nodeIndex: nodeIndex) ?? .zero
    let angle = policyCanvasFanOrderKey(
      side: side,
      sideCenter: policyCanvasSideCenter(side: side, frame: node.frame),
      farAnchor: farAnchor
    )
    let angleKey = String(
      format: "%09d",
      Int(((Double(angle) + Double.pi) * 1_000_000).rounded())
    )
    return [
      angleKey,
      String(policyCanvasFanoutBucketCoordinate(farAnchor.y)),
      String(policyCanvasFanoutBucketCoordinate(farAnchor.x)),
      farEndpoint.nodeID,
      farEndpoint.portID,
      edge.label,
      edge.id,
    ]
    .joined(separator: "|")
  }

  func edgeLineSpacing(
    for edge: PolicyCanvasEdge,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> CGFloat {
    max(
      portSpacing(for: edge.source, nodeIndex: nodeIndex),
      portSpacing(for: edge.target, nodeIndex: nodeIndex)
    )
  }

  func portSpacingBySide(
    for endpoint: PolicyCanvasPortEndpoint,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [PolicyCanvasPortSide: CGFloat] {
    Dictionary(
      uniqueKeysWithValues: PolicyCanvasPortSide.allSides.map { side in
        (side, portSpacing(for: endpoint, side: side, nodeIndex: nodeIndex))
      })
  }

  func portSpacing(
    for endpoint: PolicyCanvasPortEndpoint,
    side overrideSide: PolicyCanvasPortSide? = nil,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> CGFloat {
    guard let node = nodeIndex[endpoint.nodeID] else {
      return PolicyCanvasLayout.defaultEdgeLineSpacing
    }
    let ports = endpoint.kind == .input ? node.inputPorts : node.outputPorts
    guard ports.count > 1 else {
      return PolicyCanvasLayout.defaultEdgeLineSpacing
    }
    let side = overrideSide ?? policyCanvasResolvedPortSide(for: endpoint)
    switch side {
    case .leading, .trailing:
      return abs(
        PolicyCanvasLayout.portY(index: 1, count: ports.count, nodeHeight: node.size.height)
          - PolicyCanvasLayout.portY(index: 0, count: ports.count, nodeHeight: node.size.height)
      )
    case .top, .bottom:
      return abs(
        PolicyCanvasLayout.portX(index: 1, count: ports.count, nodeWidth: node.size.width)
          - PolicyCanvasLayout.portX(index: 0, count: ports.count, nodeWidth: node.size.width)
      )
    }
  }
}
