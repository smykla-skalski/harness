import SwiftUI

extension PolicyCanvasViewModel {
  var canReflowLayout: Bool {
    nodes.contains { $0.layoutSource == .auto }
  }

  func reflowLayout(preserveManualAnchors: Bool = true) {
    guard !nodes.isEmpty else {
      notifyStatus("Add nodes before reflowing the layout")
      return
    }
    if preserveManualAnchors && !canReflowLayout {
      notifyStatus("All nodes are manually positioned")
      return
    }

    var nextNodes = nodes
    var nextGroups = groups
    guard let result = policyCanvasAutomaticLayoutResult(
      nodes: nextNodes,
      groups: nextGroups,
      edges: edges,
      mode: .explicitReflow(preserveManualAnchors: preserveManualAnchors)
    ) else {
      notifyStatus("Layout could not be reflowed")
      return
    }
    applyPolicyCanvasLayoutResult(
      result,
      nodes: &nextNodes,
      groups: &nextGroups,
      centerInMinimumCanvas: false
    )
    let nextEdges = edges.map { edge in
      policyCanvasApplyingPreferredPortSides(
        edge,
        nodes: nextNodes,
        preservesPinnedState: true
      )
    }

    let currentNodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    let nodeChanges = nextNodes.compactMap { node -> PolicyCanvasReflowNodeChange? in
      guard let current = currentNodesByID[node.id] else {
        return nil
      }
      guard
        current.position != node.position
          || current.layoutSource != node.layoutSource
      else {
        return nil
      }
      return PolicyCanvasReflowNodeChange(
        id: node.id,
        fromPosition: current.position,
        toPosition: node.position,
        fromLayoutSource: current.layoutSource,
        toLayoutSource: node.layoutSource
      )
    }

    let currentEdgesByID = Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0) })
    let edgeChanges = nextEdges.compactMap { edge -> PolicyCanvasEdgeReflowChange? in
      guard let current = currentEdgesByID[edge.id], current != edge else {
        return nil
      }
      return PolicyCanvasEdgeReflowChange(id: edge.id, from: current, to: edge)
    }

    guard !nodeChanges.isEmpty || !edgeChanges.isEmpty else {
      notifyStatus("Layout already matches the current anchors")
      return
    }

    mutate(.reflowLayout(nodeChanges: nodeChanges, edgeChanges: edgeChanges))
  }
}
