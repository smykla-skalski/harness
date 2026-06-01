import HarnessMonitorKit
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

func policyCanvasGroupFrame(containing nodes: [PolicyCanvasNode]) -> CGRect? {
  let bounds = nodes.reduce(CGRect.null) { partial, node in
    partial.union(policyCanvasNodeFrame(node))
  }
  guard !bounds.isNull else {
    return nil
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
