import OSLog
import SwiftUI

actor PolicyCanvasRouteWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "policy-canvas.perf"
  )

  private let router: any PolicyCanvasEdgeRouter
  private var cachedInput: PolicyCanvasRouteWorkerInput?
  private var cachedOutput: PolicyCanvasRouteWorkerOutput = .empty

  init(router: any PolicyCanvasEdgeRouter = PolicyCanvasMemoizedRouter(
    inner: PolicyCanvasVisibilityRouter()
  )) {
    self.router = router
  }

  func compute(input: PolicyCanvasRouteWorkerInput) -> PolicyCanvasRouteWorkerOutput {
    guard input != cachedInput else {
      return cachedOutput
    }
    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(
      "policy_canvas.routes.compute",
      id: signpostID,
      "nodes=\(input.nodes.count, privacy: .public) edges=\(input.edges.count, privacy: .public)"
    )
    defer {
      Self.signposter.endInterval(
        "policy_canvas.routes.compute",
        interval,
        "routes=\(self.cachedOutput.routes.count, privacy: .public)"
      )
    }

    let routes = input.displayedRoutes(router: router)
    let labelPositions = input.resolvedLabelPositions(routes: routes)
    let visibleBounds = input.visibleBounds(
      routes: routes,
      labelPositions: labelPositions
    )
    cachedInput = input
    cachedOutput = PolicyCanvasRouteWorkerOutput(
      routes: routes,
      labelPositions: labelPositions,
      visibleBounds: visibleBounds,
      contentSize: policyCanvasVisibleContentSize(visibleBounds: visibleBounds)
    )
    return cachedOutput
  }

  func waitForIdle() async {}
}

struct PolicyCanvasRouteWorkerInput: Equatable, Sendable {
  fileprivate let nodes: [PolicyCanvasRouteNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let fontScale: CGFloat

  init(
    nodes: [PolicyCanvasNode],
    groups: [PolicyCanvasGroup],
    edges: [PolicyCanvasEdge],
    fontScale: CGFloat
  ) {
    self.nodes = nodes.map(PolicyCanvasRouteNode.init(node:))
    self.groups = groups
    self.edges = edges
    self.fontScale = fontScale
  }

  var contentBounds: CGRect {
    let nodeBounds = nodes.reduce(CGRect.null) { partial, node in
      partial.union(node.frame)
    }
    let bounds = groups.reduce(nodeBounds) { partial, group in
      partial.union(group.frame)
    }
    guard !bounds.isNull else {
      return CGRect(origin: .zero, size: PolicyCanvasLayout.minimumCanvasSize)
    }
    return bounds
  }

  func visibleBounds(
    routes: [String: PolicyCanvasEdgeRoute],
    labelPositions: [String: CGPoint]
  ) -> CGRect {
    var bounds = contentBounds
    for route in routes.values {
      for point in route.points {
        let pointRect = CGRect(origin: point, size: .zero)
        bounds = bounds.isNull ? pointRect : bounds.union(pointRect)
      }
    }
    let labelMetrics = PolicyCanvasEdgeLabelMetrics(fontScale: fontScale)
    let labelSize = CGSize(
      width: PolicyCanvasLayout.edgeLabelMaxWidth,
      height: labelMetrics.height
    )
    for edge in edges {
      guard !edge.label.isEmpty, let position = labelPositions[edge.id] else {
        continue
      }
      let frame = CGRect(
        x: position.x - (labelSize.width / 2),
        y: position.y - (labelSize.height / 2),
        width: labelSize.width,
        height: labelSize.height
      )
      bounds = bounds.isNull ? frame : bounds.union(frame)
    }
    guard !bounds.isNull else {
      return CGRect(origin: .zero, size: PolicyCanvasLayout.minimumCanvasSize)
    }
    return bounds
  }

  fileprivate func displayedRoutes(
    router: any PolicyCanvasEdgeRouter
  ) -> [String: PolicyCanvasEdgeRoute] {
    let portAnchors = portAnchors()
    let edgeLanes = laneAssignments(bucket: edgeRouteBucket, sortKey: edgeRouteSortKey)
    let sourceFanoutLanes = laneAssignments(
      bucket: edgeSourceFanoutBucket,
      sortKey: edgeSourceFanoutSortKey
    )
    let targetFanoutLanes = laneAssignments(
      bucket: edgeTargetFanoutBucket,
      sortKey: edgeTargetFanoutSortKey
    )
    var routes: [String: PolicyCanvasEdgeRoute] = [:]
    routes.reserveCapacity(edges.count)
    for edge in edges {
      guard let source = portAnchors[edge.source], let target = portAnchors[edge.target] else {
        continue
      }
      routes[edge.id] = displayedRoute(
        edge: edge,
        source: source,
        target: target,
        routeLane: edgeLanes[edge.id, default: 0],
        sourceFanoutLane: sourceFanoutLanes[edge.id, default: 0],
        targetFanoutLane: targetFanoutLanes[edge.id, default: 0],
        router: router
      )
    }
    return routes
  }

  fileprivate func resolvedLabelPositions(
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> [String: CGPoint] {
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: fontScale)
    return policyCanvasResolvedLabelPositions(
      routes: edges.compactMap { edge in
        guard !edge.label.isEmpty, let route = routes[edge.id] else {
          return nil
        }
        return (id: edge.id, route: route)
      },
      nodeFrames: nodes.map(\.frame),
      labelSize: CGSize(width: PolicyCanvasLayout.edgeLabelMaxWidth, height: metrics.height)
    )
  }

  private func displayedRoute(
    edge: PolicyCanvasEdge,
    source: CGPoint,
    target: CGPoint,
    routeLane: Int,
    sourceFanoutLane: Int,
    targetFanoutLane: Int,
    router: any PolicyCanvasEdgeRouter
  ) -> PolicyCanvasEdgeRoute {
    let nodeIndex = nodeIndex
    let context = PolicyCanvasRouteContext(
      lane: routeLane,
      groups: groups,
      sourceGroupID: nodeIndex[edge.source.nodeID]?.groupID,
      targetGroupID: nodeIndex[edge.target.nodeID]?.groupID,
      obstacles: routingObstacles(),
      sourceActual: source,
      targetActual: target,
      lineSpacing: edgeLineSpacing(for: edge)
    )
    if edge.effectivePinnedPortSide {
      return policyCanvasDisplayedRoute(
        PolicyCanvasPinnedDisplayedRouteRequest(
          router: router,
          source: (point: source, side: resolvedPortSide(for: edge.source)),
          sourceFanoutLane: sourceFanoutLane,
          target: (point: target, side: resolvedPortSide(for: edge.target)),
          targetFanoutLane: targetFanoutLane,
          context: context
        )
      )
    }
    return policyCanvasDisplayedRoute(
      PolicyCanvasFlexibleDisplayedRouteRequest(
        router: router,
        sourceCandidates: routeAnchorCandidates(for: edge.source),
        sourceFanoutLane: sourceFanoutLane,
        targetCandidates: routeAnchorCandidates(for: edge.target),
        targetFanoutLane: targetFanoutLane,
        context: context
      )
    )
  }

  private var nodeIndex: [String: PolicyCanvasRouteNode] {
    Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
  }

  private func routingObstacles() -> [CGRect] {
    nodes.map(\.frame) + groups.map(\.frame)
  }

  private func portAnchors() -> [PolicyCanvasPortEndpoint: CGPoint] {
    let nodeIndex = nodeIndex
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
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> CGPoint? {
    guard let node = nodeIndex[endpoint.nodeID] else {
      return nil
    }
    let ports = endpoint.kind == .input ? node.inputPorts : node.outputPorts
    guard let index = ports.firstIndex(where: { $0.id == endpoint.portID }) else {
      return nil
    }
    return portAnchor(
      for: node,
      side: endpoint.side ?? defaultPortSide(for: endpoint.kind),
      index: index,
      count: ports.count
    )
  }

  private func routeAnchorCandidates(
    for endpoint: PolicyCanvasPortEndpoint
  ) -> [PolicyCanvasRouteAnchorCandidate] {
    let points = portAnchorCandidates(for: endpoint)
    return zip(PolicyCanvasPortSide.allSides, points).map { side, point in
      (point: point, side: side)
    }
  }

  private func portAnchorCandidates(for endpoint: PolicyCanvasPortEndpoint) -> [CGPoint] {
    guard let node = nodeIndex[endpoint.nodeID] else {
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

  private func portAnchor(
    for node: PolicyCanvasRouteNode,
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

  private func laneAssignments(
    bucket: (PolicyCanvasEdge) -> String,
    sortKey: (PolicyCanvasEdge) -> String
  ) -> [String: Int] {
    let sortedEdges = edges.sorted { left, right in
      let leftKey = sortKey(left)
      let rightKey = sortKey(right)
      if leftKey != rightKey {
        return leftKey < rightKey
      }
      return left.id < right.id
    }
    var nextLaneByBucket: [String: Int] = [:]
    var lanes: [String: Int] = [:]
    for edge in sortedEdges {
      let edgeBucket = bucket(edge)
      let lane = nextLaneByBucket[edgeBucket, default: 0]
      lanes[edge.id] = lane
      nextLaneByBucket[edgeBucket] = lane + 1
    }
    return lanes
  }

  private func edgeLaneSortKey(_ edge: PolicyCanvasEdge) -> String {
    let targetY = portAnchor(for: edge.target, nodeIndex: nodeIndex)?.y ?? 0
    return
      "\(edgeRouteBucket(edge))|\(Int(targetY.rounded()))|\(edge.source.portID)|\(edge.target.portID)"
  }

  private func edgeRouteBucket(_ edge: PolicyCanvasEdge) -> String {
    "\(edgeSourceFanoutBucket(edge))->\(edgeTargetFanoutBucket(edge))"
  }

  private func edgeRouteSortKey(_ edge: PolicyCanvasEdge) -> String {
    edgeLaneSortKey(edge)
  }

  private func edgeSourceFanoutBucket(_ edge: PolicyCanvasEdge) -> String {
    let side = resolvedPortSide(for: edge.source).rawValue
    return "\(edge.source.nodeID)|\(edge.source.portID)|\(side)"
  }

  private func edgeTargetFanoutBucket(_ edge: PolicyCanvasEdge) -> String {
    let side = resolvedPortSide(for: edge.target).rawValue
    return "\(edge.target.nodeID)|\(edge.target.portID)|\(side)"
  }

  private func edgeSourceFanoutSortKey(_ edge: PolicyCanvasEdge) -> String {
    fanoutSortKey(
      bucket: edgeSourceFanoutBucket(edge),
      anchor: portAnchor(for: edge.target, nodeIndex: nodeIndex) ?? .zero,
      nodeID: edge.target.nodeID,
      portID: edge.target.portID
    )
  }

  private func edgeTargetFanoutSortKey(_ edge: PolicyCanvasEdge) -> String {
    fanoutSortKey(
      bucket: edgeTargetFanoutBucket(edge),
      anchor: portAnchor(for: edge.source, nodeIndex: nodeIndex) ?? .zero,
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
    [bucket, String(Int(anchor.y.rounded())), String(Int(anchor.x.rounded())), nodeID, portID]
      .joined(separator: "|")
  }

  private func edgeLineSpacing(for edge: PolicyCanvasEdge) -> CGFloat {
    max(portSpacing(for: edge.source), portSpacing(for: edge.target))
  }

  private func portSpacing(for endpoint: PolicyCanvasPortEndpoint) -> CGFloat {
    guard let node = nodeIndex[endpoint.nodeID] else {
      return PolicyCanvasLayout.defaultEdgeLineSpacing
    }
    let ports = endpoint.kind == .input ? node.inputPorts : node.outputPorts
    guard ports.count > 1 else {
      return PolicyCanvasLayout.defaultEdgeLineSpacing
    }
    let side = resolvedPortSide(for: endpoint)
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

  private func defaultPortSide(for kind: PolicyCanvasPortKind) -> PolicyCanvasPortSide {
    kind == .input ? .leading : .trailing
  }
}

struct PolicyCanvasRouteWorkerOutput: Equatable, Sendable {
  let routes: [String: PolicyCanvasEdgeRoute]
  let labelPositions: [String: CGPoint]
  let visibleBounds: CGRect
  let contentSize: CGSize

  static let empty = Self(
    routes: [:],
    labelPositions: [:],
    visibleBounds: CGRect(origin: .zero, size: PolicyCanvasLayout.minimumCanvasSize),
    contentSize: PolicyCanvasLayout.minimumCanvasSize
  )

  static func fallback(for input: PolicyCanvasRouteWorkerInput) -> Self {
    let visibleBounds = input.contentBounds
    return Self(
      routes: [:],
      labelPositions: [:],
      visibleBounds: visibleBounds,
      contentSize: policyCanvasVisibleContentSize(visibleBounds: visibleBounds)
    )
  }
}

private struct PolicyCanvasRouteNode: Equatable, Sendable {
  let id: String
  let position: CGPoint
  let groupID: String?
  let inputPorts: [PolicyCanvasPort]
  let outputPorts: [PolicyCanvasPort]

  init(node: PolicyCanvasNode) {
    id = node.id
    position = node.position
    groupID = node.groupID
    inputPorts = node.inputPorts
    outputPorts = node.outputPorts
  }

  var frame: CGRect {
    CGRect(origin: position, size: PolicyCanvasLayout.nodeSize)
  }
}
