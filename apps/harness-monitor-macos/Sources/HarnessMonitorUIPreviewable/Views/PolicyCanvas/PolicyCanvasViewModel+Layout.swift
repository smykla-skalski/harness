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

  /// Obstacles handed to the visibility router. Node frames + group
  /// frames; both layers (`PolicyCanvasEdgeLayer` and
  /// `PolicyCanvasEdgeLabelLayer`) hoist this once per body so the
  /// stroke and label render against the same obstacle set.
  /// `PolicyCanvasVisibilityRouter.preparedObstacles` auto-drops any
  /// obstacle whose padded rect contains source or target, which is
  /// what makes intra-group edges still work: a member node's source
  /// port sits inside its group's padded frame, so the source's group
  /// gets filtered automatically and the route can exit cleanly.
  var routingObstacles: [CGRect] {
    let nodeObstacles = nodes.map { node in
      CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize)
    }
    let groupObstacles = groups.map(\.frame)
    return nodeObstacles + groupObstacles
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

  /// All four side anchors for the endpoint's port, used by T2.2 flex
  /// routing. Returns at most four points (leading/trailing/top/bottom) so
  /// the router can pick the combination that yields the fewest bends.
  /// Returns an empty array when the endpoint cannot resolve.
  ///
  /// **Order is load-bearing for the fallback path.**
  /// `PolicyCanvasPortSide.allSides` returns `[.leading, .trailing, .top,
  /// .bottom]`, and `PolicyCanvasVisibilityRouter.route(sourceCandidates:
  /// targetCandidates:context:)` falls back to `sourceCandidates[0]` paired
  /// with `targetCandidates[0]` when every combo's A* call reports no path
  /// (the degenerate "all candidates fall back" case). With the current
  /// order that degenerate fallback is `leading → leading`, the canonical
  /// node side for inbound flow. Reordering this list silently changes
  /// which side gets picked when routing cannot solve, so any caller
  /// touching `allSides` must consider whether the new `[0]` is still the
  /// right default geometry.
  func portAnchorCandidates(for endpoint: PolicyCanvasPortEndpoint) -> [CGPoint] {
    guard let node = node(endpoint.nodeID) else {
      return []
    }
    let ports = endpoint.kind == .input ? node.inputPorts : node.outputPorts
    guard let index = ports.firstIndex(where: { $0.id == endpoint.portID }) else {
      return []
    }
    return PolicyCanvasPortSide.allSides.map { side in
      portAnchor(for: node, side: side, index: index, count: ports.count)
    }
  }

  /// Bulk-resolve every endpoint referenced by `edges` into a single dictionary
  /// the body-local site can hoist before iterating. Hot-path callers
  /// (`PolicyCanvasEdgeLayer`, `PolicyCanvasEdgeLabelLayer`) used to call
  /// `portAnchor(for:)` twice per edge per body run, each of which walked
  /// `nodes` linearly and then walked the port list — quadratic in edge count
  /// on the dense default fixture. This pre-rolls a `[Endpoint: CGPoint]` map
  /// once per body so each per-edge lookup is O(1). Endpoints that fail to
  /// resolve (deleted node, missing port id) are omitted from the dictionary
  /// so callers still gate rendering on `dict[endpoint] != nil`, matching the
  /// behavior of the per-edge `portAnchor(for:)` short-circuit.
  ///
  /// Allocation contract: builds one node-id index dictionary and one result
  /// dictionary per call; callers must scope this to a body-local `let` so the
  /// dictionary is dropped at end-of-body and not retained across renders.
  func portAnchors(
    for edges: [PolicyCanvasEdge]
  ) -> [PolicyCanvasPortEndpoint: CGPoint] {
    guard !edges.isEmpty else {
      return [:]
    }
    // O(n) node index once. `nodes` is small (<200) but `first(where:)` on
    // each endpoint lookup is O(n) per call; index up front so the per-edge
    // path is O(1) for both endpoint resolutions.
    var nodeIndex: [String: PolicyCanvasNode] = [:]
    nodeIndex.reserveCapacity(nodes.count)
    for node in nodes {
      nodeIndex[node.id] = node
    }
    var anchors: [PolicyCanvasPortEndpoint: CGPoint] = [:]
    anchors.reserveCapacity(edges.count * 2)
    for edge in edges {
      if let point = portAnchor(for: edge.source, nodeIndex: nodeIndex) {
        anchors[edge.source] = point
      }
      if let point = portAnchor(for: edge.target, nodeIndex: nodeIndex) {
        anchors[edge.target] = point
      }
    }
    return anchors
  }

  private func portAnchor(
    for endpoint: PolicyCanvasPortEndpoint,
    nodeIndex: [String: PolicyCanvasNode]
  ) -> CGPoint? {
    guard let node = nodeIndex[endpoint.nodeID] else {
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
