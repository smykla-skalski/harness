import OSLog
import SwiftUI

private let policyCanvasLayoutSignposter = OSSignposter(
  subsystem: "io.harnessmonitor",
  category: "policy-canvas.perf"
)

/// Automatic-layout helpers + overlap detection used by
/// `policyCanvasCleanInitialLayout(nodes:groups:edges:)`. ELK owns default
/// placement; these helpers decide when a persisted arrangement is trustworthy
/// and normalize the final canvas bounds.

public struct PolicyCanvasNormalizedLayout {
  public let nodes: [PolicyCanvasNode]
  public let groups: [PolicyCanvasGroup]
  public let routingHints: PolicyCanvasLayoutRoutingHints?
}

public struct PolicyCanvasCleanLayout {
  public let nodes: [PolicyCanvasNode]
  public let groups: [PolicyCanvasGroup]
  public let metrics: PolicyCanvasLayoutMetrics?
  public let routingHints: PolicyCanvasLayoutRoutingHints?
  public let precomputedRoutes: PolicyCanvasPrecomputedRouteSet?

  public init(
    nodes: [PolicyCanvasNode],
    groups: [PolicyCanvasGroup],
    metrics: PolicyCanvasLayoutMetrics?,
    routingHints: PolicyCanvasLayoutRoutingHints?,
    precomputedRoutes: PolicyCanvasPrecomputedRouteSet? = nil
  ) {
    self.nodes = nodes
    self.groups = groups
    self.metrics = metrics
    self.routingHints = routingHints
    self.precomputedRoutes = precomputedRoutes
  }
}

/// Return value of `applyDefaultPolicyCanvasLayout`. Property names match the
/// tuple labels they replace so all call sites compile without change.
public struct PolicyCanvasAppliedDefaultLayout {
  public let metrics: PolicyCanvasLayoutMetrics?
  public let routingHints: PolicyCanvasLayoutRoutingHints?
  public let precomputedRoutes: PolicyCanvasPrecomputedRouteSet?
}

public func policyCanvasNeedsDefaultArrangement(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup]
) -> Bool {
  policyCanvasAnyGroupOverlap(groups)
    || policyCanvasAnyNodeOverlap(nodes)
    || policyCanvasAnyNodeOutsideAssignedGroup(nodes: nodes, groups: groups)
}

public func policyCanvasAutomaticLayoutResult(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup],
  edges: [PolicyCanvasEdge],
  mode: PolicyCanvasAutomaticLayoutMode = .initialLoad
) -> PolicyCanvasLayoutResult? {
  let signpostID = policyCanvasLayoutSignposter.makeSignpostID()
  let interval = policyCanvasLayoutSignposter.beginInterval(
    "policy_canvas.layout.compute",
    id: signpostID,
    "nodes=\(nodes.count) edges=\(edges.count) groups=\(groups.count)"
  )
  defer {
    policyCanvasLayoutSignposter.endInterval(
      "policy_canvas.layout.compute",
      interval
    )
  }
  if let elkResult = policyCanvasElkLayoutResult(
    nodes: nodes,
    groups: groups,
    edges: edges,
    mode: mode
  ) {
    return elkResult
  }
  let graph = policyCanvasLayoutGraph(
    nodes: nodes,
    groups: groups,
    edges: edges,
    mode: mode
  )
  return PolicyCanvasLayeredLayoutEngine(mode: mode).layout(graph: graph)
}

public func applyPolicyCanvasLayoutResult(
  _ result: PolicyCanvasLayoutResult,
  nodes: inout [PolicyCanvasNode],
  groups: inout [PolicyCanvasGroup],
  centerInMinimumCanvas: Bool
) -> PolicyCanvasLayoutRoutingHints? {
  let groupsByID = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($1.id, $0) })
  for index in nodes.indices {
    guard let position = result.nodePositions[nodes[index].id] else {
      continue
    }
    if result.autoPlacedNodeIDs.contains(nodes[index].id) {
      // Automatic layout can land an auto-placed node on a fractional coordinate.
      // Snap auto placements to whole pixels so saved layouts round-trip exactly
      // and sub-pixel group-frame drift does not trip the tidiness gate. Manual
      // anchors keep their exact authored position.
      nodes[index].position = CGPoint(x: position.x.rounded(), y: position.y.rounded())
      nodes[index].layoutSource = .auto
    } else {
      nodes[index].position = position
    }
  }
  for (groupID, frame) in result.groupFrames {
    guard let groupIndex = groupsByID[groupID] else {
      continue
    }
    groups[groupIndex].frame = frame
  }
  var routingHints = result.routingHints
  if centerInMinimumCanvas {
    let translation = policyCanvasCenterInMinimumCanvas(nodes: &nodes, groups: &groups)
    routingHints = routingHints?.offsetBy(dx: translation.width, dy: translation.height)
  }
  return routingHints
}

@discardableResult
public func applyDefaultPolicyCanvasLayout(
  nodes: inout [PolicyCanvasNode],
  groups: inout [PolicyCanvasGroup],
  edges: [PolicyCanvasEdge],
  mode: PolicyCanvasAutomaticLayoutMode = .initialLoad
) -> PolicyCanvasAppliedDefaultLayout {
  guard
    let result = policyCanvasAutomaticLayoutResult(
      nodes: nodes,
      groups: groups,
      edges: edges,
      mode: mode
    )
  else {
    return PolicyCanvasAppliedDefaultLayout(
      metrics: nil, routingHints: nil, precomputedRoutes: nil
    )
  }
  let routingHints = applyPolicyCanvasLayoutResult(
    result,
    nodes: &nodes,
    groups: &groups,
    centerInMinimumCanvas: mode.centersInMinimumCanvas
  )
  let precomputedRoutes = policyCanvasAppliedPrecomputedRoutes(
    result: result,
    nodes: nodes,
    edges: edges
  )
  return PolicyCanvasAppliedDefaultLayout(
    metrics: result.metrics,
    routingHints: routingHints,
    precomputedRoutes: precomputedRoutes
  )
}

public func policyCanvasAppliedPrecomputedRoutes(
  result: PolicyCanvasLayoutResult,
  nodes: [PolicyCanvasNode],
  edges: [PolicyCanvasEdge]
) -> PolicyCanvasPrecomputedRouteSet? {
  guard let precomputedRoutes = result.precomputedRoutes else {
    return nil
  }
  let appliedPositions = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position) })
  let offsetRoutes: PolicyCanvasPrecomputedRouteSet
  if let nodeID = result.nodePositions.keys.min(),
    let position = result.nodePositions[nodeID],
    let applied = appliedPositions[nodeID]
  {
    offsetRoutes = precomputedRoutes.offsetBy(
      dx: applied.x - position.x,
      dy: applied.y - position.y
    )
  } else {
    offsetRoutes = precomputedRoutes
  }
  guard
    policyCanvasPrecomputedRouteTerminalsAttach(
      precomputedRoutes: offsetRoutes,
      nodes: nodes,
      edges: edges
    )
  else {
    return nil
  }
  return offsetRoutes
}

/// Derive routing metadata from the layout that is already on the canvas.
///
/// Route hints are a pure function of node/group positions and displayed edges;
/// they should not be a second persisted source of truth. Use this when loading
/// trusted saved coordinates or when a no-op reformat needs to refresh route
/// geometry without moving nodes.
public func policyCanvasRoutingHintsForCurrentLayout(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup],
  edges: [PolicyCanvasEdge]
) -> PolicyCanvasLayoutRoutingHints? {
  guard !nodes.isEmpty, !edges.isEmpty else {
    return nil
  }
  let graph = policyCanvasLayoutGraph(
    nodes: nodes,
    groups: groups,
    edges: edges,
    mode: .initialLoad
  )
  let normalizedGroups = PolicyCanvasLayeredLayoutEngine().normalizedGroups(for: graph)
  let layoutGroupIDByNodeID = Dictionary(
    uniqueKeysWithValues: normalizedGroups.flatMap { group in
      group.nodeIDs.map { ($0, group.layoutID) }
    }
  )
  let nodePositions = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position) })
  let groupFramesByLayoutID = policyCanvasRebuiltGroupFramesByLayoutID(
    normalizedGroups: normalizedGroups,
    layoutGroupIDByNodeID: layoutGroupIDByNodeID,
    nodePositions: nodePositions
  )
  return policyCanvasLayoutRoutingHints(
    graph: graph,
    nodePositions: nodePositions,
    layoutGroupIDByNodeID: layoutGroupIDByNodeID,
    groupFramesByLayoutID: groupFramesByLayoutID
  )
}

public func policyCanvasNormalizeMinimumOrigin(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup],
  routingHints: PolicyCanvasLayoutRoutingHints? = nil
) -> PolicyCanvasNormalizedLayout {
  let bounds = policyCanvasBounds(nodes: nodes, groups: groups)
  guard !bounds.isNull else {
    return PolicyCanvasNormalizedLayout(nodes: nodes, groups: groups, routingHints: routingHints)
  }
  let dx = max(0, PolicyCanvasLayout.initialContentOrigin.x - bounds.minX)
  let dy = max(0, PolicyCanvasLayout.initialContentOrigin.y - bounds.minY)
  guard dx > 0 || dy > 0 else {
    return PolicyCanvasNormalizedLayout(nodes: nodes, groups: groups, routingHints: routingHints)
  }
  var normalizedNodes = nodes
  var normalizedGroups = groups
  for index in normalizedNodes.indices {
    normalizedNodes[index].position.x += dx
    normalizedNodes[index].position.y += dy
  }
  for index in normalizedGroups.indices {
    normalizedGroups[index].frame = normalizedGroups[index].frame.offsetBy(dx: dx, dy: dy)
  }
  return PolicyCanvasNormalizedLayout(
    nodes: normalizedNodes,
    groups: normalizedGroups,
    routingHints: routingHints?.offsetBy(dx: dx, dy: dy)
  )
}

public func policyCanvasNodeFrame(_ node: PolicyCanvasNode) -> CGRect {
  CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize(for: node))
}

public func policyCanvasNodeFrame(
  _ node: PolicyCanvasNode,
  edges: [PolicyCanvasEdge]
) -> CGRect {
  CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize(for: node, edges: edges))
}

public func policyCanvasNodeFramesByID(
  nodes: [PolicyCanvasNode],
  edges: [PolicyCanvasEdge]
) -> [String: CGRect] {
  let sizes = PolicyCanvasLayout.nodeSizes(for: nodes, edges: edges)
  return Dictionary(
    uniqueKeysWithValues: nodes.map { node in
      (
        node.id,
        CGRect(
          origin: node.position,
          size: sizes[node.id] ?? PolicyCanvasLayout.nodeSize(for: node)
        )
      )
    }
  )
}

public func policyCanvasGroupFrame(containing bounds: CGRect) -> CGRect {
  let padded = bounds.insetBy(
    dx: -PolicyCanvasLayout.groupHorizontalPadding,
    dy: -PolicyCanvasLayout.groupVerticalPadding
  )
  let minX = padded.minX
  let minY = padded.minY
  let maxX = max(
    minX + PolicyCanvasLayout.minimumGroupSize.width,
    padded.maxX
  )
  let maxY = max(
    minY + PolicyCanvasLayout.minimumGroupSize.height,
    padded.maxY
  )
  return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    .integral
    .standardized
}

public func policyCanvasGroupFrame(containing nodes: [PolicyCanvasNode]) -> CGRect? {
  let bounds = nodes.reduce(CGRect.null) { partial, node in
    partial.union(policyCanvasNodeFrame(node))
  }
  guard !bounds.isNull else {
    return nil
  }
  return policyCanvasGroupFrame(containing: bounds)
}
