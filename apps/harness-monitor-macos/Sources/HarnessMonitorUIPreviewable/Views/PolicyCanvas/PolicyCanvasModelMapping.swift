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
    label: edge.label ?? "policy"
  )
}

func taskBoardPolicyNode(
  _ node: PolicyCanvasNode,
  originalKind: TaskBoardPolicyPipelineNodeKind? = nil
) -> TaskBoardPolicyPipelineNode {
  TaskBoardPolicyPipelineNode(
    id: node.id,
    title: node.title,
    kind: originalKind ?? taskBoardPolicyNodeKind(for: node.kind),
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
  return bounds.insetBy(dx: -44, dy: -52).standardized
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
