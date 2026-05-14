import SwiftUI

extension PolicyCanvasViewModel {
  func accessibilityLabel(for node: PolicyCanvasNode) -> String {
    "\(node.kind.title) \(node.title)"
  }

  func accessibilityValue(for node: PolicyCanvasNode) -> String {
    var parts: [String] = []
    if let groupID = node.groupID, let group = group(groupID) {
      parts.append("group \(group.title)")
    }
    let outgoing = connectedTitles(for: node.id, direction: .outgoing)
    if !outgoing.isEmpty {
      parts.append("connects to: \(outgoing.joined(separator: ", "))")
    }
    let incoming = connectedTitles(for: node.id, direction: .incoming)
    if !incoming.isEmpty {
      parts.append("receives from: \(incoming.joined(separator: ", "))")
    }
    return parts.joined(separator: ", ")
  }

  private enum EdgeDirection {
    case outgoing
    case incoming
  }

  private func connectedTitles(for nodeID: String, direction: EdgeDirection) -> [String] {
    edges.compactMap { edge in
      switch direction {
      case .outgoing:
        return edge.source.nodeID == nodeID ? self.node(edge.target.nodeID)?.title : nil
      case .incoming:
        return edge.target.nodeID == nodeID ? self.node(edge.source.nodeID)?.title : nil
      }
    }
  }

  func accessibilityLabel(for edge: PolicyCanvasEdge) -> String {
    let sourceNode = node(edge.source.nodeID)
    let targetNode = node(edge.target.nodeID)
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
      return "Edge \(edgeName)"
    }
    return "Edge \(edgeName), from \(sourcePiece) to \(targetPiece)"
  }
}
