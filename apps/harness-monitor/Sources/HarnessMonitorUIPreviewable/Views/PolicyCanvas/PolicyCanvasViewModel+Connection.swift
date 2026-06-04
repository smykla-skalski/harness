import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasViewModel {
  func dropPalettePayloads(_ payloads: [String], at point: CGPoint) -> Bool {
    guard
      let payload = payloads.first,
      let parsedPayload = parseComponentPalettePayload(payload)
    else {
      return false
    }
    switch parsedPayload {
    case .kind(let kind):
      createNode(kind: kind, at: point)
    case .automation(let item):
      createAutomationNode(item: item, at: point)
    }
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
    let priorSelection = selection
    mutate(.addNode(node, restoreSelection: priorSelection))
  }

  func setInputTargeted(
    _ targeted: Bool,
    nodeID: String,
    portID: String,
    side: PolicyCanvasPortSide? = nil
  ) {
    if targeted {
      highlightedInput = PolicyCanvasPortEndpoint(
        nodeID: nodeID,
        portID: portID,
        kind: .input,
        side: side
      )
    } else {
      highlightedInput = nil
    }
  }

  func connectDroppedPortPayloads(
    _ payloads: [String],
    targetNodeID: String,
    targetPortID: String,
    targetSide: PolicyCanvasPortSide? = nil
  ) -> Bool {
    guard let source = payloads.compactMap(parseOutputPortPayload).first else {
      clearPendingEdge()
      return false
    }
    guard source.nodeID != targetNodeID else {
      clearPendingEdge()
      return false
    }
    let target = PolicyCanvasPortEndpoint(
      nodeID: targetNodeID,
      portID: targetPortID,
      kind: .input,
      side: targetSide
    )
    // A second drag onto a tuple that already has a wire is not a duplicate to
    // drop - it is the author adding another reason-code branch on the same
    // source -> target transition. Fold it into the existing wire so the
    // one-edge-per-tuple invariant holds and the merge stays the routing unit.
    if let existing = edges.first(where: { $0.source == source && $0.target == target }) {
      clearPendingEdge()
      addBranch(toEdgeID: existing.id)
      return true
    }
    let edge = PolicyCanvasEdge(
      id: "edge-\(source.nodeID)-\(source.portID)-\(target.nodeID)-\(target.portID)",
      source: source,
      target: target,
      label: edgeLabel(source: source, target: target)
    )
    let priorSelection = selection
    clearPendingEdge()
    mutate(.addEdge(edge, restoreSelection: priorSelection))
    return true
  }

  func parsePalettePayload(_ payload: String) -> PolicyCanvasNodeKind? {
    let parts = payload.split(separator: "|").map(String.init)
    guard parts.count == 2, parts[0] == "policy-canvas-palette" else {
      return nil
    }
    return PolicyCanvasNodeKind(rawValue: parts[1])
  }

  func parseAutomationPalettePayload(_ payload: String) -> PolicyCanvasAutomationPaletteItem? {
    let parts = payload.split(separator: "|").map(String.init)
    guard parts.count == 2, parts[0] == "policy-canvas-automation-palette" else {
      return nil
    }
    return PolicyCanvasAutomationPaletteItem(rawValue: parts[1])
  }

  private func parseComponentPalettePayload(
    _ payload: String
  ) -> PolicyCanvasComponentPalettePayload? {
    if let kind = parsePalettePayload(payload) {
      return .kind(kind)
    }
    if let item = parseAutomationPalettePayload(payload) {
      return .automation(item)
    }
    return nil
  }

  func parseOutputPortPayload(_ payload: String) -> PolicyCanvasPortEndpoint? {
    let parts = payload.split(separator: "|").map(String.init)
    guard parts.count == 3 || parts.count == 4, parts[0] == "policy-canvas-port" else {
      return nil
    }
    let side = parts.count == 4 ? PolicyCanvasPortSide(rawValue: parts[3]) : nil
    return PolicyCanvasPortEndpoint(
      nodeID: parts[1],
      portID: parts[2],
      kind: .output,
      side: side
    )
  }

  func edgeLabel(
    source: PolicyCanvasPortEndpoint,
    target: PolicyCanvasPortEndpoint
  ) -> String {
    let sourcePort = node(source.nodeID)?.outputPorts.first { $0.id == source.portID }
    let targetPort = node(target.nodeID)?.inputPorts.first { $0.id == target.portID }
    return [sourcePort?.title, targetPort?.title]
      .compactMap { $0 }
      .joined(separator: " -> ")
  }

  func markNodeEdited(_ nodeID: String) {
    cleanEphemeralNodeIDs.remove(nodeID)
  }

  func markNodeManualLayout(_ nodeID: String) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else {
      return
    }
    guard nodes[index].layoutSource != .manual else {
      return
    }
    nodes[index].layoutSource = .manual
  }

  func markEdgeEdited(_ edgeID: String) {
    cleanEphemeralEdgeIDs.remove(edgeID)
  }

  func resetCleanEphemeralComponents() {
    cleanEphemeralNodeIDs.removeAll()
    cleanEphemeralEdgeIDs.removeAll()
  }
}

private enum PolicyCanvasComponentPalettePayload {
  case kind(PolicyCanvasNodeKind)
  case automation(PolicyCanvasAutomationPaletteItem)
}
