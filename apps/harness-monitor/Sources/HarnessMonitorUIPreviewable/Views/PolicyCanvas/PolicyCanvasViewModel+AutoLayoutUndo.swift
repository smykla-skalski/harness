import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasViewModel {
  func applyReflowLayout(
    nodeChanges: [PolicyCanvasReflowNodeChange],
    edgeChanges: [PolicyCanvasEdgeReflowChange],
    fromRoutingHints: PolicyCanvasLayoutRoutingHints?,
    toRoutingHints: PolicyCanvasLayoutRoutingHints?
  ) -> PolicyCanvasChange {
    let nodeIndicesByID = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
    for change in nodeChanges {
      guard let index = nodeIndicesByID[change.id] else {
        continue
      }
      nodes[index].position = change.toPosition
      nodes[index].layoutSource = change.toLayoutSource
    }

    let edgeIndicesByID = Dictionary(uniqueKeysWithValues: edges.enumerated().map { ($1.id, $0) })
    for change in edgeChanges {
      guard let index = edgeIndicesByID[change.id] else {
        continue
      }
      edges[index] = change.to
    }

    routingHints = toRoutingHints
    reconcileGroupFrames()
    clearTransientGestureState()

    let inverseNodeChanges = nodeChanges.map { change in
      PolicyCanvasReflowNodeChange(
        id: change.id,
        fromPosition: change.toPosition,
        toPosition: change.fromPosition,
        fromLayoutSource: change.toLayoutSource,
        toLayoutSource: change.fromLayoutSource
      )
    }
    let inverseEdgeChanges = edgeChanges.map { change in
      PolicyCanvasEdgeReflowChange(
        id: change.id,
        from: change.to,
        to: change.from
      )
    }
    return .reflowLayout(
      nodeChanges: inverseNodeChanges,
      edgeChanges: inverseEdgeChanges,
      fromRoutingHints: toRoutingHints,
      toRoutingHints: fromRoutingHints
    )
  }
}
