import HarnessMonitorKit
import SwiftUI

func policyCanvasNode(
  _ node: TaskBoardPolicyPipelineNode,
  layout: TaskBoardPolicyPipelineLayout
) -> PolicyCanvasNode {
  let position = layout.nodePosition(for: node.id)
  var canvasNode = PolicyCanvasNode(
    id: node.id,
    title: node.title,
    kind: policyCanvasKind(for: node.kind),
    position: CGPoint(x: CGFloat(position.x), y: CGFloat(position.y))
  )
  canvasNode.groupID = node.groupId
  canvasNode.policyKind = node.kind
  canvasNode.inputPorts = node.inputs.map { port in
    PolicyCanvasPort(id: port.id, title: port.title, kind: .input)
  }
  canvasNode.outputPorts = node.outputs.map { port in
    PolicyCanvasPort(id: port.id, title: port.title, kind: .output)
  }
  return canvasNode
}

func policyCanvasGroup(
  offset: Int,
  element: TaskBoardPolicyPipelineGroup,
  nodes: [PolicyCanvasNode]
) -> PolicyCanvasGroup {
  let frame =
    element.frame.isEmpty
    ? synthesizedGroupFrame(offset: offset, group: element, nodes: nodes)
    : CGRect(
      x: CGFloat(element.frame.x),
      y: CGFloat(element.frame.y),
      width: CGFloat(element.frame.width),
      height: CGFloat(element.frame.height)
    )
  return PolicyCanvasGroup(
    id: element.id,
    title: element.title,
    frame: frame,
    tone: PolicyCanvasGroupTone.allCases[offset % PolicyCanvasGroupTone.allCases.count]
  )
}

func policyCanvasCleanInitialLayout(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup]
) -> (nodes: [PolicyCanvasNode], groups: [PolicyCanvasGroup]) {
  var cleanNodes = nodes
  var cleanGroups = groups
  if policyCanvasUsesDefaultPolicyGroups(cleanGroups),
    policyCanvasNeedsDefaultArrangement(nodes: cleanNodes, groups: cleanGroups)
  {
    applyDefaultPolicyCanvasLayout(nodes: &cleanNodes, groups: &cleanGroups)
  }
  return policyCanvasNormalizeMinimumOrigin(nodes: cleanNodes, groups: cleanGroups)
}

func policyCanvasEdge(_ edge: TaskBoardPolicyPipelineEdge) -> PolicyCanvasEdge {
  PolicyCanvasEdge(
    id: edge.id,
    source: PolicyCanvasPortEndpoint(
      nodeID: edge.fromNodeId,
      portID: edge.fromPort,
      kind: .output
    ),
    target: PolicyCanvasPortEndpoint(
      nodeID: edge.toNodeId,
      portID: edge.toPort,
      kind: .input
    ),
    label: policyCanvasEdgeLabel(edge)
  )
}

func taskBoardPolicyNode(
  _ node: PolicyCanvasNode,
  originalKind: TaskBoardPolicyPipelineNodeKind? = nil
) -> TaskBoardPolicyPipelineNode {
  TaskBoardPolicyPipelineNode(
    id: node.id,
    title: node.title,
    kind: node.policyKind ?? originalKind ?? taskBoardPolicyNodeKind(for: node.kind),
    position: TaskBoardPolicyCanvasPoint(
      x: Double(node.position.x),
      y: Double(node.position.y)
    ),
    groupId: node.groupID,
    inputs: node.inputPorts.map { TaskBoardPolicyPipelinePort(id: $0.id, title: $0.title) },
    outputs: node.outputPorts.map { TaskBoardPolicyPipelinePort(id: $0.id, title: $0.title) }
  )
}

func taskBoardPolicyEdge(
  _ edge: PolicyCanvasEdge,
  originalCondition: TaskBoardPolicyPipelineEdgeCondition? = nil
) -> TaskBoardPolicyPipelineEdge {
  TaskBoardPolicyPipelineEdge(
    id: edge.id,
    fromNodeId: edge.source.nodeID,
    fromPort: edge.source.portID,
    toNodeId: edge.target.nodeID,
    toPort: edge.target.portID,
    label: edge.label,
    condition: originalCondition ?? .always
  )
}

func taskBoardPolicyGroup(
  _ group: PolicyCanvasGroup,
  nodes: [PolicyCanvasNode]
) -> TaskBoardPolicyPipelineGroup {
  TaskBoardPolicyPipelineGroup(
    id: group.id,
    title: group.title,
    color: group.tone.hexColor,
    frame: TaskBoardPolicyCanvasRect(
      x: Double(group.frame.minX),
      y: Double(group.frame.minY),
      width: Double(group.frame.width),
      height: Double(group.frame.height)
    ),
    nodeIds: nodes.filter { $0.groupID == group.id }.map(\.id)
  )
}

func taskBoardPolicyNodeLayout(_ node: PolicyCanvasNode) -> TaskBoardPolicyPipelineNodeLayout {
  TaskBoardPolicyPipelineNodeLayout(
    nodeId: node.id,
    x: Int(node.position.x.rounded()),
    y: Int(node.position.y.rounded())
  )
}

func policyCanvasKind(
  for kind: TaskBoardPolicyPipelineNodeKind
) -> PolicyCanvasNodeKind {
  switch kind.kind {
  case "trigger":
    .source
  case "human_gate", "consensus_gate":
    .review
  case "supervisor_rule":
    .transform
  case "dry_run_gate":
    .decision
  default:
    .condition
  }
}

private func synthesizedGroupFrame(
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
  fileprivate func nodePosition(for nodeID: String) -> TaskBoardPolicyCanvasPoint {
    guard let node = nodes.first(where: { $0.nodeId == nodeID }) else {
      return .zero
    }
    return TaskBoardPolicyCanvasPoint(x: Double(node.x), y: Double(node.y))
  }
}

extension TaskBoardPolicyCanvasRect {
  fileprivate var isEmpty: Bool {
    width <= 0 || height <= 0
  }
}

func taskBoardPolicyNodeKind(
  for kind: PolicyCanvasNodeKind
) -> TaskBoardPolicyPipelineNodeKind {
  switch kind {
  case .source:
    TaskBoardPolicyPipelineNodeKind(kind: "trigger", workflow: "default-task")
  case .condition:
    TaskBoardPolicyPipelineNodeKind(kind: "action_gate", action: .spawnAgent)
  case .review:
    TaskBoardPolicyPipelineNodeKind(kind: "human_gate")
  case .transform:
    TaskBoardPolicyPipelineNodeKind(kind: "supervisor_rule", ruleId: "stuck-agent")
  case .decision:
    TaskBoardPolicyPipelineNodeKind(kind: "dry_run_gate")
  }
}

private func policyCanvasUsesDefaultPolicyGroups(_ groups: [PolicyCanvasGroup]) -> Bool {
  let groupIDs = Set(groups.map(\.id))
  return ["entry", "merge", "terminal"].allSatisfy(groupIDs.contains)
}

private func policyCanvasNeedsDefaultArrangement(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup]
) -> Bool {
  policyCanvasAnyGroupOverlap(groups)
    || policyCanvasAnyNodeOverlap(nodes)
    || policyCanvasAnyNodeOutsideAssignedGroup(nodes: nodes, groups: groups)
    || policyCanvasBounds(nodes: nodes, groups: groups).originNeedsNormalization
}

private func applyDefaultPolicyCanvasLayout(
  nodes: inout [PolicyCanvasNode],
  groups: inout [PolicyCanvasGroup]
) {
  for index in groups.indices {
    guard let frame = defaultPolicyCanvasGroupFrames[groups[index].id] else { continue }
    groups[index].frame = frame
  }
  for index in nodes.indices {
    guard let position = defaultPolicyCanvasNodePositions[nodes[index].id] else { continue }
    nodes[index].position = position
  }
}

private func policyCanvasNormalizeMinimumOrigin(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup]
) -> (nodes: [PolicyCanvasNode], groups: [PolicyCanvasGroup]) {
  let bounds = policyCanvasBounds(nodes: nodes, groups: groups)
  guard !bounds.isNull else {
    return (nodes, groups)
  }
  let dx = max(0, PolicyCanvasLayout.initialContentOrigin.x - bounds.minX)
  let dy = max(0, PolicyCanvasLayout.initialContentOrigin.y - bounds.minY)
  guard dx > 0 || dy > 0 else {
    return (nodes, groups)
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
  return (normalizedNodes, normalizedGroups)
}

private func policyCanvasBounds(
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

private func policyCanvasAnyGroupOverlap(_ groups: [PolicyCanvasGroup]) -> Bool {
  for leftIndex in groups.indices {
    for rightIndex in groups.index(after: leftIndex)..<groups.endIndex
    where groups[leftIndex].frame.intersects(groups[rightIndex].frame) {
      return true
    }
  }
  return false
}

private func policyCanvasAnyNodeOverlap(_ nodes: [PolicyCanvasNode]) -> Bool {
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

private func policyCanvasAnyNodeOutsideAssignedGroup(
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

func policyCanvasNodeFrame(_ node: PolicyCanvasNode) -> CGRect {
  CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize)
}

private func policyCanvasGroupFrame(containing bounds: CGRect) -> CGRect {
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

extension CGRect {
  fileprivate var originNeedsNormalization: Bool {
    minX < PolicyCanvasLayout.initialContentOrigin.x
      || minY < PolicyCanvasLayout.initialContentOrigin.y
  }
}

private let defaultPolicyCanvasGroupFrames: [String: CGRect] = [
  "entry": CGRect(x: 140, y: 160, width: 256, height: 220),
  "merge": CGRect(x: 540, y: 160, width: 256, height: 420),
  "terminal": CGRect(x: 980, y: 160, width: 256, height: 1_220),
]

private let defaultPolicyCanvasNodePositions: [String: CGPoint] = [
  "action:router": CGPoint(x: 184, y: 212),
  "evidence:merge": CGPoint(x: 584, y: 212),
  "risk:merge": CGPoint(x: 584, y: 392),
  "supervisor:default-allow": CGPoint(x: 1_024, y: 212),
  "dry_run:mutate_repo": CGPoint(x: 1_024, y: 352),
  "human:unsafe-action": CGPoint(x: 1_024, y: 492),
  "human:missing-merge-evidence": CGPoint(x: 1_024, y: 632),
  "consensus:protected-path": CGPoint(x: 1_024, y: 772),
  "dry_run:high-risk-merge": CGPoint(x: 1_024, y: 912),
  "supervisor:merge-deny": CGPoint(x: 1_024, y: 1_052),
  "supervisor:auto-merge": CGPoint(x: 1_024, y: 1_192),
]

private func policyCanvasEdgeLabel(_ edge: TaskBoardPolicyPipelineEdge) -> String {
  if let label = edge.label?.trimmingCharacters(in: .whitespacesAndNewlines),
    !label.isEmpty,
    label != "policy"
  {
    return label
  }
  if edge.condition.condition != "always" {
    return edge.condition.condition.replacingOccurrences(of: "_", with: " ")
  }
  return edge.fromPort.replacingOccurrences(of: "_", with: " ")
}
