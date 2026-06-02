import HarnessMonitorKit
import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

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
    policyCanvasPort(port, nodeKind: node.kind, kind: .input)
  }
  canvasNode.outputPorts = node.outputs.map { port in
    policyCanvasPort(port, nodeKind: node.kind, kind: .output)
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
  mode: PolicyCanvasAutomaticLayoutMode = .initialLoad,
  algorithmSelection: PolicyCanvasAlgorithmSelection = .harnessCurrent
) -> PolicyCanvasCleanLayout {
  var cleanNodes = nodes
  var cleanGroups = groups
  var layoutMetrics: PolicyCanvasLayoutMetrics?
  var routingHints: PolicyCanvasLayoutRoutingHints?
  let shouldAutoArrange: Bool
  switch mode {
  case .initialLoad:
    shouldAutoArrange = policyCanvasNeedsDefaultArrangement(nodes: cleanNodes, groups: cleanGroups)
  case .explicitReflow:
    shouldAutoArrange = true
  }
  if shouldAutoArrange {
    let autoLayout = applyDefaultPolicyCanvasLayout(
      nodes: &cleanNodes,
      groups: &cleanGroups,
      edges: edges,
      mode: mode,
      algorithmSelection: algorithmSelection
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
  return PolicyCanvasCleanLayout(
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
  let sourceNode = nodes.first(where: { $0.id == edge.fromNodeId })
  let targetNode = nodes.first(where: { $0.id == edge.toNodeId })
  var source = PolicyCanvasPortEndpoint(
    nodeID: edge.fromNodeId,
    portID: policyCanvasImportedPortID(edge.fromPort, node: sourceNode, kind: .output),
    kind: .output
  )
  var target = PolicyCanvasPortEndpoint(
    nodeID: edge.toNodeId,
    portID: policyCanvasImportedPortID(edge.toPort, node: targetNode, kind: .input),
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
    kind: kind,
    reasonCode: edge.condition.reasonCode
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
  adjustedEdge.pinnedPortSide =
    preservesPinnedState
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
  let sourcePortID = policyCanvasImportedPortID(edge.fromPort, node: sourceNode, kind: .output)
  let targetPortID = policyCanvasImportedPortID(edge.toPort, node: targetNode, kind: .input)
  return sourceNode.outputPorts.contains { $0.id == sourcePortID }
    && targetNode.inputPorts.contains { $0.id == targetPortID }
}

func taskBoardPolicyNode(
  _ node: PolicyCanvasNode,
  originalKind: TaskBoardPolicyPipelineNodeKind? = nil
) -> TaskBoardPolicyPipelineNode {
  let exportedKind = node.policyKind ?? originalKind ?? taskBoardPolicyNodeKind(for: node.kind)
  return TaskBoardPolicyPipelineNode(
    id: node.id,
    title: node.title,
    kind: exportedKind,
    automation: node.automationBinding,
    position: TaskBoardPolicyCanvasPoint(
      x: Double(node.position.x),
      y: Double(node.position.y)
    ),
    groupId: node.groupID,
    inputs: node.inputPorts.map { port in
      taskBoardPolicyPort(port, nodeKind: exportedKind, kind: .input)
    },
    outputs: node.outputPorts.map { port in
      taskBoardPolicyPort(port, nodeKind: exportedKind, kind: .output)
    }
  )
}

/// Build the daemon edge for a single canvas edge (one branch). Applies the
/// switch-node port persistence and the if_then_else boolean condition export.
/// The merged fan-in expander in `PolicyCanvasModelMapping+Branches.swift` calls
/// this once per branch so a folded wire round-trips to its N daemon edges.
func taskBoardPolicyEdge(
  _ edge: PolicyCanvasEdge,
  sourceNode: PolicyCanvasNode? = nil,
  targetNode: PolicyCanvasNode? = nil,
  originalCondition: TaskBoardPolicyPipelineEdgeCondition? = nil
) -> TaskBoardPolicyPipelineEdge {
  let condition = policyCanvasExportedEdgeCondition(
    edge,
    sourceNode: sourceNode,
    originalCondition: originalCondition
  )
  return TaskBoardPolicyPipelineEdge(
    id: edge.id,
    fromNodeId: edge.source.nodeID,
    fromPort: taskBoardPolicyPersistedPortID(
      edge.source.portID,
      node: sourceNode,
      kind: .output
    ),
    toNodeId: edge.target.nodeID,
    toPort: taskBoardPolicyPersistedPortID(
      edge.target.portID,
      node: targetNode,
      kind: .input
    ),
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
  PolicyCanvasNodeKind(rawValue: kind.kind)
    ?? {
      switch kind.kind {
      case "human_gate", "consensus_gate":
        .humanGate
      case "supervisor_rule":
        .supervisorRule
      case "finish":
        .finish
      case "trigger":
        .trigger
      default:
        .evidenceCheck
      }
    }()
}

private func policyCanvasPort(
  _ port: TaskBoardPolicyPipelinePort,
  nodeKind: TaskBoardPolicyPipelineNodeKind,
  kind: PolicyCanvasPortKind
) -> PolicyCanvasPort {
  let title = policyCanvasImportedPortTitle(port.title, nodeKind: nodeKind, kind: kind)
  return PolicyCanvasPort(
    id: policyCanvasImportedPortID(port.id, title: title, nodeKind: nodeKind, kind: kind),
    title: title,
    kind: kind
  )
}

private func taskBoardPolicyPort(
  _ port: PolicyCanvasPort,
  nodeKind: TaskBoardPolicyPipelineNodeKind,
  kind: PolicyCanvasPortKind
) -> TaskBoardPolicyPipelinePort {
  return TaskBoardPolicyPipelinePort(
    id: taskBoardPolicyPersistedPortID(port.id, title: port.title, nodeKind: nodeKind, kind: kind),
    title: port.title
  )
}

private func policyCanvasImportedPortID(
  _ portID: String,
  node: PolicyCanvasNode?,
  kind: PolicyCanvasPortKind
) -> String {
  guard let node, policyCanvasUsesSwitchPortNormalization(node) else {
    return portID
  }
  let ports = kind == .input ? node.inputPorts : node.outputPorts
  if let title = ports.first(where: { $0.id == portID })?.title {
    return policyCanvasPortID(title: title, kind: kind)
  }
  return policyCanvasPortID(
    title: taskBoardPolicyPersistedPortTitle(portID, kind: kind),
    kind: kind
  )
}

private func policyCanvasImportedPortID(
  _ portID: String,
  title: String,
  nodeKind: TaskBoardPolicyPipelineNodeKind,
  kind: PolicyCanvasPortKind
) -> String {
  guard taskBoardPolicyUsesSwitchPortNormalization(nodeKind) else {
    return portID
  }
  return policyCanvasPortID(title: title, kind: kind)
}

private func policyCanvasImportedPortTitle(
  _ title: String,
  nodeKind: TaskBoardPolicyPipelineNodeKind,
  kind: PolicyCanvasPortKind
) -> String {
  guard taskBoardPolicyUsesSwitchPortNormalization(nodeKind) else {
    return title
  }
  return taskBoardPolicyPersistedPortTitle(title, kind: kind)
}

private func taskBoardPolicyPersistedPortID(
  _ portID: String,
  node: PolicyCanvasNode?,
  kind: PolicyCanvasPortKind
) -> String {
  guard let node, policyCanvasUsesSwitchPortNormalization(node) else {
    return portID
  }
  let ports = kind == .input ? node.inputPorts : node.outputPorts
  return ports.first(where: { $0.id == portID })?.title
    ?? taskBoardPolicyPersistedPortTitle(portID, kind: kind)
}

private func taskBoardPolicyPersistedPortID(
  _ portID: String,
  title: String,
  nodeKind: TaskBoardPolicyPipelineNodeKind,
  kind: PolicyCanvasPortKind
) -> String {
  guard taskBoardPolicyUsesSwitchPortNormalization(nodeKind) else {
    return portID
  }
  return title
}

private func taskBoardPolicyPersistedPortTitle(
  _ portID: String,
  kind: PolicyCanvasPortKind
) -> String {
  let prefix = "\(kind.rawValue)-"
  guard portID.hasPrefix(prefix) else {
    return portID
  }
  return String(portID.dropFirst(prefix.count))
}

private func policyCanvasPortID(
  title: String,
  kind: PolicyCanvasPortKind
) -> String {
  "\(kind.rawValue)-\(title)"
}

private func policyCanvasUsesSwitchPortNormalization(_ node: PolicyCanvasNode) -> Bool {
  node.kind == .switch || taskBoardPolicyUsesSwitchPortNormalization(node.policyKind)
}

private func taskBoardPolicyUsesSwitchPortNormalization(
  _ nodeKind: TaskBoardPolicyPipelineNodeKind?
) -> Bool {
  nodeKind?.kind == PolicyCanvasNodeKind.switch.rawValue
}
