import SwiftUI

public struct PolicyCanvasRouteWorkerInput: Equatable, Sendable {
  // Generation counter from the view model. Bumped on every input-changing
  // mutation (node/edge/group add/remove, drag end, etc.) via
  // `invalidateValidationCache`. Placed first so synthesized Equatable
  // short-circuits on this O(1) comparison before falling through to the
  // O(N) array checks below. Default 0 keeps test fixtures comparing by
  // array equality only.
  public let graphGeneration: UInt64
  public let nodes: [PolicyCanvasNode]
  public let groups: [PolicyCanvasGroup]
  public let edges: [PolicyCanvasEdge]
  public let fontScale: CGFloat
  public let routingHints: PolicyCanvasLayoutRoutingHints?
  public let algorithmSelection: PolicyCanvasAlgorithmSelection

  public init(
    graphGeneration: UInt64 = 0,
    nodes: [PolicyCanvasNode],
    groups: [PolicyCanvasGroup],
    edges: [PolicyCanvasEdge],
    fontScale: CGFloat,
    routingHints: PolicyCanvasLayoutRoutingHints? = nil,
    algorithmSelection: PolicyCanvasAlgorithmSelection = .referenceRouting
  ) {
    self.graphGeneration = graphGeneration
    self.nodes = nodes
    self.groups = groups
    self.edges = edges
    self.fontScale = fontScale
    self.routingHints = routingHints
    self.algorithmSelection = algorithmSelection
  }
}

public struct PolicyCanvasPreparedRouteInput: Equatable, Sendable {
  public let nodes: [PolicyCanvasRouteNode]
  public let groups: [PolicyCanvasGroup]
  public let edges: [PolicyCanvasEdge]
  public let fontScale: CGFloat
  public let routingHints: PolicyCanvasLayoutRoutingHints?

  public init(input: PolicyCanvasRouteWorkerInput) {
    nodes = input.nodes.map(PolicyCanvasRouteNode.init(node:))
    groups = input.groups
    edges = input.edges
    fontScale = input.fontScale
    routingHints = input.routingHints
  }

  public var contentBounds: CGRect {
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

  public func visibleBounds(
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
    for edge in edges {
      guard !edge.label.isEmpty, let position = labelPositions[edge.id] else {
        continue
      }
      let frame = labelMetrics.frame(for: edge.label, center: position)
      bounds = bounds.isNull ? frame : bounds.union(frame)
    }
    guard !bounds.isNull else {
      return CGRect(origin: .zero, size: PolicyCanvasLayout.minimumCanvasSize)
    }
    return bounds
  }

  public func resolvedLabelPositions(
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> [String: CGPoint] {
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: fontScale)
    let routeFrames = policyCanvasRouteFrames(routes.map { (id: $0.key, route: $0.value) })
    let labelledRoutes: [PolicyCanvasLabelPlacementRoute] = edges.compactMap { edge in
      guard !edge.label.isEmpty, let route = routes[edge.id] else {
        return nil
      }
      return PolicyCanvasLabelPlacementRoute(
        id: edge.id,
        label: edge.label,
        route: route,
        size: metrics.size(for: edge.label)
      )
    }
    return policyCanvasResolvedLabelPositions(
      routes: labelledRoutes,
      nodeFrames: nodes.map(\.frame) + policyCanvasGroupTitleFrames(groups),
      routeFrames: routeFrames
    )
  }

  public var nodeIndex: [String: PolicyCanvasRouteNode] {
    Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
  }

  public func fallbackRoutes(nodeIndex: [String: PolicyCanvasRouteNode]) -> [String: PolicyCanvasEdgeRoute] {
    let portAnchors = portAnchors(nodeIndex: nodeIndex)
    let orderedEdges = policyCanvasRouteBuildOrder(edges: edges, portAnchors: portAnchors)
    let edgeLanes = policyCanvasSharedTargetRouteLaneAssignments(
      edges: edges,
      bucket: { edgeRouteBucket($0, nodeIndex: nodeIndex) },
      sortKey: { edgeRouteSortKey($0, nodeIndex: nodeIndex) }
    )
    var routes: [String: PolicyCanvasEdgeRoute] = [:]
    routes.reserveCapacity(edges.count)
    for edge in orderedEdges {
      guard let source = portAnchors[edge.source], let target = portAnchors[edge.target] else {
        continue
      }
      routes[edge.id] = PolicyCanvasEdgeRoute(
        source: source,
        target: target,
        lane: edgeLanes[edge.id, default: 0],
        groups: groups,
        sourceGroupID: nodeIndex[edge.source.nodeID]?.groupID,
        targetGroupID: nodeIndex[edge.target.nodeID]?.groupID
      )
    }
    return routes
  }
}

public struct PolicyCanvasRouteNode: Equatable, Sendable {
  public let id: String
  public let title: String
  public let accessibilityLabel: String
  public let position: CGPoint
  public let groupID: String?
  public let inputPorts: [PolicyCanvasPort]
  public let outputPorts: [PolicyCanvasPort]

  public init(node: PolicyCanvasNode) {
    id = node.id
    title = node.title
    accessibilityLabel = "\(node.kind.title) \(node.title)"
    position = node.position
    groupID = node.groupID
    inputPorts = node.inputPorts
    outputPorts = node.outputPorts
  }

  public var frame: CGRect {
    CGRect(origin: position, size: PolicyCanvasLayout.nodeSize)
  }
}
