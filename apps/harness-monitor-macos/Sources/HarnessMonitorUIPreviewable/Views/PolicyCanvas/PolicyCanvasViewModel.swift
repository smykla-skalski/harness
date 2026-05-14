import HarnessMonitorKit
import Observation
import SwiftUI

@MainActor
@Observable
final class PolicyCanvasViewModel {
  var selectedTab: PolicyCanvasTab
  var nodes: [PolicyCanvasNode]
  var groups: [PolicyCanvasGroup]
  var edges: [PolicyCanvasEdge]
  var selection: PolicyCanvasSelection?
  var zoom: CGFloat
  var highlightedGroupID: String?
  var highlightedInput: PolicyCanvasPortEndpoint?
  var lastActionSummary: String
  var backingDocument: TaskBoardPolicyPipelineDocument?
  var latestSimulation: TaskBoardPolicyPipelineSimulationResult?
  var isDirty: Bool
  var hasRequestedInitialRemoteLoad: Bool

  @ObservationIgnored private var nextNodeNumber: Int
  @ObservationIgnored private var loadedDocumentRevision: UInt64?
  @ObservationIgnored private var nodeDragOrigins: [String: CGPoint] = [:]
  @ObservationIgnored private var groupDragOrigins: [String: CGRect] = [:]
  @ObservationIgnored private var groupNodeDragOrigins: [String: [String: CGPoint]] = [:]

  init(
    selectedTab: PolicyCanvasTab = .draft,
    nodes: [PolicyCanvasNode],
    groups: [PolicyCanvasGroup],
    edges: [PolicyCanvasEdge],
    selection: PolicyCanvasSelection? = nil,
    zoom: CGFloat = 0.92,
    nextNodeNumber: Int = 10
  ) {
    self.selectedTab = selectedTab
    self.nodes = nodes
    self.groups = groups
    self.edges = edges
    self.selection = selection
    self.zoom = zoom
    self.lastActionSummary = "No pending changes"
    self.backingDocument = nil
    self.latestSimulation = nil
    self.isDirty = false
    self.hasRequestedInitialRemoteLoad = false
    self.nextNodeNumber = nextNodeNumber
    reconcileGroupFrames()
  }

  var selectedNode: PolicyCanvasNode? {
    guard case .node(let id) = selection else {
      return nil
    }
    return node(id)
  }

  var selectedGroup: PolicyCanvasGroup? {
    guard case .group(let id) = selection else {
      return nil
    }
    return group(id)
  }

  var selectedEdge: PolicyCanvasEdge? {
    guard case .edge(let id) = selection else {
      return nil
    }
    return edges.first { $0.id == id }
  }

  var selectedTitle: String {
    if let selectedNode {
      return selectedNode.title
    }
    if let selectedGroup {
      return selectedGroup.title
    }
    if let selectedEdge {
      return selectedEdge.label
    }
    return "Canvas"
  }

  var policySummary: String {
    "\(nodes.count) nodes - \(edges.count) edges - \(groups.count) groups"
  }

  var canPromote: Bool {
    promoteDisabledReason == nil
  }

  var promoteDisabledReason: String? {
    guard let backingDocument else {
      return "Save a draft first"
    }
    if isDirty {
      return "Save draft changes first"
    }
    guard let latestSimulation else {
      return "Run simulation first"
    }
    guard latestSimulation.succeeded else {
      return "Fix validation before promotion"
    }
    guard latestSimulation.revision == backingDocument.revision else {
      return "Run simulation for saved revision"
    }
    return nil
  }

  func resetNextNodeNumber() {
    nextNodeNumber = nodes.count + 1
  }

  func markInitialRemoteLoadRequested() -> Bool {
    guard !hasRequestedInitialRemoteLoad else {
      return false
    }
    hasRequestedInitialRemoteLoad = true
    return true
  }

  func shouldApplyExternalDocument(_ document: TaskBoardPolicyPipelineDocument?) -> Bool {
    guard let document else {
      return false
    }
    guard !isDirty else {
      return false
    }
    return loadedDocumentRevision != document.revision || backingDocument?.mode != document.mode
  }

  func markLoadedDocumentRevision(_ revision: UInt64?) {
    loadedDocumentRevision = revision
  }

  func dropPalettePayloads(_ payloads: [String], at point: CGPoint) -> Bool {
    guard
      let payload = payloads.first,
      let kind = parsePalettePayload(payload)
    else {
      return false
    }
    createNode(kind: kind, at: point)
    return true
  }

  func createNode(kind: PolicyCanvasNodeKind, at point: CGPoint) {
    let number = nextNodeNumber
    nextNodeNumber += 1
    var node = PolicyCanvasNode(
      id: "\(kind.rawValue)-\(number)",
      title: "\(kind.title) \(number)",
      kind: kind,
      position: snapped(
        CGPoint(
          x: point.x - PolicyCanvasLayout.nodeSize.width / 2,
          y: point.y - PolicyCanvasLayout.nodeSize.height / 2
        )
      )
    )
    node.groupID = containingGroupID(for: nodeCenter(node))
    node.policyKind = taskBoardPolicyNodeKind(for: kind)
    nodes.append(node)
    reconcileGroupFrames()
    selection = .node(node.id)
    isDirty = true
    lastActionSummary = "\(kind.title) node added"
  }

  func dragNode(_ nodeID: String, translation: CGSize) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else {
      return
    }
    if nodeDragOrigins[nodeID] == nil {
      nodeDragOrigins[nodeID] = nodes[index].position
    }
    let origin = nodeDragOrigins[nodeID] ?? nodes[index].position
    nodes[index].position = snapped(
      CGPoint(
        x: origin.x + translation.width / zoom,
        y: origin.y + translation.height / zoom
      )
    )
    highlightedGroupID =
      containingGroupID(for: nodeCenter(nodes[index]), excluding: nodes[index].groupID)
      ?? nodes[index].groupID
    reconcileGroupFrames()
    selection = .node(nodeID)
    isDirty = true
  }

  func endNodeDrag(_ nodeID: String, translation: CGSize) {
    dragNode(nodeID, translation: translation)
    if let index = nodes.firstIndex(where: { $0.id == nodeID }) {
      let targetGroupID = containingGroupID(
        for: nodeCenter(nodes[index]),
        excluding: nodes[index].groupID
      )
      if let targetGroupID {
        nodes[index].groupID = targetGroupID
      } else if nodes[index].groupID == nil {
        nodes[index].groupID = containingGroupID(for: nodeCenter(nodes[index]))
      }
    }
    reconcileGroupFrames()
    nodeDragOrigins[nodeID] = nil
    highlightedGroupID = nil
  }

  func dragGroup(_ groupID: String, translation: CGSize) {
    guard let index = groups.firstIndex(where: { $0.id == groupID }) else {
      return
    }
    seedGroupDrag(groupID: groupID, group: groups[index])
    let origin = groupDragOrigins[groupID] ?? groups[index].frame
    let nextOrigin = snapped(
      CGPoint(
        x: origin.origin.x + translation.width / zoom,
        y: origin.origin.y + translation.height / zoom
      )
    )
    let delta = CGSize(
      width: nextOrigin.x - origin.origin.x,
      height: nextOrigin.y - origin.origin.y
    )
    groups[index].frame.origin = nextOrigin
    moveNodes(in: groupID, by: delta)
    reconcileGroupFrames()
    highlightedGroupID = groupID
    selection = .group(groupID)
    isDirty = true
  }

  func endGroupDrag(_ groupID: String, translation: CGSize) {
    dragGroup(groupID, translation: translation)
    groupDragOrigins[groupID] = nil
    groupNodeDragOrigins[groupID] = nil
    highlightedGroupID = nil
  }

  func setInputTargeted(
    _ targeted: Bool,
    nodeID: String,
    portID: String
  ) {
    if targeted {
      highlightedInput = PolicyCanvasPortEndpoint(
        nodeID: nodeID,
        portID: portID,
        kind: .input
      )
    } else {
      highlightedInput = nil
    }
  }

  func connectDroppedPortPayloads(
    _ payloads: [String],
    targetNodeID: String,
    targetPortID: String
  ) -> Bool {
    guard let source = payloads.compactMap(parseOutputPortPayload).first else {
      return false
    }
    guard source.nodeID != targetNodeID else {
      highlightedInput = nil
      return false
    }
    let target = PolicyCanvasPortEndpoint(
      nodeID: targetNodeID,
      portID: targetPortID,
      kind: .input
    )
    guard !edges.contains(where: { $0.source == source && $0.target == target }) else {
      highlightedInput = nil
      return true
    }
    let edge = PolicyCanvasEdge(
      id: "edge-\(source.nodeID)-\(source.portID)-\(target.nodeID)-\(target.portID)",
      source: source,
      target: target,
      label: edgeLabel(source: source, target: target)
    )
    edges.append(edge)
    selection = .edge(edge.id)
    highlightedInput = nil
    isDirty = true
    lastActionSummary = "Edge created"
    return true
  }

  func portAnchor(for endpoint: PolicyCanvasPortEndpoint) -> CGPoint? {
    guard let node = node(endpoint.nodeID) else {
      return nil
    }
    let ports = endpoint.kind == .input ? node.inputPorts : node.outputPorts
    guard let index = ports.firstIndex(where: { $0.id == endpoint.portID }) else {
      return nil
    }
    let x =
      endpoint.kind == .input
      ? node.position.x
      : node.position.x + PolicyCanvasLayout.nodeSize.width
    return CGPoint(
      x: x,
      y: node.position.y + PolicyCanvasLayout.portY(index: index, count: ports.count)
    )
  }

  func node(_ id: String) -> PolicyCanvasNode? {
    nodes.first { $0.id == id }
  }

  func group(_ id: String) -> PolicyCanvasGroup? {
    groups.first { $0.id == id }
  }

  func nodes(in groupID: String) -> [PolicyCanvasNode] {
    nodes.filter { $0.groupID == groupID }
  }

  func reconcileGroupFrames() {
    for index in groups.indices {
      let members = nodes(in: groups[index].id)
      guard let frame = policyCanvasGroupFrame(containing: members) else {
        continue
      }
      groups[index].frame = frame
    }
  }

  private func seedGroupDrag(groupID: String, group: PolicyCanvasGroup) {
    if groupDragOrigins[groupID] == nil {
      groupDragOrigins[groupID] = group.frame
      let origins = nodes(in: groupID).map { ($0.id, $0.position) }
      groupNodeDragOrigins[groupID] = Dictionary(uniqueKeysWithValues: origins)
    }
  }

  private func moveNodes(in groupID: String, by delta: CGSize) {
    let origins = groupNodeDragOrigins[groupID] ?? [:]
    for index in nodes.indices where nodes[index].groupID == groupID {
      guard let origin = origins[nodes[index].id] else {
        continue
      }
      nodes[index].position = snapped(
        CGPoint(x: origin.x + delta.width, y: origin.y + delta.height)
      )
    }
  }

  private func nodeCenter(_ node: PolicyCanvasNode) -> CGPoint {
    CGPoint(
      x: node.position.x + PolicyCanvasLayout.nodeSize.width / 2,
      y: node.position.y + PolicyCanvasLayout.nodeSize.height / 2
    )
  }

  private func containingGroupID(
    for point: CGPoint,
    excluding excludedID: String? = nil
  ) -> String? {
    groups.first { group in
      group.id != excludedID && group.frame.contains(point)
    }?.id
  }

  private func snapped(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: (point.x / PolicyCanvasLayout.gridSize).rounded() * PolicyCanvasLayout.gridSize,
      y: (point.y / PolicyCanvasLayout.gridSize).rounded() * PolicyCanvasLayout.gridSize
    )
  }

  private func parsePalettePayload(_ payload: String) -> PolicyCanvasNodeKind? {
    let parts = payload.split(separator: "|").map(String.init)
    guard parts.count == 2, parts[0] == "policy-canvas-palette" else {
      return nil
    }
    return PolicyCanvasNodeKind(rawValue: parts[1])
  }

  private func parseOutputPortPayload(_ payload: String) -> PolicyCanvasPortEndpoint? {
    let parts = payload.split(separator: "|").map(String.init)
    guard parts.count == 3, parts[0] == "policy-canvas-port" else {
      return nil
    }
    return PolicyCanvasPortEndpoint(nodeID: parts[1], portID: parts[2], kind: .output)
  }

  private func edgeLabel(
    source: PolicyCanvasPortEndpoint,
    target: PolicyCanvasPortEndpoint
  ) -> String {
    let sourcePort = node(source.nodeID)?.outputPorts.first { $0.id == source.portID }
    let targetPort = node(target.nodeID)?.inputPorts.first { $0.id == target.portID }
    return [sourcePort?.title, targetPort?.title]
      .compactMap { $0 }
      .joined(separator: " -> ")
  }

}
