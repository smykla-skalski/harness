import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

func synthesizedGroupFrame(
  offset: Int,
  group: TaskBoardPolicyPipelineGroup,
  nodes: [PolicyCanvasNode]
) -> CGRect {
  let memberIDs = Set(group.nodeIds)
  let members = nodes.filter { node in
    node.groupID == group.id || memberIDs.contains(node.id)
  }
  guard !members.isEmpty else {
    return CGRect(x: 72 + CGFloat(offset * 280), y: 72, width: 248, height: 220)
  }
  let bounds = members.reduce(CGRect.null) { partial, node in
    partial.union(CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize))
  }
  return policyCanvasGroupFrame(containing: bounds)
}

extension TaskBoardPolicyPipelineLayout {
  func nodeLayout(
    for nodeID: String
  ) -> (position: TaskBoardPolicyCanvasPoint, source: TaskBoardPolicyPipelineNodeLayoutSource?)? {
    guard let node = nodes.first(where: { $0.nodeId == nodeID }) else {
      return nil
    }
    return (
      position: TaskBoardPolicyCanvasPoint(x: Double(node.x), y: Double(node.y)),
      source: node.source
    )
  }
}

extension TaskBoardPolicyCanvasRect {
  var isEmpty: Bool {
    width <= 0 || height <= 0
  }
}

func taskBoardPolicyNodeKind(
  for kind: PolicyCanvasNodeKind
) -> TaskBoardPolicyPipelineNodeKind {
  kind.defaultPolicyKind
}

func policyCanvasEdgeLabel(_ edge: TaskBoardPolicyPipelineEdge) -> String {
  if let label = edge.label?.trimmingCharacters(in: .whitespacesAndNewlines),
    !label.isEmpty
  {
    let normalized = policyCanvasNormalizedEdgeLabel(label)
    if !policyCanvasIsGenericEdgeLabel(normalized) {
      return normalized
    }
  }
  if let branchLabel = policyCanvasConditionalBranchLabel(
    fromPort: edge.fromPort,
    condition: edge.condition.condition
  ) {
    return branchLabel
  }
  if edge.condition.condition != "always" {
    return edge.condition.condition.replacingOccurrences(of: "_", with: " ")
  }
  let fallback = policyCanvasNormalizedEdgeLabel(edge.fromPort)
  return policyCanvasIsGenericEdgeLabel(fallback) ? "" : fallback
}

private func policyCanvasNormalizedEdgeLabel(_ label: String) -> String {
  label
    .replacingOccurrences(of: "_", with: " ")
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func policyCanvasConditionalBranchLabel(
  fromPort: String,
  condition: String
) -> String? {
  switch policyCanvasNormalizedEdgeLabel(fromPort).lowercased() {
  case "then", "true":
    return "then"
  case "else", "false":
    return "else"
  default:
    break
  }
  switch condition.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
  case "condition_true":
    return "then"
  case "condition_false":
    return "else"
  default:
    return nil
  }
}

private func policyCanvasIsGenericEdgeLabel(_ label: String) -> Bool {
  switch label.lowercased() {
  case "", "in", "input", "policy", "input policy":
    true
  default:
    false
  }
}

func policyCanvasAssignPreferredPortSides(
  source: inout PolicyCanvasPortEndpoint,
  target: inout PolicyCanvasPortEndpoint,
  nodes: [PolicyCanvasNode]
) {
  guard
    let sourceNode = nodes.first(where: { $0.id == source.nodeID }),
    let targetNode = nodes.first(where: { $0.id == target.nodeID }),
    sourceNode.groupID == targetNode.groupID
  else {
    return
  }
  let horizontalDelta = abs(sourceNode.position.x - targetNode.position.x)
  let verticalDelta = abs(sourceNode.position.y - targetNode.position.y)
  if horizontalDelta >= PolicyCanvasLayout.nodeSize.width {
    if sourceNode.position.x < targetNode.position.x {
      source.side = .trailing
      target.side = .leading
    } else {
      source.side = .leading
      target.side = .trailing
    }
    policyCanvasUnblockTargetPortSide(
      target: &target, targetNode: targetNode, sourceNode: sourceNode, nodes: nodes
    )
    return
  }
  guard verticalDelta > horizontalDelta,
    verticalDelta >= PolicyCanvasLayout.nodeSize.height
  else {
    return
  }
  if sourceNode.position.y < targetNode.position.y {
    source.side = .bottom
    target.side = .top
  } else {
    source.side = .top
    target.side = .bottom
  }
  policyCanvasUnblockTargetPortSide(
    target: &target, targetNode: targetNode, sourceNode: sourceNode, nodes: nodes
  )
}

/// Steer the target off a port side that another node sits flush against.
///
/// The router escapes a port by stepping `edgePortTurnMinimumLead` straight out
/// before it turns. When a foreign node sits flush against the chosen side, that
/// lead point lands inside the neighbor; the router then reads the neighbor as an
/// endpoint, drops it from the obstacle set, and the wire cuts straight through
/// its body. So when the geometrically preferred target side is blocked this way,
/// switch to the perpendicular side that still faces the source - but only if
/// that side is itself clear, so the fallback never trades one body hit for
/// another.
private func policyCanvasUnblockTargetPortSide(
  target: inout PolicyCanvasPortEndpoint,
  targetNode: PolicyCanvasNode,
  sourceNode: PolicyCanvasNode,
  nodes: [PolicyCanvasNode]
) {
  guard let side = target.side,
    policyCanvasPortSideIsBlocked(node: targetNode, side: side, nodes: nodes),
    let alternative = policyCanvasPerpendicularFacingSide(
      from: side, node: targetNode, toward: sourceNode
    ),
    !policyCanvasPortSideIsBlocked(node: targetNode, side: alternative, nodes: nodes)
  else {
    return
  }
  target.side = alternative
}

private func policyCanvasPortSideIsBlocked(
  node: PolicyCanvasNode,
  side: PolicyCanvasPortSide,
  nodes: [PolicyCanvasNode]
) -> Bool {
  let frame = CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize)
  // One point past the lead so a neighbor sitting exactly one lead away - whose
  // edge the lead point lands on, dropping it from the obstacle set - still
  // counts as blocking.
  let reach = PolicyCanvasLayout.edgePortTurnMinimumLead + 1
  let corridor: CGRect
  switch side {
  case .leading:
    corridor = CGRect(x: frame.minX - reach, y: frame.minY, width: reach, height: frame.height)
  case .trailing:
    corridor = CGRect(x: frame.maxX, y: frame.minY, width: reach, height: frame.height)
  case .top:
    corridor = CGRect(x: frame.minX, y: frame.minY - reach, width: frame.width, height: reach)
  case .bottom:
    corridor = CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: reach)
  }
  return nodes.contains { other in
    other.id != node.id
      && CGRect(origin: other.position, size: PolicyCanvasLayout.nodeSize).intersects(corridor)
  }
}

/// The perpendicular side that still faces the source, or nil when the source is
/// not offset by a full node on the perpendicular axis (no side genuinely faces
/// it there, so a flip would only point the wire away from its origin).
private func policyCanvasPerpendicularFacingSide(
  from side: PolicyCanvasPortSide,
  node: PolicyCanvasNode,
  toward other: PolicyCanvasNode
) -> PolicyCanvasPortSide? {
  switch side {
  case .leading, .trailing:
    if other.position.y + PolicyCanvasLayout.nodeSize.height <= node.position.y {
      return .top
    }
    if other.position.y >= node.position.y + PolicyCanvasLayout.nodeSize.height {
      return .bottom
    }
    return nil
  case .top, .bottom:
    if other.position.x + PolicyCanvasLayout.nodeSize.width <= node.position.x {
      return .leading
    }
    if other.position.x >= node.position.x + PolicyCanvasLayout.nodeSize.width {
      return .trailing
    }
    return nil
  }
}

func policyCanvasAssignTrustedLayoutSources(
  _ nodes: [PolicyCanvasNode]
) -> [PolicyCanvasNode] {
  var trustedNodes = nodes
  for index in trustedNodes.indices where trustedNodes[index].layoutSource == nil {
    trustedNodes[index].layoutSource = .manual
  }
  return trustedNodes
}
