import SwiftUI

extension PolicyCanvasViewModel {
  var canvasContentSize: CGSize {
    let bounds = canvasContentBounds
    return CGSize(
      width: max(
        PolicyCanvasLayout.minimumCanvasSize.width,
        bounds.maxX + PolicyCanvasLayout.canvasTrailingPadding
      ),
      height: max(
        PolicyCanvasLayout.minimumCanvasSize.height,
        bounds.maxY + PolicyCanvasLayout.canvasBottomPadding
      )
    )
  }

  var canvasContentBounds: CGRect {
    let nodeBounds = nodes.reduce(CGRect.null) { partial, node in
      partial.union(policyCanvasNodeFrame(node))
    }
    return groups.reduce(nodeBounds) { partial, group in
      partial.union(group.frame)
    }
  }

  var initialViewportAnchorPoint: CGPoint {
    let bounds = canvasContentBounds
    guard !bounds.isNull else {
      return CGPoint(
        x: PolicyCanvasLayout.minimumCanvasSize.width / 2,
        y: PolicyCanvasLayout.minimumCanvasSize.height / 2
      )
    }
    return CGPoint(
      x: bounds.midX * zoom,
      y: bounds.midY * zoom
    )
  }

  var edgeRouteLanes: [String: Int] {
    let sortedEdges = edges.sorted { left, right in
      let leftKey = edgeLaneSortKey(left)
      let rightKey = edgeLaneSortKey(right)
      if leftKey != rightKey {
        return leftKey < rightKey
      }
      return left.id < right.id
    }
    var nextLaneByBucket: [String: Int] = [:]
    var lanes: [String: Int] = [:]
    for edge in sortedEdges {
      let bucket = edgeLaneBucket(edge)
      let lane = nextLaneByBucket[bucket, default: 0]
      lanes[edge.id] = lane
      nextLaneByBucket[bucket] = lane + 1
    }
    return lanes
  }

  func portAnchor(for endpoint: PolicyCanvasPortEndpoint) -> CGPoint? {
    guard let node = node(endpoint.nodeID) else {
      return nil
    }
    let ports = endpoint.kind == .input ? node.inputPorts : node.outputPorts
    guard let index = ports.firstIndex(where: { $0.id == endpoint.portID }) else {
      return nil
    }
    let side = endpoint.side ?? defaultPortSide(for: endpoint.kind)
    return portAnchor(for: node, side: side, index: index, count: ports.count)
  }

  func node(_ id: String) -> PolicyCanvasNode? {
    nodes.first { $0.id == id }
  }

  func group(_ id: String) -> PolicyCanvasGroup? {
    groups.first { $0.id == id }
  }

  func nodes(in groupID: String) -> [PolicyCanvasNode] {
    nodes.filter { $0.groupID == groupID }
  }

  func reconcileGroupFrames() {
    for index in groups.indices {
      let members = nodes(in: groups[index].id)
      guard let frame = policyCanvasGroupFrame(containing: members) else {
        continue
      }
      groups[index].frame = frame
    }
  }

  func seedGroupDrag(groupID: String, group: PolicyCanvasGroup) {
    if groupDragOrigins[groupID] == nil {
      groupDragOrigins[groupID] = group.frame
      let origins = nodes(in: groupID).map { ($0.id, $0.position) }
      groupNodeDragOrigins[groupID] = Dictionary(uniqueKeysWithValues: origins)
    }
  }

  func moveNodes(in groupID: String, by delta: CGSize) {
    let origins = groupNodeDragOrigins[groupID] ?? [:]
    for index in nodes.indices where nodes[index].groupID == groupID {
      guard let origin = origins[nodes[index].id] else {
        continue
      }
      nodes[index].position = snapped(
        CGPoint(x: origin.x + delta.width, y: origin.y + delta.height)
      )
    }
  }

  func nodeCenter(_ node: PolicyCanvasNode) -> CGPoint {
    CGPoint(
      x: node.position.x + PolicyCanvasLayout.nodeSize.width / 2,
      y: node.position.y + PolicyCanvasLayout.nodeSize.height / 2
    )
  }

  func containingGroupID(
    for point: CGPoint,
    excluding excludedID: String? = nil
  ) -> String? {
    groups.first { group in
      group.id != excludedID && group.frame.contains(point)
    }?.id
  }

  func snapped(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: (point.x / PolicyCanvasLayout.gridSize).rounded() * PolicyCanvasLayout.gridSize,
      y: (point.y / PolicyCanvasLayout.gridSize).rounded() * PolicyCanvasLayout.gridSize
    )
  }

  private func defaultPortSide(for kind: PolicyCanvasPortKind) -> PolicyCanvasPortSide {
    kind == .input ? .leading : .trailing
  }

  private func portAnchor(
    for node: PolicyCanvasNode,
    side: PolicyCanvasPortSide,
    index: Int,
    count: Int
  ) -> CGPoint {
    switch side {
    case .leading:
      CGPoint(
        x: node.position.x,
        y: node.position.y + PolicyCanvasLayout.portY(index: index, count: count)
      )
    case .trailing:
      CGPoint(
        x: node.position.x + PolicyCanvasLayout.nodeSize.width,
        y: node.position.y + PolicyCanvasLayout.portY(index: index, count: count)
      )
    case .top:
      CGPoint(
        x: node.position.x + PolicyCanvasLayout.portX(index: index, count: count),
        y: node.position.y
      )
    case .bottom:
      CGPoint(
        x: node.position.x + PolicyCanvasLayout.portX(index: index, count: count),
        y: node.position.y + PolicyCanvasLayout.nodeSize.height
      )
    }
  }

  private func edgeLaneSortKey(_ edge: PolicyCanvasEdge) -> String {
    let targetY = portAnchor(for: edge.target)?.y ?? 0
    return "\(edgeLaneBucket(edge))|\(Int(targetY.rounded()))|\(edge.source.portID)"
  }

  private func edgeLaneBucket(_ edge: PolicyCanvasEdge) -> String {
    let sourceGroup = node(edge.source.nodeID)?.groupID ?? "ungrouped"
    let targetGroup = node(edge.target.nodeID)?.groupID ?? "ungrouped"
    return "\(sourceGroup)->\(targetGroup)"
  }
}
