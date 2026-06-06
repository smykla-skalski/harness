import CoreGraphics
import Foundation

/// Slide each single-fed branch terminal under the point where its one feeder
/// leaves the source, so the drop is a straight line instead of a jog. A terminal
/// fed from the source's bottom centers on that bottom port; one fed from the
/// trailing edge centers on the trailing exit column (one fed from the leading
/// edge mirrors). Sources that fan three or more children below them keep the
/// comb's even spread - their feeders diverge from packed bottom ports, so pulling
/// each child under its own port would overlap them and the bottom fan already
/// reads cleanly. Per terminal row the aligned terminals are pushed apart to one
/// column step, left to right, so alignment never drops one onto another. The side
/// test mirrors the route worker's `policyCanvasGeometryAwareSourceSide`, so a
/// terminal is only pulled where its rendered rail actually leaves the source.
public func policyCanvasAlignSingleFedTerminals(
  nodes: inout [PolicyCanvasNode],
  groups: inout [PolicyCanvasGroup],
  edges: [PolicyCanvasEdge]
) {
  let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
  let lead = PolicyCanvasLayout.edgePortTurnMinimumLead
  let desiredCenterX = policyCanvasSingleFedTerminalDesiredCenters(
    nodes: nodes,
    nodesByID: nodesByID,
    edges: edges,
    lead: lead
  )
  let finalX = policyCanvasSpreadTerminalCenters(
    desiredCenterX,
    nodesByID: nodesByID,
    lead: lead
  )
  policyCanvasApplyTerminalAlignments(finalX, nodes: &nodes, groups: &groups)
}

@discardableResult
public func policyCanvasResolveGroupedNodeOverlaps(
  nodes: inout [PolicyCanvasNode],
  groups: inout [PolicyCanvasGroup]
) -> Bool {
  guard !groups.isEmpty, nodes.contains(where: { $0.groupID != nil }) else {
    return false
  }
  let nodePositions = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position) })
  let resolvedPositions = policyCanvasResolveNodeOverlaps(nodePositions: nodePositions)
  var changed = false
  for index in nodes.indices {
    guard let resolved = resolvedPositions[nodes[index].id],
      resolved != nodes[index].position
    else {
      continue
    }
    nodes[index].position = resolved
    changed = true
  }
  if changed {
    policyCanvasReencloseGroupFrames(nodes: nodes, groups: &groups)
  }
  return changed
}

private func policyCanvasTerminalSourceSide(
  source: PolicyCanvasNode,
  target: PolicyCanvasNode
) -> PolicyCanvasPortSide {
  policyCanvasGeometryAwareSourceSide(
    natural: .trailing,
    sourceFrame: policyCanvasNodeFrame(source),
    targetFrame: policyCanvasNodeFrame(target)
  )
}

private func policyCanvasBelowChildren(
  nodesByID: [String: PolicyCanvasNode],
  edges: [PolicyCanvasEdge]
) -> [String: Set<String>] {
  var belowChildren: [String: Set<String>] = [:]
  for edge in edges {
    guard let source = nodesByID[edge.source.nodeID], let target = nodesByID[edge.target.nodeID]
    else { continue }
    if policyCanvasNodeFrame(target).minY > policyCanvasNodeFrame(source).maxY {
      belowChildren[source.id, default: []].insert(target.id)
    }
  }
  return belowChildren
}

private func policyCanvasSingleFedTerminalDesiredCenters(
  nodes: [PolicyCanvasNode],
  nodesByID: [String: PolicyCanvasNode],
  edges: [PolicyCanvasEdge],
  lead: CGFloat
) -> [String: CGFloat] {
  let context = PolicyCanvasTerminalAlignmentContext(
    nodesByID: nodesByID,
    incomingByTarget: Dictionary(grouping: edges, by: { $0.target.nodeID }),
    belowChildren: policyCanvasBelowChildren(nodesByID: nodesByID, edges: edges),
    edges: edges,
    lead: lead
  )
  var desiredCenterX: [String: CGFloat] = [:]
  for node in nodes where node.outputPorts.isEmpty {
    guard
      let centerX = policyCanvasDesiredTerminalCenterX(
        node: node,
        context: context
      )
    else {
      continue
    }
    desiredCenterX[node.id] = centerX
  }
  return desiredCenterX
}

private struct PolicyCanvasTerminalAlignmentContext {
  let nodesByID: [String: PolicyCanvasNode]
  let incomingByTarget: [String: [PolicyCanvasEdge]]
  let belowChildren: [String: Set<String>]
  let edges: [PolicyCanvasEdge]
  let lead: CGFloat
}

private func policyCanvasDesiredTerminalCenterX(
  node: PolicyCanvasNode,
  context: PolicyCanvasTerminalAlignmentContext
) -> CGFloat? {
  guard
    let incoming = context.incomingByTarget[node.id], incoming.count == 1,
    let edge = incoming.first,
    let source = context.nodesByID[edge.source.nodeID],
    (context.belowChildren[source.id]?.count ?? 0) < 3,
    policyCanvasNodeFrame(node).minY > policyCanvasNodeFrame(source).maxY
  else {
    return nil
  }

  switch policyCanvasTerminalSourceSide(source: source, target: node) {
  case .bottom:
    return policyCanvasBottomTerminalCenterX(
      edge: edge,
      source: source,
      context: context
    )
  case .trailing:
    return policyCanvasNodeFrame(source).maxX + context.lead
  case .leading:
    return policyCanvasNodeFrame(source).minX - context.lead
  default:
    return nil
  }
}

private func policyCanvasBottomTerminalCenterX(
  edge: PolicyCanvasEdge,
  source: PolicyCanvasNode,
  context: PolicyCanvasTerminalAlignmentContext
) -> CGFloat? {
  let bottomEdges = source.outputPorts.compactMap { port -> PolicyCanvasEdge? in
    context.edges.first { candidate in
      guard
        candidate.source.nodeID == source.id,
        candidate.source.portID == port.id,
        let target = context.nodesByID[candidate.target.nodeID]
      else {
        return false
      }
      return policyCanvasTerminalSourceSide(source: source, target: target) == .bottom
    }
  }
  guard let index = bottomEdges.firstIndex(where: { $0.id == edge.id }) else {
    return nil
  }
  return source.position.x + PolicyCanvasLayout.portX(index: index, count: bottomEdges.count)
}

private func policyCanvasSpreadTerminalCenters(
  _ desiredCenterX: [String: CGFloat],
  nodesByID: [String: PolicyCanvasNode],
  lead: CGFloat
) -> [String: CGFloat] {
  guard !desiredCenterX.isEmpty else {
    return [:]
  }
  let half = PolicyCanvasLayout.nodeSize.width / 2
  let step = PolicyCanvasLayout.nodeSize.width + lead
  let rows = Dictionary(grouping: desiredCenterX.keys) {
    Int((nodesByID[$0]?.position.y ?? 0).rounded())
  }
  var finalX: [String: CGFloat] = [:]
  for ids in rows.values {
    let ordered = ids.sorted { (desiredCenterX[$0] ?? 0) < (desiredCenterX[$1] ?? 0) }
    var previousCenter = -CGFloat.greatestFiniteMagnitude
    for id in ordered {
      let center = max(desiredCenterX[id] ?? 0, previousCenter + step)
      finalX[id] = center - half
      previousCenter = center
    }
  }
  return finalX
}

private func policyCanvasApplyTerminalAlignments(
  _ finalX: [String: CGFloat],
  nodes: inout [PolicyCanvasNode],
  groups: inout [PolicyCanvasGroup]
) {
  guard !finalX.isEmpty else {
    return
  }
  let alignedIDs = finalX.keys.sorted()
  let indexByID = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
  for id in alignedIDs {
    guard let index = indexByID[id], let x = finalX[id] else {
      continue
    }
    let original = nodes[index].position
    nodes[index].position = CGPoint(x: x.rounded(), y: original.y)
    policyCanvasReencloseGroupFrames(nodes: nodes, groups: &groups)
    if policyCanvasNeedsDefaultArrangement(nodes: nodes, groups: groups) {
      nodes[index].position = original
      policyCanvasReencloseGroupFrames(nodes: nodes, groups: &groups)
    }
  }
}

/// Rebuilds each group's frame to enclose its current members, matching the
/// engine's own `policyCanvasGroupFrame` padding so a re-enclosed frame is
/// identical to one the layered engine would have produced for those positions.
func policyCanvasReencloseGroupFrames(
  nodes: [PolicyCanvasNode],
  groups: inout [PolicyCanvasGroup]
) {
  var membersByGroup: [String: [PolicyCanvasNode]] = [:]
  for node in nodes {
    if let groupID = node.groupID {
      membersByGroup[groupID, default: []].append(node)
    }
  }
  for index in groups.indices {
    if let frame = policyCanvasGroupFrame(containing: membersByGroup[groups[index].id] ?? []) {
      groups[index].frame = frame
    }
  }
}
