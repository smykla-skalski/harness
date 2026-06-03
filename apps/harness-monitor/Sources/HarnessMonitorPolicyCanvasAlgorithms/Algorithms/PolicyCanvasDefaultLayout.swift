import SwiftUI

/// Automatic-layout helpers + overlap detection used by
/// `policyCanvasCleanInitialLayout(nodes:groups:edges:)`. The layered engine
/// owns default placement now; these helpers only decide when a persisted
/// arrangement is trustworthy and normalize the final canvas bounds.

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

  public init(
    nodes: [PolicyCanvasNode],
    groups: [PolicyCanvasGroup],
    metrics: PolicyCanvasLayoutMetrics?,
    routingHints: PolicyCanvasLayoutRoutingHints?
  ) {
    self.nodes = nodes
    self.groups = groups
    self.metrics = metrics
    self.routingHints = routingHints
  }
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
  mode: PolicyCanvasAutomaticLayoutMode = .initialLoad,
  algorithmSelection: PolicyCanvasAlgorithmSelection = .referenceRouting
) -> PolicyCanvasLayoutResult? {
  let graph = policyCanvasLayoutGraph(
    nodes: nodes,
    groups: groups,
    edges: edges,
    mode: mode
  )
  if PolicyCanvasLayoutAlgorithmRegistry.isHarnessCurrentLayout(algorithmSelection) {
    return PolicyCanvasLayeredLayoutEngine(mode: mode).layout(graph: graph)
  }
  return PolicyCanvasDecoupledSugiyamaLayoutEngine(
    mode: mode,
    selection: algorithmSelection
  ).layout(graph: graph)
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
      // The layered engine's barycentric centering averages neighbor positions,
      // which can land an auto-placed node on a fractional coordinate (a third of
      // a pixel when three neighbors average). Snap auto placements to whole
      // pixels so a saved layout round-trips exactly and a node never poking a
      // sub-pixel past its integral group frame trips the tidiness gate. Manual
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
  mode: PolicyCanvasAutomaticLayoutMode = .initialLoad,
  algorithmSelection: PolicyCanvasAlgorithmSelection = .referenceRouting
) -> (metrics: PolicyCanvasLayoutMetrics?, routingHints: PolicyCanvasLayoutRoutingHints?) {
  guard
    let result = policyCanvasAutomaticLayoutResult(
      nodes: nodes,
      groups: groups,
      edges: edges,
      mode: mode,
      algorithmSelection: algorithmSelection
    )
  else {
    return (metrics: nil, routingHints: nil)
  }
  let routingHints = applyPolicyCanvasLayoutResult(
    result,
    nodes: &nodes,
    groups: &groups,
    centerInMinimumCanvas: mode.centersInMinimumCanvas
  )
  return (metrics: result.metrics, routingHints: routingHints)
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

func policyCanvasBounds(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup]
) -> CGRect {
  let nodeBounds = nodes.reduce(CGRect.null) { partial, node in
    partial.union(CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize))
  }
  return groups.reduce(nodeBounds) { partial, group in
    partial.union(group.frame)
  }
}

func policyCanvasAnyGroupOverlap(_ groups: [PolicyCanvasGroup]) -> Bool {
  for leftIndex in groups.indices {
    for rightIndex in groups.index(after: leftIndex)..<groups.endIndex
    where groups[leftIndex].frame.intersects(groups[rightIndex].frame) {
      return true
    }
  }
  return false
}

func policyCanvasAnyNodeOverlap(_ nodes: [PolicyCanvasNode]) -> Bool {
  for leftIndex in nodes.indices {
    for rightIndex in nodes.index(after: leftIndex)..<nodes.endIndex {
      let leftFrame = policyCanvasNodeFrame(nodes[leftIndex])
      let rightFrame = policyCanvasNodeFrame(nodes[rightIndex])
      if leftFrame.intersects(rightFrame) {
        return true
      }
    }
  }
  return false
}

func policyCanvasAnyNodeOutsideAssignedGroup(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup]
) -> Bool {
  let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.frame) })
  return nodes.contains { node in
    guard let groupID = node.groupID, let groupFrame = groupsByID[groupID] else {
      return false
    }
    return !groupFrame.contains(policyCanvasNodeFrame(node))
  }
}

public func policyCanvasNodeFrame(_ node: PolicyCanvasNode) -> CGRect {
  CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize)
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

extension CGRect {
  var originNeedsNormalization: Bool {
    minX < PolicyCanvasLayout.initialContentOrigin.x
      || minY < PolicyCanvasLayout.initialContentOrigin.y
  }
}

private func policyCanvasCenterInMinimumCanvas(
  nodes: inout [PolicyCanvasNode],
  groups: inout [PolicyCanvasGroup]
) -> CGSize {
  let bounds = policyCanvasBounds(nodes: nodes, groups: groups)
  guard !bounds.isNull else {
    return .zero
  }
  let targetCanvasWidth = max(
    PolicyCanvasLayout.minimumCanvasSize.width,
    bounds.width + (PolicyCanvasLayout.canvasTrailingPadding * 2)
  )
  let targetCanvasHeight = max(
    PolicyCanvasLayout.minimumCanvasSize.height,
    bounds.height + (PolicyCanvasLayout.canvasBottomPadding * 2)
  )
  let centeredMinX = max(
    PolicyCanvasLayout.initialContentOrigin.x,
    (targetCanvasWidth - bounds.width) / 2
  )
  let centeredMinY = max(
    PolicyCanvasLayout.initialContentOrigin.y,
    (targetCanvasHeight - bounds.height) / 2
  )
  let dx = centeredMinX - bounds.minX
  let dy = centeredMinY - bounds.minY
  guard dx != 0 || dy != 0 else {
    return .zero
  }
  for index in nodes.indices {
    nodes[index].position.x += dx
    nodes[index].position.y += dy
  }
  for index in groups.indices {
    groups[index].frame = groups[index].frame.offsetBy(dx: dx, dy: dy)
  }
  return CGSize(width: dx, height: dy)
}
