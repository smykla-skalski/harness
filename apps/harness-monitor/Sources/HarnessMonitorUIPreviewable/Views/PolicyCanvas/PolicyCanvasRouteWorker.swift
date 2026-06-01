import OSLog
import SwiftUI

actor PolicyCanvasRouteWorker {
  static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "policy-canvas.perf"
  )

  let router: any PolicyCanvasEdgeRouter
  var cachedInput: PolicyCanvasRouteWorkerInput?
  var cachedOutput: PolicyCanvasRouteWorkerOutput = .empty

  init(
    router: any PolicyCanvasEdgeRouter = PolicyCanvasMemoizedRouter(
      inner: PolicyCanvasVisibilityRouter()
    )
  ) {
    self.router = router
  }

  func compute(input: PolicyCanvasRouteWorkerInput) -> PolicyCanvasRouteWorkerOutput {
    guard input != cachedInput else {
      return cachedOutput
    }
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
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

    let nodeIndex = prepared.nodeIndex
    let initialRoutes = prepared.displayedRoutes(router: router)
    var portMarkerLayout = prepared.portMarkerLayout(
      routes: initialRoutes,
      nodeIndex: nodeIndex
    )
    var routes = initialRoutes
    var converged = false
    var oscillationDetected = false
    var seenLayouts: [PolicyCanvasPortMarkerLayout] = [portMarkerLayout]
    for _ in 0..<3 {
      routes = prepared.displayedRoutes(
        router: router,
        portMarkerLayout: portMarkerLayout
      )
      let nextPortMarkerLayout = prepared.portMarkerLayout(
        routes: routes,
        nodeIndex: nodeIndex
      )
      if nextPortMarkerLayout == portMarkerLayout {
        converged = true
        break
      }
      if seenLayouts.contains(nextPortMarkerLayout) {
        // Oscillation: nextLayout matches a state we already saw. Stop and
        // pin nextLayout as the canonical resting place so subsequent
        // compute() calls reach the same fixed point instead of flipping
        // between two layouts across frames.
        oscillationDetected = true
        portMarkerLayout = nextPortMarkerLayout
        break
      }
      seenLayouts.append(nextPortMarkerLayout)
      portMarkerLayout = nextPortMarkerLayout
    }
    if !converged {
      // Oscillation or exhaustion: re-route once against the chosen layout
      // so routes and portMarkerLayout agree. On oscillation we already
      // selected a deterministic resting place; this pass makes the
      // visible routes consistent with it.
      _ = oscillationDetected
      routes = prepared.displayedRoutes(router: router, portMarkerLayout: portMarkerLayout)
    }
    // Final post-process: declutter vertical descents so a through-bus does not
    // skim a shared node. Applied once on the converged routes (not inside the
    // marker-convergence loop, whose layout reads only the untouched port
    // attach points) so the worker and the displayed-route helper stay in sync.
    routes = policyCanvasVerticalDescentDeclutteredRoutes(
      routes, edges: prepared.edges, nodeFrames: prepared.nodes.map(\.frame))
    // Then nest any genuine multi-source fan-in (>=3 sources into one bottom port)
    // into a clean staircase: the sequential router cannot order the whole fan, so
    // its rails turn at inconsistent heights and cross. This rewrites them once
    // with the full family in hand.
    routes = policyCanvasNestedFanInRoutes(routes, edges: prepared.edges)
    let labelPositions = prepared.resolvedLabelPositions(routes: routes)
    let visibleBounds = prepared.visibleBounds(
      routes: routes,
      labelPositions: labelPositions
    )
    let portVisibility = prepared.portVisibility(routes: routes, nodeIndex: nodeIndex)
    let accessibilityEdgeEntries = prepared.accessibilityEdgeEntries(nodeIndex: nodeIndex)
    let nodeAccessibilityValuesByID = prepared.nodeAccessibilityValuesByID(nodeIndex: nodeIndex)
    let accessibilityNodeEntries = prepared.accessibilityNodeEntries()
    let connectTargetsByNodeID = prepared.connectTargetsByNodeID()
    let contentSize = policyCanvasVisibleContentSize(visibleBounds: visibleBounds)
    cachedInput = input
    cachedOutput = PolicyCanvasRouteWorkerOutput(
      routes: routes,
      labelPositions: labelPositions,
      portVisibility: portVisibility,
      portMarkerLayout: portMarkerLayout,
      visibleBounds: visibleBounds,
      contentSize: contentSize,
      accessibilityEdgeLabelsByID: Self.edgeLabelsByID(accessibilityEdgeEntries),
      accessibilityNodeEntries: accessibilityNodeEntries,
      accessibilityEdgeEntries: accessibilityEdgeEntries,
      nodeAccessibilityValuesByID: nodeAccessibilityValuesByID,
      connectTargetsByNodeID: connectTargetsByNodeID
    )
    return cachedOutput
  }

  func waitForIdle() async {}

  static func edgeLabelsByID(
    _ entries: [PolicyCanvasAccessibilityEdgeEntry]
  ) -> [String: String] {
    Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.label) })
  }
}

struct PolicyCanvasRouteWorkerKey: Equatable {
  let graphGeneration: UInt64
  let nodeCount: Int
  let groupCount: Int
  let edgeCount: Int
  let fontScale: CGFloat
  let routingHints: PolicyCanvasLayoutRoutingHints?
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

  init(
    graphGeneration: UInt64 = 0,
    nodes: [PolicyCanvasNode],
    groups: [PolicyCanvasGroup],
    edges: [PolicyCanvasEdge],
    fontScale: CGFloat,
    routingHints: PolicyCanvasLayoutRoutingHints? = nil
  ) {
    self.graphGeneration = graphGeneration
    self.nodes = nodes
    self.groups = groups
    self.edges = edges
    self.fontScale = fontScale
    self.routingHints = routingHints
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

func policyCanvasNodePositionsByID(_ nodes: [PolicyCanvasNode]) -> [String: CGPoint] {
  Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position) })
}

func policyCanvasProjectedRouteOutput(
  cachedOutput: PolicyCanvasRouteWorkerOutput,
  cachedNodePositionsByID: [String: CGPoint],
  currentNodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup],
  edges: [PolicyCanvasEdge],
  fontScale: CGFloat
) -> PolicyCanvasRouteWorkerOutput {
  guard !cachedOutput.routes.isEmpty, !cachedNodePositionsByID.isEmpty else {
    return cachedOutput
  }

  var movedNodeDeltas: [String: CGSize] = [:]
  movedNodeDeltas.reserveCapacity(currentNodes.count)
  for node in currentNodes {
    guard let cachedPosition = cachedNodePositionsByID[node.id] else {
      continue
    }
    let delta = CGSize(
      width: node.position.x - cachedPosition.x,
      height: node.position.y - cachedPosition.y
    )
    if delta != .zero {
      movedNodeDeltas[node.id] = delta
    }
  }
  guard !movedNodeDeltas.isEmpty else {
    return cachedOutput
  }

  let currentNodesByID = Dictionary(uniqueKeysWithValues: currentNodes.map { ($0.id, $0) })
  var routes = cachedOutput.routes
  var labelPositions = cachedOutput.labelPositions
  var didProjectRoute = false
  for edge in edges {
    let sourceDelta = movedNodeDeltas[edge.source.nodeID] ?? .zero
    let targetDelta = movedNodeDeltas[edge.target.nodeID] ?? .zero
    guard sourceDelta != .zero || targetDelta != .zero,
      let route = routes[edge.id]
    else {
      continue
    }
    let projectedRoute = policyCanvasProjectedRoute(
      route,
      edge: edge,
      sourceDelta: sourceDelta,
      targetDelta: targetDelta,
      currentNodesByID: currentNodesByID,
      groups: groups
    )
    guard projectedRoute != route else {
      continue
    }
    routes[edge.id] = projectedRoute
    if labelPositions[edge.id] != nil {
      labelPositions[edge.id] = projectedRoute.labelPosition
    }
    didProjectRoute = true
  }
  guard didProjectRoute else {
    return cachedOutput
  }

  let prepared = PolicyCanvasPreparedRouteInput(
    input: PolicyCanvasRouteWorkerInput(
      nodes: currentNodes,
      groups: groups,
      edges: edges,
      fontScale: fontScale
    )
  )
  let visibleBounds = prepared.visibleBounds(routes: routes, labelPositions: labelPositions)
  let contentSize = policyCanvasVisibleContentSize(visibleBounds: visibleBounds)
  return PolicyCanvasRouteWorkerOutput(
    routes: routes,
    labelPositions: labelPositions,
    portVisibility: cachedOutput.portVisibility,
    portMarkerLayout: cachedOutput.portMarkerLayout,
    visibleBounds: visibleBounds,
    contentSize: contentSize,
    accessibilityEdgeLabelsByID: cachedOutput.accessibilityEdgeLabelsByID,
    accessibilityNodeEntries: cachedOutput.accessibilityNodeEntries,
    accessibilityEdgeEntries: cachedOutput.accessibilityEdgeEntries,
    nodeAccessibilityValuesByID: cachedOutput.nodeAccessibilityValuesByID,
    connectTargetsByNodeID: cachedOutput.connectTargetsByNodeID
  )
}

private func policyCanvasProjectedRoute(
  _ route: PolicyCanvasEdgeRoute,
  edge: PolicyCanvasEdge,
  sourceDelta: CGSize,
  targetDelta: CGSize,
  currentNodesByID: [String: PolicyCanvasNode],
  groups: [PolicyCanvasGroup]
) -> PolicyCanvasEdgeRoute {
  guard let source = route.points.first, let target = route.points.last else {
    return route
  }
  if sourceDelta == targetDelta {
    return PolicyCanvasEdgeRoute(
      points: route.points.map { policyCanvasTranslatedPoint($0, by: sourceDelta) },
      labelPosition: policyCanvasTranslatedPoint(route.labelPosition, by: sourceDelta)
    )
  }
  return PolicyCanvasEdgeRoute(
    source: policyCanvasTranslatedPoint(source, by: sourceDelta),
    target: policyCanvasTranslatedPoint(target, by: targetDelta),
    lane: 0,
    groups: groups,
    sourceGroupID: currentNodesByID[edge.source.nodeID]?.groupID,
    targetGroupID: currentNodesByID[edge.target.nodeID]?.groupID
  )
}

private func policyCanvasTranslatedPoint(_ point: CGPoint, by delta: CGSize) -> CGPoint {
  CGPoint(x: point.x + delta.width, y: point.y + delta.height)
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
