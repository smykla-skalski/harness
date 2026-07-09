import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels
import SwiftUI

func policyCanvasNode(
  _ node: PolicyPipelineNode,
  layout: PolicyPipelineLayout
) -> PolicyCanvasNode {
  policyCanvasNode(
    node,
    layoutLookup: PolicyCanvasDocumentLayoutLookup(layout: layout)
  )
}

func policyCanvasNode(
  _ node: PolicyPipelineNode,
  layoutLookup: PolicyCanvasDocumentLayoutLookup
) -> PolicyCanvasNode {
  let layoutNode = layoutLookup.nodeLayout(for: node.id.rawValue)
  let position = layoutNode?.position ?? .zero
  var canvasNode = PolicyCanvasNode(
    id: node.id.rawValue,
    title: node.title,
    kind: policyCanvasKind(for: node.kind),
    position: CGPoint(x: CGFloat(position.x), y: CGFloat(position.y))
  )
  canvasNode.layoutSource = layoutNode?.source
  canvasNode.groupID = node.groupId?.rawValue
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
  element: PolicyPipelineGroup,
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
    id: element.id.rawValue,
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
) -> PolicyCanvasCleanLayout {
  var cleanNodes = nodes
  var cleanGroups = groups
  var layoutMetrics: PolicyCanvasLayoutMetrics?
  var routingHints: PolicyCanvasLayoutRoutingHints?
  var precomputedRoutes: PolicyCanvasPrecomputedRouteSet?
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
      mode: mode
    )
    if let autoLayoutMetrics = autoLayout.metrics {
      layoutMetrics = autoLayoutMetrics
      routingHints = autoLayout.routingHints
      precomputedRoutes = autoLayout.precomputedRoutes
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
    routingHints: normalized.routingHints,
    precomputedRoutes: policyCanvasOffsetPrecomputedRoutes(
      precomputedRoutes,
      from: cleanNodes,
      to: normalized.nodes
    )
  )
}

private func policyCanvasOffsetPrecomputedRoutes(
  _ routes: PolicyCanvasPrecomputedRouteSet?,
  from originalNodes: [PolicyCanvasNode],
  to normalizedNodes: [PolicyCanvasNode]
) -> PolicyCanvasPrecomputedRouteSet? {
  guard let routes else {
    return nil
  }
  let originalPositions = Dictionary(
    uniqueKeysWithValues: originalNodes.map { ($0.id, $0.position) })
  for node in normalizedNodes {
    guard let original = originalPositions[node.id] else {
      continue
    }
    return routes.offsetBy(dx: node.position.x - original.x, dy: node.position.y - original.y)
  }
  return routes
}

func policyCanvasEdge(
  _ edge: PolicyPipelineEdge,
  nodes: [PolicyCanvasNode] = [],
  assignPreferredPortSides: Bool = true
) -> PolicyCanvasEdge? {
  if !nodes.isEmpty {
    return policyCanvasEdge(
      edge,
      nodeLookup: PolicyCanvasNodeLookup(nodes: nodes),
      assignPreferredPortSides: assignPreferredPortSides
    )
  }
  guard policyCanvasEdgeEndpointsExist(edge, nodes: nodes) else {
    return nil
  }
  let sourceNode = nodes.first(where: { $0.id == edge.fromNodeId.rawValue })
  let targetNode = nodes.first(where: { $0.id == edge.toNodeId.rawValue })
  var source = PolicyCanvasPortEndpoint(
    nodeID: edge.fromNodeId.rawValue,
    portID: policyCanvasImportedPortID(edge.fromPort.rawValue, node: sourceNode, kind: .output),
    kind: .output
  )
  var target = PolicyCanvasPortEndpoint(
    nodeID: edge.toNodeId.rawValue,
    portID: policyCanvasImportedPortID(edge.toPort.rawValue, node: targetNode, kind: .input),
    kind: .input
  )
  if assignPreferredPortSides {
    policyCanvasAssignPreferredPortSides(source: &source, target: &target, nodes: nodes)
  }
  let kind = PolicyCanvasEdgeKind.derive(from: edge.condition.condition)
  return PolicyCanvasEdge(
    id: edge.id.rawValue,
    source: source,
    target: target,
    label: policyCanvasEdgeLabel(edge),
    condition: edge.condition.condition,
    pinnedPortSide: source.side != nil || target.side != nil,
    kind: kind,
    reasonCode: edge.condition.reasonCode
  )
}

func policyCanvasEdge(
  _ edge: PolicyPipelineEdge,
  nodeLookup: PolicyCanvasNodeLookup,
  assignPreferredPortSides: Bool = true
) -> PolicyCanvasEdge? {
  guard
    let sourceNode = nodeLookup.node(id: edge.fromNodeId.rawValue),
    let targetNode = nodeLookup.node(id: edge.toNodeId.rawValue)
  else {
    return nil
  }
  let sourcePortID = policyCanvasImportedPortID(
    edge.fromPort.rawValue, node: sourceNode, kind: .output)
  let targetPortID = policyCanvasImportedPortID(
    edge.toPort.rawValue, node: targetNode, kind: .input)
  // An edge maps whenever both endpoint nodes exist - it does not require the
  // resolved port id to be present in the node's declared ports. Terminal port
  // markers are seeded from the edges themselves (see `seededPortMarkerEntries`),
  // so a wire still routes and renders when the document carried no ports (e.g. a
  // casing-stripped decode where `input_ports`/`output_ports` arrived empty).
  // Guarding on port existence here silently dropped those edges.
  var source = PolicyCanvasPortEndpoint(
    nodeID: edge.fromNodeId.rawValue,
    portID: sourcePortID,
    kind: .output
  )
  var target = PolicyCanvasPortEndpoint(
    nodeID: edge.toNodeId.rawValue,
    portID: targetPortID,
    kind: .input
  )
  if assignPreferredPortSides {
    policyCanvasAssignPreferredPortSides(
      source: &source,
      target: &target,
      nodeLookup: nodeLookup
    )
  }
  let kind = PolicyCanvasEdgeKind.derive(from: edge.condition.condition)
  return PolicyCanvasEdge(
    id: edge.id.rawValue,
    source: source,
    target: target,
    label: policyCanvasEdgeLabel(edge),
    condition: edge.condition.condition,
    pinnedPortSide: source.side != nil || target.side != nil,
    kind: kind,
    reasonCode: edge.condition.reasonCode
  )
}

func policyCanvasEdgeEndpointsExist(
  _ edge: PolicyPipelineEdge,
  nodes: [PolicyCanvasNode]
) -> Bool {
  guard !nodes.isEmpty else { return true }
  guard let sourceNode = nodes.first(where: { $0.id == edge.fromNodeId.rawValue }),
    let targetNode = nodes.first(where: { $0.id == edge.toNodeId.rawValue })
  else {
    return false
  }
  let sourcePortID = policyCanvasImportedPortID(
    edge.fromPort.rawValue, node: sourceNode, kind: .output)
  let targetPortID = policyCanvasImportedPortID(
    edge.toPort.rawValue, node: targetNode, kind: .input)
  return sourceNode.outputPorts.contains { $0.id == sourcePortID }
    && targetNode.inputPorts.contains { $0.id == targetPortID }
}

func policyNode(
  _ node: PolicyCanvasNode,
  originalKind: PolicyGraphNodeKind? = nil
) -> PolicyPipelineNode {
  let exportedKind = node.policyKind ?? originalKind ?? policyNodeKind(for: node.kind)
  return PolicyPipelineNode(
    id: PolicyGraphNodeId(node.id),
    title: node.title,
    kind: exportedKind,
    automation: node.automationBinding,
    position: HarnessMonitorKit.PolicyCanvasPoint(
      x: Double(node.position.x),
      y: Double(node.position.y)
    ),
    groupId: node.groupID.map { PolicyGraphGroupId($0) },
    inputs: node.inputPorts.map { port in
      policyPort(port, nodeKind: exportedKind, kind: .input)
    },
    outputs: node.outputPorts.map { port in
      policyPort(port, nodeKind: exportedKind, kind: .output)
    }
  )
}

/// Build the daemon edge for a single canvas edge (one branch). Applies the
/// switch-node port persistence and the if_then_else boolean condition export.
/// The merged fan-in expander in `PolicyCanvasModelMapping+Branches.swift` calls
/// this once per branch so a folded wire round-trips to its N daemon edges.
func policyEdge(
  _ edge: PolicyCanvasEdge,
  sourceNode: PolicyCanvasNode? = nil,
  targetNode: PolicyCanvasNode? = nil,
  originalCondition: PolicyPipelineEdgeCondition? = nil
) -> PolicyPipelineEdge {
  let condition = policyCanvasExportedEdgeCondition(
    edge,
    sourceNode: sourceNode,
    originalCondition: originalCondition
  )
  return PolicyPipelineEdge(
    id: PolicyGraphEdgeId(edge.id),
    fromNodeId: PolicyGraphNodeId(edge.source.nodeID),
    fromPort: PolicyGraphPortId(
      policyPersistedPortID(
        edge.source.portID,
        node: sourceNode,
        kind: .output
      )),
    toNodeId: PolicyGraphNodeId(edge.target.nodeID),
    toPort: PolicyGraphPortId(
      policyPersistedPortID(
        edge.target.portID,
        node: targetNode,
        kind: .input
      )),
    label: edge.label,
    condition: condition
  )
}

func policyGroup(
  _ group: PolicyCanvasGroup,
  nodes: [PolicyCanvasNode]
) -> PolicyPipelineGroup {
  PolicyPipelineGroup(
    id: PolicyGraphGroupId(group.id),
    title: group.title,
    color: group.tone.hexColor,
    frame: HarnessMonitorKit.PolicyCanvasRect(
      x: Double(group.frame.minX),
      y: Double(group.frame.minY),
      width: Double(group.frame.width),
      height: Double(group.frame.height)
    ),
    nodeIds: nodes.filter { $0.groupID == group.id }.map { PolicyGraphNodeId($0.id) }
  )
}

func policyNodeLayout(_ node: PolicyCanvasNode) -> PolicyPipelineNodeLayout {
  PolicyPipelineNodeLayout(
    nodeId: PolicyGraphNodeId(node.id),
    x: Int(node.position.x.rounded()),
    y: Int(node.position.y.rounded()),
    source: node.layoutSource
  )
}
