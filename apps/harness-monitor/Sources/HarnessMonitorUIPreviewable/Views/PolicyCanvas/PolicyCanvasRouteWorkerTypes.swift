import SwiftUI

struct PolicyCanvasRouteWorkerKey: Equatable {
  let graphGeneration: UInt64
  let nodeCount: Int
  let groupCount: Int
  let edgeCount: Int
  let fontScale: CGFloat
  let routingHints: PolicyCanvasLayoutRoutingHints?
  let algorithmSelection: PolicyCanvasAlgorithmSelection

  init(
    graphGeneration: UInt64,
    nodeCount: Int,
    groupCount: Int,
    edgeCount: Int,
    fontScale: CGFloat,
    routingHints: PolicyCanvasLayoutRoutingHints?,
    algorithmSelection: PolicyCanvasAlgorithmSelection = .harnessCurrent
  ) {
    self.graphGeneration = graphGeneration
    self.nodeCount = nodeCount
    self.groupCount = groupCount
    self.edgeCount = edgeCount
    self.fontScale = fontScale
    self.routingHints = routingHints
    self.algorithmSelection = algorithmSelection
  }
}

struct PolicyCanvasRouteWorkerInput: Equatable, Sendable {
  // Generation counter from the view model. Bumped on every input-changing
  // mutation (node/edge/group add/remove, drag end, etc.) via
  // `invalidateValidationCache`. Placed first so synthesized Equatable
  // short-circuits on this O(1) comparison before falling through to the
  // O(N) array checks below. Default 0 keeps test fixtures comparing by
  // array equality only.
  let graphGeneration: UInt64
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let fontScale: CGFloat
  let routingHints: PolicyCanvasLayoutRoutingHints?
  let algorithmSelection: PolicyCanvasAlgorithmSelection

  init(
    graphGeneration: UInt64 = 0,
    nodes: [PolicyCanvasNode],
    groups: [PolicyCanvasGroup],
    edges: [PolicyCanvasEdge],
    fontScale: CGFloat,
    routingHints: PolicyCanvasLayoutRoutingHints? = nil,
    algorithmSelection: PolicyCanvasAlgorithmSelection = .harnessCurrent
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

struct PolicyCanvasPreparedRouteInput: Equatable, Sendable {
  let nodes: [PolicyCanvasRouteNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let fontScale: CGFloat
  let routingHints: PolicyCanvasLayoutRoutingHints?

  init(input: PolicyCanvasRouteWorkerInput) {
    nodes = input.nodes.map(PolicyCanvasRouteNode.init(node:))
    groups = input.groups
    edges = input.edges
    fontScale = input.fontScale
    routingHints = input.routingHints
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

  func resolvedLabelPositions(
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

  var nodeIndex: [String: PolicyCanvasRouteNode] {
    Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
  }
}

struct PolicyCanvasRouteWorkerOutput: Equatable, Sendable {
  let signature: PolicyCanvasRouteWorkerOutputSignature
  let routes: [String: PolicyCanvasEdgeRoute]
  let labelPositions: [String: CGPoint]
  let portVisibility: PolicyCanvasPortVisibilityMap
  let portMarkerLayout: PolicyCanvasPortMarkerLayout
  let visibleBounds: CGRect
  let contentSize: CGSize
  let accessibilityEdgeLabelsByID: [String: String]
  let accessibilityNodeEntries: [PolicyCanvasAccessibilityNodeEntry]
  let accessibilityEdgeEntries: [PolicyCanvasAccessibilityEdgeEntry]
  let nodeAccessibilityValuesByID: [String: String]
  let connectTargetsByNodeID: [String: [PolicyCanvasAccessibilityConnectTarget]]

  static let empty = Self(
    signature: .empty,
    routes: [:],
    labelPositions: [:],
    portVisibility: [:],
    portMarkerLayout: .empty,
    visibleBounds: CGRect(origin: .zero, size: PolicyCanvasLayout.minimumCanvasSize),
    contentSize: PolicyCanvasLayout.minimumCanvasSize,
    accessibilityEdgeLabelsByID: [:],
    accessibilityNodeEntries: [],
    accessibilityEdgeEntries: [],
    nodeAccessibilityValuesByID: [:],
    connectTargetsByNodeID: [:]
  )

  static func fallback(for input: PolicyCanvasRouteWorkerInput) -> Self {
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let visibleBounds = prepared.contentBounds
    let nodeIndex = prepared.nodeIndex
    let accessibilityEdgeEntries = prepared.accessibilityEdgeEntries(nodeIndex: nodeIndex)
    let nodeAccessibilityValuesByID = prepared.nodeAccessibilityValuesByID(nodeIndex: nodeIndex)
    let accessibilityNodeEntries = prepared.accessibilityNodeEntries()
    let connectTargetsByNodeID = prepared.connectTargetsByNodeID()
    let contentSize = policyCanvasVisibleContentSize(visibleBounds: visibleBounds)
    return Self(
      signature: PolicyCanvasRouteWorkerOutputSignature(
        routes: [:],
        labelPositions: [:],
        portVisibility: [:],
        visibleBounds: visibleBounds,
        contentSize: contentSize,
        accessibilityNodeEntries: accessibilityNodeEntries,
        accessibilityEdgeEntries: accessibilityEdgeEntries,
        nodeAccessibilityValuesByID: nodeAccessibilityValuesByID,
        connectTargetsByNodeID: connectTargetsByNodeID
      ),
      routes: [:],
      labelPositions: [:],
      portVisibility: [:],
      portMarkerLayout: .empty,
      visibleBounds: visibleBounds,
      contentSize: contentSize,
      accessibilityEdgeLabelsByID: Dictionary(
        uniqueKeysWithValues: accessibilityEdgeEntries.map { ($0.id, $0.label) }
      ),
      accessibilityNodeEntries: accessibilityNodeEntries,
      accessibilityEdgeEntries: accessibilityEdgeEntries,
      nodeAccessibilityValuesByID: nodeAccessibilityValuesByID,
      connectTargetsByNodeID: connectTargetsByNodeID
    )
  }

  init(
    signature: PolicyCanvasRouteWorkerOutputSignature,
    routes: [String: PolicyCanvasEdgeRoute],
    labelPositions: [String: CGPoint],
    portVisibility: PolicyCanvasPortVisibilityMap,
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    visibleBounds: CGRect,
    contentSize: CGSize,
    accessibilityEdgeLabelsByID: [String: String],
    accessibilityNodeEntries: [PolicyCanvasAccessibilityNodeEntry],
    accessibilityEdgeEntries: [PolicyCanvasAccessibilityEdgeEntry],
    nodeAccessibilityValuesByID: [String: String],
    connectTargetsByNodeID: [String: [PolicyCanvasAccessibilityConnectTarget]]
  ) {
    self.signature = signature
    self.routes = routes
    self.labelPositions = labelPositions
    self.portVisibility = portVisibility
    self.portMarkerLayout = portMarkerLayout
    self.visibleBounds = visibleBounds
    self.contentSize = contentSize
    self.accessibilityEdgeLabelsByID = accessibilityEdgeLabelsByID
    self.accessibilityNodeEntries = accessibilityNodeEntries
    self.accessibilityEdgeEntries = accessibilityEdgeEntries
    self.nodeAccessibilityValuesByID = nodeAccessibilityValuesByID
    self.connectTargetsByNodeID = connectTargetsByNodeID
  }

  init(
    routes: [String: PolicyCanvasEdgeRoute],
    labelPositions: [String: CGPoint],
    portVisibility: PolicyCanvasPortVisibilityMap,
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    visibleBounds: CGRect,
    contentSize: CGSize,
    accessibilityEdgeLabelsByID: [String: String],
    accessibilityNodeEntries: [PolicyCanvasAccessibilityNodeEntry],
    accessibilityEdgeEntries: [PolicyCanvasAccessibilityEdgeEntry],
    nodeAccessibilityValuesByID: [String: String],
    connectTargetsByNodeID: [String: [PolicyCanvasAccessibilityConnectTarget]]
  ) {
    self.init(
      signature: PolicyCanvasRouteWorkerOutputSignature(
        routes: routes,
        labelPositions: labelPositions,
        portVisibility: portVisibility,
        visibleBounds: visibleBounds,
        contentSize: contentSize,
        accessibilityNodeEntries: accessibilityNodeEntries,
        accessibilityEdgeEntries: accessibilityEdgeEntries,
        nodeAccessibilityValuesByID: nodeAccessibilityValuesByID,
        connectTargetsByNodeID: connectTargetsByNodeID
      ),
      routes: routes,
      labelPositions: labelPositions,
      portVisibility: portVisibility,
      portMarkerLayout: portMarkerLayout,
      visibleBounds: visibleBounds,
      contentSize: contentSize,
      accessibilityEdgeLabelsByID: accessibilityEdgeLabelsByID,
      accessibilityNodeEntries: accessibilityNodeEntries,
      accessibilityEdgeEntries: accessibilityEdgeEntries,
      nodeAccessibilityValuesByID: nodeAccessibilityValuesByID,
      connectTargetsByNodeID: connectTargetsByNodeID
    )
  }
}

struct PolicyCanvasAccessibilityNodeEntry: Equatable, Sendable, Identifiable {
  let id: String
  let label: String
}

struct PolicyCanvasAccessibilityEdgeEntry: Equatable, Sendable, Identifiable {
  let id: String
  let label: String
}

struct PolicyCanvasRouteNode: Equatable, Sendable {
  let id: String
  let title: String
  let accessibilityLabel: String
  let position: CGPoint
  let groupID: String?
  let inputPorts: [PolicyCanvasPort]
  let outputPorts: [PolicyCanvasPort]

  init(node: PolicyCanvasNode) {
    id = node.id
    title = node.title
    accessibilityLabel = "\(node.kind.title) \(node.title)"
    position = node.position
    groupID = node.groupID
    inputPorts = node.inputPorts
    outputPorts = node.outputPorts
  }

  var frame: CGRect {
    CGRect(origin: position, size: PolicyCanvasLayout.nodeSize)
  }
}
