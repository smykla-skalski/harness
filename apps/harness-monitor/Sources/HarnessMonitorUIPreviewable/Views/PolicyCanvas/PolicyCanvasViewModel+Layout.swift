import SwiftUI

enum PolicyCanvasCanvasHitTarget: Equatable {
  case port(PolicyCanvasPortEndpoint)
  case node(String)
  case group(String)
}

extension PolicyCanvasViewModel {
  var canvasContentSize: CGSize {
    let bounds = canvasContentBounds
    guard !bounds.isNull else {
      // `CGRect.null` carries `greatestFiniteMagnitude` coordinates. Feeding
      // those through the viewport's `contentSize * zoom` math overflows to
      // infinity once zoom exceeds 1.0, which is the runtime warning the
      // canvas was logging on empty/live startup paths.
      return PolicyCanvasLayout.minimumCanvasSize
    }
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

  func fittedInitialZoom(
    for viewportSize: CGSize,
    contentBounds: CGRect? = nil
  ) -> CGFloat {
    guard viewportSize.width > 0, viewportSize.height > 0 else {
      return zoom
    }
    let bounds = contentBounds ?? canvasContentBounds
    guard !bounds.isNull else {
      return zoom
    }
    let inset = PolicyCanvasLayout.initialViewportInset * 2
    let width = bounds.width + inset
    let height = bounds.height + inset
    guard width > 0, height > 0 else {
      return zoom
    }
    let fittedZoom = min(viewportSize.width / width, viewportSize.height / height)
    return max(
      PolicyCanvasLayout.minimumZoom,
      min(PolicyCanvasLayout.maximumZoom, fittedZoom)
    )
  }

  /// Node obstacles are hard blockers for the router. Group backgrounds are not:
  /// they are visual containers, not shapes, and treating them as walls forces
  /// long loop-like detours around whole sections of the canvas.
  var nodeRoutingObstacles: [CGRect] {
    nodes.map { node in
      CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize)
    }
  }

  /// Per-edge obstacle list. Includes nodes and compact group-title strips as
  /// hard obstacles, but leaves group bodies passable. This follows the
  /// visibility-router model: route around shapes first; score or nudge softer
  /// cluster/group interactions later instead of making them maze walls.
  func routingObstacles(source: CGPoint, target: CGPoint) -> [CGRect] {
    nodeRoutingObstacles + policyCanvasGroupTitleFrames(groups)
  }

  /// Per-kind edge counts for the inspector empty-state breakdown.
  /// Returns 0 for kinds with no edges so the inspector can render a
  /// stable three-row layout (flow / control / error) regardless of
  /// which kinds are present in the current document.
  var edgeCountsByKind: [PolicyCanvasEdgeKind: Int] {
    var counts: [PolicyCanvasEdgeKind: Int] = [:]
    for kind in PolicyCanvasEdgeKind.allCases {
      counts[kind] = 0
    }
    for edge in edges {
      counts[edge.kind, default: 0] += 1
    }
    return counts
  }

  var edgeRouteLanes: [String: Int] {
    policyCanvasSharedTargetRouteLaneAssignments(
      edges: edges,
      bucket: edgeRouteBucket,
      sortKey: edgeRouteSortKey
    )
  }

  var edgeSourceFanoutLanes: [String: Int] {
    policyCanvasLaneAssignments(
      edges: edges,
      bucket: edgeSourceFanoutBucket,
      sortKey: edgeSourceFanoutSortKey
    )
  }

  var edgeRouteFamilyPreferences: [String: PolicyCanvasRouteFamilyPreference] {
    policyCanvasRouteFamilyPreferences(edges: edges)
  }

  var edgeTargetFanoutLanes: [String: Int] {
    policyCanvasTargetFanoutLaneAssignments(
      edges: edges,
      familyPreferences: edgeRouteFamilyPreferences,
      bucket: edgeTargetFanoutBucket,
      sortKey: edgeTargetFanoutSortKey
    )
  }

  func edgeLineSpacing(for edge: PolicyCanvasEdge) -> CGFloat {
    max(portSpacing(for: edge.source), portSpacing(for: edge.target))
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

  /// Semantic side anchors for the endpoint's port, used by flex routing.
  /// Output ports can route from trailing or bottom; input ports can route
  /// into leading or top. Those are the sides that the node renderer exposes
  /// as visible/interactive ports for each kind, so flex routing cannot choose
  /// an impossible side that reads as a wrong port in the rendered canvas.
  /// Returns an empty array when the endpoint cannot resolve.
  ///
  /// **Order is load-bearing for the fallback path.**
  /// Output sides are `[.trailing, .bottom]` and input sides are `[.leading,
  /// .top]`, so a degenerate flex fallback still yields the natural
  /// trailing-output to leading-input pair.
  func portAnchorCandidates(
    for endpoint: PolicyCanvasPortEndpoint
  ) -> [PolicyCanvasRouteAnchorCandidate] {
    guard let node = node(endpoint.nodeID) else {
      return []
    }
    let ports = endpoint.kind == .input ? node.inputPorts : node.outputPorts
    guard let index = ports.firstIndex(where: { $0.id == endpoint.portID }) else {
      return []
    }
    return routablePortSides(for: endpoint.kind).map { side in
      (point: portAnchor(for: node, side: side, index: index, count: ports.count), side: side)
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

  func nodeCenter(_ node: PolicyCanvasNode) -> CGPoint {
    CGPoint(
      x: node.position.x + PolicyCanvasLayout.nodeSize.width / 2,
      y: node.position.y + PolicyCanvasLayout.nodeSize.height / 2
    )
  }

  private func defaultPortSide(for kind: PolicyCanvasPortKind) -> PolicyCanvasPortSide {
    kind == .input ? .leading : .trailing
  }

  private func routablePortSides(for kind: PolicyCanvasPortKind) -> [PolicyCanvasPortSide] {
    switch kind {
    case .input:
      [.leading, .top]
    case .output:
      [.trailing, .bottom]
    }
  }

  func portAnchor(
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
    let sourceAnchor = portAnchor(for: edge.source) ?? .zero
    let targetAnchor = portAnchor(for: edge.target) ?? .zero
    return [
      edgeRouteBucket(edge),
      String(Int(sourceAnchor.y.rounded())),
      String(Int(targetAnchor.y.rounded())),
      String(Int(targetAnchor.x.rounded())),
      edge.source.portID,
      edge.target.nodeID,
      edge.target.portID,
    ]
    .joined(separator: "|")
  }

  private func edgeRouteBucket(_ edge: PolicyCanvasEdge) -> String {
    let sourceSide = resolvedPortSide(for: edge.source).rawValue
    let targetSide = resolvedPortSide(for: edge.target).rawValue
    let targetScope = node(edge.target.nodeID)?.groupID ?? edge.target.nodeID
    return [
      edge.source.nodeID,
      sourceSide,
      targetScope,
      targetSide,
    ]
    .joined(separator: "|")
  }

  private func edgeRouteSortKey(_ edge: PolicyCanvasEdge) -> String {
    edgeLaneSortKey(edge)
  }

  private func edgeSourceFanoutBucket(_ edge: PolicyCanvasEdge) -> String {
    let side = resolvedPortSide(for: edge.source).rawValue
    return "\(edge.source.nodeID)|\(side)"
  }

  private func edgeTargetFanoutBucket(_ edge: PolicyCanvasEdge) -> String {
    let side = resolvedPortSide(for: edge.target).rawValue
    return "\(edge.target.nodeID)|\(side)"
  }

  private func edgeSourceFanoutSortKey(_ edge: PolicyCanvasEdge) -> String {
    fanoutSortKey(
      bucket: edgeSourceFanoutBucket(edge),
      anchor: portAnchor(for: edge.target) ?? .zero,
      nodeID: edge.target.nodeID,
      portID: edge.target.portID
    )
  }

  private func edgeTargetFanoutSortKey(_ edge: PolicyCanvasEdge) -> String {
    fanoutSortKey(
      bucket: edgeTargetFanoutBucket(edge),
      anchor: portAnchor(for: edge.source) ?? .zero,
      nodeID: edge.source.nodeID,
      portID: edge.source.portID
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

  func portSpacing(
    for endpoint: PolicyCanvasPortEndpoint,
    side overrideSide: PolicyCanvasPortSide? = nil
  ) -> CGFloat {
    guard let node = node(endpoint.nodeID) else {
      return PolicyCanvasLayout.defaultEdgeLineSpacing
    }
    let ports = endpoint.kind == .input ? node.inputPorts : node.outputPorts
    guard ports.count > 1 else {
      return PolicyCanvasLayout.defaultEdgeLineSpacing
    }
    let side = overrideSide ?? resolvedPortSide(for: endpoint)
    switch side {
    case .leading, .trailing:
      return abs(
        PolicyCanvasLayout.portY(index: 1, count: ports.count)
          - PolicyCanvasLayout.portY(index: 0, count: ports.count)
      )
    case .top, .bottom:
      return abs(
        PolicyCanvasLayout.portX(index: 1, count: ports.count)
          - PolicyCanvasLayout.portX(index: 0, count: ports.count)
      )
    }
  }

  private func resolvedPortSide(for endpoint: PolicyCanvasPortEndpoint) -> PolicyCanvasPortSide {
    endpoint.side ?? defaultPortSide(for: endpoint.kind)
  }
}
