// Companion to PolicyCanvasViewModel+AutoLayout.swift.
// Canonical reflow-signature helpers used to detect fixed-point forced
// reformats and compare successive layout snapshots.
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasViewModel {
  func isCurrentCanonicalForcedReflow() -> Bool {
    guard let lastCanonicalForcedReflowSignature else {
      return false
    }
    return lastCanonicalForcedReflowSignature
      == canonicalForcedReflowSignature(
        nodes: nodes,
        groups: groups,
        edges: edges,
        routingHints: routingHints
      )
  }

  func reflowSnapshotSignature(_ snapshot: PolicyCanvasReflowSnapshot) -> String {
    canonicalForcedReflowSignature(
      nodes: snapshot.nodes,
      groups: snapshot.groups,
      edges: snapshot.edges,
      routingHints: snapshot.routingHints
    )
  }

  func canonicalForcedReflowSignature(
    nodes: [PolicyCanvasNode],
    groups: [PolicyCanvasGroup],
    edges: [PolicyCanvasEdge],
    routingHints: PolicyCanvasLayoutRoutingHints?
  ) -> String {
    var parts: [String] = []
    parts.reserveCapacity(nodes.count + groups.count + edges.count + 1)
    parts.append("a:\(String(describing: algorithmSelection))")
    for node in nodes.sorted(by: { $0.id < $1.id }) {
      let layoutSource = node.layoutSource.map { String(describing: $0) } ?? "nil"
      parts.append(
        "n:\(node.id):\(reflowSignatureCoordinate(node.position.x)):"
          + "\(reflowSignatureCoordinate(node.position.y)):\(layoutSource)"
      )
    }
    for group in groups.sorted(by: { $0.id < $1.id }) {
      parts.append(
        "g:\(group.id):\(reflowSignatureCoordinate(group.frame.minX)):"
          + "\(reflowSignatureCoordinate(group.frame.minY)):"
          + "\(reflowSignatureCoordinate(group.frame.width)):"
          + "\(reflowSignatureCoordinate(group.frame.height))"
      )
    }
    for edge in edges.sorted(by: { $0.id < $1.id }) {
      let sourceSide = edge.source.side.map { String(describing: $0) } ?? "nil"
      let targetSide = edge.target.side.map { String(describing: $0) } ?? "nil"
      parts.append(
        "e:\(edge.id):\(sourceSide):\(targetSide):\(edge.pinnedPortSide)"
      )
    }
    for (edgeID, hint) in (routingHints?.edgeHints ?? [:]).sorted(by: { $0.key < $1.key }) {
      parts.append(
        "h:\(edgeID):\(hint.key.sourceScopeID):\(hint.key.targetScopeID):"
          + "\(hint.key.targetNodeID):\(hint.key.label):\(hint.key.laneIndex):"
          + "\(reflowSignatureCoordinate(hint.horizontalLaneY)):"
          + "\(hint.verticalLaneX.map(reflowSignatureCoordinate) ?? "nil"):"
          + "\(hint.bundleOrdinal):\(hint.bundleSize)"
      )
    }
    return parts.joined(separator: "|")
  }

  func reflowSignatureCoordinate(_ value: CGFloat) -> String {
    String(Int(value.rounded()))
  }
}
