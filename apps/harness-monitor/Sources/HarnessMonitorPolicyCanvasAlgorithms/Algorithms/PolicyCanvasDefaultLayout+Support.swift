import CoreGraphics
import Foundation

extension CGRect {
  var originNeedsNormalization: Bool {
    minX < PolicyCanvasLayout.initialContentOrigin.x
      || minY < PolicyCanvasLayout.initialContentOrigin.y
  }
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

func policyCanvasPrecomputedRouteTerminalsAttach(
  precomputedRoutes: PolicyCanvasPrecomputedRouteSet,
  nodes: [PolicyCanvasNode],
  edges: [PolicyCanvasEdge]
) -> Bool {
  let edgeIDs = Set(edges.map(\.id))
  guard precomputedRoutes.routes.count == edgeIDs.count,
    Set(precomputedRoutes.routes.keys) == edgeIDs
  else {
    return false
  }
  let nodeFrames = Dictionary(
    uniqueKeysWithValues: nodes.map { node in
      (node.id, policyCanvasNodeFrame(node, edges: edges))
    }
  )
  for edge in edges {
    guard
      let route = precomputedRoutes.routes[edge.id],
      let first = route.points.first,
      let last = route.points.last,
      let sourceFrame = nodeFrames[edge.source.nodeID],
      let targetFrame = nodeFrames[edge.target.nodeID],
      policyCanvasPrecomputedRouteTerminal(first, attachesTo: sourceFrame),
      policyCanvasPrecomputedRouteTerminal(last, attachesTo: targetFrame)
    else {
      return false
    }
  }
  return true
}

func policyCanvasPrecomputedRouteTerminal(
  _ point: CGPoint,
  attachesTo frame: CGRect
) -> Bool {
  let tolerance = PolicyCanvasLayout.portDiameter
  let withinVertical = point.y >= frame.minY - tolerance && point.y <= frame.maxY + tolerance
  let withinHorizontal = point.x >= frame.minX - tolerance && point.x <= frame.maxX + tolerance
  let onLeading = withinVertical && abs(point.x - frame.minX) <= tolerance
  let onTrailing = withinVertical && abs(point.x - frame.maxX) <= tolerance
  let onTop = withinHorizontal && abs(point.y - frame.minY) <= tolerance
  let onBottom = withinHorizontal && abs(point.y - frame.maxY) <= tolerance
  return onLeading || onTrailing || onTop || onBottom
}

func policyCanvasCenterInMinimumCanvas(
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
