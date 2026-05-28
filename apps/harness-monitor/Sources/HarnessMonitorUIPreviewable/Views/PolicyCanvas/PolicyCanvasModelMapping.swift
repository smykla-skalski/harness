import HarnessMonitorKit
import SwiftUI

func policyCanvasNode(
  _ node: TaskBoardPolicyPipelineNode,
  layout: TaskBoardPolicyPipelineLayout
) -> PolicyCanvasNode {
  let layoutNode = layout.nodeLayout(for: node.id)
  let position = layoutNode?.position ?? .zero
  var canvasNode = PolicyCanvasNode(
    id: node.id,
    title: node.title,
    kind: policyCanvasKind(for: node.kind),
    position: CGPoint(x: CGFloat(position.x), y: CGFloat(position.y))
  )
  canvasNode.layoutSource = layoutNode?.source
  canvasNode.groupID = node.groupId
  canvasNode.policyKind = node.kind
  canvasNode.automationBinding = node.automation
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
  groups: [PolicyCanvasGroup],
  edges: [PolicyCanvasEdge],
  mode: PolicyCanvasAutomaticLayoutMode = .initialLoad
) -> (
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup],
  metrics: PolicyCanvasLayoutMetrics?,
  routingHints: PolicyCanvasLayoutRoutingHints?
) {
  var cleanNodes = nodes
  var cleanGroups = groups
  var layoutMetrics: PolicyCanvasLayoutMetrics?
  var routingHints: PolicyCanvasLayoutRoutingHints?
  let shouldAutoArrange: Bool
  switch mode {
  case .initialLoad:
    shouldAutoArrange = policyCanvasNeedsDefaultArrangement(nodes: cleanNodes, groups: cleanGroups)
  case .explicitReflow(_):
    shouldAutoArrange = true
  }
  if shouldAutoArrange {
    let autoLayout = applyDefaultPolicyCanvasLayout(
      nodes: &cleanNodes,
      groups: &cleanGroups,
      edges: edges,
      mode: mode
    )
    if let autoLayoutMetrics = autoLayout.metrics {
      layoutMetrics = autoLayoutMetrics
      routingHints = autoLayout.routingHints
    } else {
      cleanNodes = policyCanvasAssignTrustedLayoutSources(cleanNodes)
    }
  } else {
    cleanNodes = policyCanvasAssignTrustedLayoutSources(cleanNodes)
  }
  let normalized = policyCanvasNormalizeMinimumOrigin(
    nodes: cleanNodes,
    groups: cleanGroups,
    routingHints: routingHints
  )
  return (
    nodes: normalized.nodes,
    groups: normalized.groups,
    metrics: layoutMetrics,
    routingHints: normalized.routingHints
  )
}

func policyCanvasEdge(
  _ edge: TaskBoardPolicyPipelineEdge,
  nodes: [PolicyCanvasNode] = [],
  assignPreferredPortSides: Bool = true
) -> PolicyCanvasEdge? {
  guard policyCanvasEdgeEndpointsExist(edge, nodes: nodes) else {
    return nil
  }
  var source = PolicyCanvasPortEndpoint(
    nodeID: edge.fromNodeId,
    portID: edge.fromPort,
    kind: .output
  )
  var target = PolicyCanvasPortEndpoint(
    nodeID: edge.toNodeId,
    portID: edge.toPort,
    kind: .input
  )
  if assignPreferredPortSides {
    policyCanvasAssignPreferredPortSides(source: &source, target: &target, nodes: nodes)
  }
  let kind = PolicyCanvasEdgeKind.derive(from: edge.condition.condition)
  return PolicyCanvasEdge(
    id: edge.id,
    source: source,
    target: target,
    label: policyCanvasEdgeLabel(edge),
    condition: edge.condition.condition,
    pinnedPortSide: source.side != nil || target.side != nil,
    kind: kind
  )
}

func policyCanvasApplyingPreferredPortSides(
  _ edge: PolicyCanvasEdge,
  nodes: [PolicyCanvasNode],
  preservesPinnedState: Bool = false
) -> PolicyCanvasEdge {
  var adjustedEdge = edge
  var source = adjustedEdge.source
  var target = adjustedEdge.target
  source.side = nil
  target.side = nil
  policyCanvasAssignPreferredPortSides(source: &source, target: &target, nodes: nodes)
  adjustedEdge.source = source
  adjustedEdge.target = target
  adjustedEdge.pinnedPortSide = preservesPinnedState
    ? edge.pinnedPortSide
    : (source.side != nil || target.side != nil)
  return adjustedEdge
}

func policyCanvasEdgeEndpointsExist(
  _ edge: TaskBoardPolicyPipelineEdge,
  nodes: [PolicyCanvasNode]
) -> Bool {
  guard !nodes.isEmpty else { return true }
  guard let sourceNode = nodes.first(where: { $0.id == edge.fromNodeId }),
    let targetNode = nodes.first(where: { $0.id == edge.toNodeId })
  else {
    return false
  }
  return sourceNode.outputPorts.contains { $0.id == edge.fromPort }
    && targetNode.inputPorts.contains { $0.id == edge.toPort }
}

func taskBoardPolicyNode(
  _ node: PolicyCanvasNode,
  originalKind: TaskBoardPolicyPipelineNodeKind? = nil
) -> TaskBoardPolicyPipelineNode {
  TaskBoardPolicyPipelineNode(
    id: node.id,
    title: node.title,
    kind: node.policyKind ?? originalKind ?? taskBoardPolicyNodeKind(for: node.kind),
    automation: node.automationBinding,
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
  // The canvas edge carries the editable condition string; everything else
  // on the daemon-side condition payload (actions, reasonCode) is preserved
  // from the loaded backing document. When the user has not edited the
  // condition the canvas string matches the original payload's `.condition`
  // and the result is byte-equal to passing `originalCondition` through.
  let condition = TaskBoardPolicyPipelineEdgeCondition(
    condition: edge.condition,
    actions: originalCondition?.actions ?? [],
    reasonCode: originalCondition?.reasonCode
  )
  return TaskBoardPolicyPipelineEdge(
    id: edge.id,
    fromNodeId: edge.source.nodeID,
    fromPort: edge.source.portID,
    toNodeId: edge.target.nodeID,
    toPort: edge.target.portID,
    label: edge.label,
    condition: condition
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
    y: Int(node.position.y.rounded()),
    source: node.layoutSource
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
  fileprivate func nodeLayout(
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

private func policyCanvasEdgeLabel(_ edge: TaskBoardPolicyPipelineEdge) -> String {
  if let label = edge.label?.trimmingCharacters(in: .whitespacesAndNewlines),
    !label.isEmpty
  {
    let normalized = policyCanvasNormalizedEdgeLabel(label)
    if !policyCanvasIsGenericEdgeLabel(normalized) {
      return normalized
    }
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

private func policyCanvasIsGenericEdgeLabel(_ label: String) -> Bool {
  switch label.lowercased() {
  case "", "in", "input", "policy", "input policy":
    true
  default:
    false
  }
}

private func policyCanvasAssignPreferredPortSides(
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

private func policyCanvasAssignTrustedLayoutSources(
  _ nodes: [PolicyCanvasNode]
) -> [PolicyCanvasNode] {
  var trustedNodes = nodes
  for index in trustedNodes.indices where trustedNodes[index].layoutSource == nil {
    trustedNodes[index].layoutSource = .manual
  }
  return trustedNodes
}
