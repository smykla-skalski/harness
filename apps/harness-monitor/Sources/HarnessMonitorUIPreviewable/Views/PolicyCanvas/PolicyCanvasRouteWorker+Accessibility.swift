import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasPreparedRouteInput {
  func accessibilityNodeEntries() -> [PolicyCanvasAccessibilityNodeEntry] {
    nodes
      .sorted { left, right in
        let rowDelta = left.position.y - right.position.y
        if abs(rowDelta) >= 10 {
          return rowDelta < 0
        }
        return left.position.x < right.position.x
      }
      .map { node in
        PolicyCanvasAccessibilityNodeEntry(id: node.id, label: node.accessibilityLabel)
      }
  }

  func accessibilityEdgeEntries(
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [PolicyCanvasAccessibilityEdgeEntry] {
    edges.map { edge in
      PolicyCanvasAccessibilityEdgeEntry(
        id: edge.id,
        label: accessibilityLabel(for: edge, nodeIndex: nodeIndex)
      )
    }
  }

  func nodeAccessibilityValuesByID(
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [String: String] {
    let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.title) })
    var outgoingTitlesByNodeID: [String: [String]] = [:]
    var incomingTitlesByNodeID: [String: [String]] = [:]
    for edge in edges {
      if let targetTitle = nodeIndex[edge.target.nodeID]?.title {
        outgoingTitlesByNodeID[edge.source.nodeID, default: []].append(targetTitle)
      }
      if let sourceTitle = nodeIndex[edge.source.nodeID]?.title {
        incomingTitlesByNodeID[edge.target.nodeID, default: []].append(sourceTitle)
      }
    }

    var values: [String: String] = [:]
    values.reserveCapacity(nodes.count)
    for node in nodes {
      var parts: [String] = []
      if let groupID = node.groupID, let groupTitle = groupsByID[groupID] {
        parts.append("group \(groupTitle)")
      }
      if let outgoing = outgoingTitlesByNodeID[node.id], !outgoing.isEmpty {
        parts.append("connects to: \(outgoing.joined(separator: ", "))")
      }
      if let incoming = incomingTitlesByNodeID[node.id], !incoming.isEmpty {
        parts.append("receives from: \(incoming.joined(separator: ", "))")
      }
      let value = parts.joined(separator: ", ")
      if !value.isEmpty {
        values[node.id] = value
      }
    }
    return values
  }

  func connectTargetsByNodeID() -> [String: [PolicyCanvasAccessibilityConnectTarget]] {
    var connectedPairs = Set<String>()
    connectedPairs.reserveCapacity(edges.count)
    for edge in edges {
      connectedPairs.insert(connectPairKey(source: edge.source, target: edge.target))
    }

    var targetsByNodeID: [String: [PolicyCanvasAccessibilityConnectTarget]] = [:]
    targetsByNodeID.reserveCapacity(nodes.count)
    for source in nodes {
      guard let sourcePort = source.outputPorts.first else {
        continue
      }
      let sourceEndpoint = PolicyCanvasPortEndpoint(
        nodeID: source.id,
        portID: sourcePort.id,
        kind: .output
      )
      var targets: [PolicyCanvasAccessibilityConnectTarget] = []
      targets.reserveCapacity(PolicyCanvasAccessibility.connectableTargetActionCap)
      targetLoop: for target in nodes where target.id != source.id {
        for port in target.inputPorts {
          let candidate = PolicyCanvasPortEndpoint(
            nodeID: target.id,
            portID: port.id,
            kind: .input
          )
          guard !connectedPairs.contains(connectPairKey(source: sourceEndpoint, target: candidate))
          else {
            continue
          }
          targets.append(
            PolicyCanvasAccessibilityConnectTarget(
              endpoint: candidate,
              displayName: "\(target.title) \(port.title)"
            )
          )
          if targets.count >= PolicyCanvasAccessibility.connectableTargetActionCap {
            break targetLoop
          }
        }
      }
      if !targets.isEmpty {
        targetsByNodeID[source.id] = targets
      }
    }
    return targetsByNodeID
  }

  private func connectPairKey(
    source: PolicyCanvasPortEndpoint,
    target: PolicyCanvasPortEndpoint
  ) -> String {
    "\(source.nodeID)|\(source.portID)->\(target.nodeID)|\(target.portID)"
  }

  private func accessibilityLabel(
    for edge: PolicyCanvasEdge,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> String {
    let sourceNode = nodeIndex[edge.source.nodeID]
    let targetNode = nodeIndex[edge.target.nodeID]
    let sourcePort = sourceNode?.outputPorts.first { $0.id == edge.source.portID }
    let targetPort = targetNode?.inputPorts.first { $0.id == edge.target.portID }
    let sourcePiece = [sourceNode?.title, sourcePort?.title]
      .compactMap { $0 }
      .joined(separator: " ")
    let targetPiece = [targetNode?.title, targetPort?.title]
      .compactMap { $0 }
      .joined(separator: " ")
    let edgeName = edge.label.isEmpty ? "connection" : edge.label
    if sourcePiece.isEmpty || targetPiece.isEmpty {
      return "\(edgeName) edge"
    }
    return "\(edgeName) edge, from \(sourcePiece) to \(targetPiece)"
  }
}
