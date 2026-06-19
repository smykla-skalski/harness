import Foundation
import SwiftUI

// Member-level ordering helpers for unconstrained layered layout.

extension PolicyCanvasLayeredLayoutEngine {
  func unconstrainedPlacedNeighborCenters(
    memberIDs: [String],
    edges: [PolicyCanvasLayoutEdge],
    nodePositions: [String: CGPoint]
  ) -> [String: CGFloat] {
    memberIDs.reduce(into: [:]) { partial, nodeID in
      let neighborCenters = edges.compactMap { edge -> CGFloat? in
        if edge.targetNodeID == nodeID, let sourcePosition = nodePositions[edge.sourceNodeID] {
          return sourcePosition.y + (PolicyCanvasLayout.nodeSize.height / 2)
        }
        if edge.sourceNodeID == nodeID, let targetPosition = nodePositions[edge.targetNodeID] {
          return targetPosition.y + (PolicyCanvasLayout.nodeSize.height / 2)
        }
        return nil
      }
      guard !neighborCenters.isEmpty else {
        return
      }
      partial[nodeID] = neighborCenters.reduce(CGFloat.zero, +) / CGFloat(neighborCenters.count)
    }
  }

  func unconstrainedMemberPrecedes(
    leftID: String,
    rightID: String,
    tables: PolicyCanvasMemberOrderingTables
  ) -> Bool {
    let leftRank = tables.internalRanks[leftID] ?? 0
    let rightRank = tables.internalRanks[rightID] ?? 0
    if leftRank != rightRank {
      return leftRank < rightRank
    }
    let leftPlacedCenterY = tables.placedNeighborCenterY[leftID]
    let rightPlacedCenterY = tables.placedNeighborCenterY[rightID]
    if let leftPlacedCenterY, let rightPlacedCenterY,
      abs(leftPlacedCenterY - rightPlacedCenterY) >= (PolicyCanvasLayout.gridSize / 2)
    {
      return leftPlacedCenterY < rightPlacedCenterY
    }
    let leftCenterY = tables.itemCenterY[leftID] ?? 0
    let rightCenterY = tables.itemCenterY[rightID] ?? 0
    if abs(leftCenterY - rightCenterY) >= (PolicyCanvasLayout.gridSize / 2) {
      return leftCenterY < rightCenterY
    }
    return (tables.orderHints[leftID] ?? .zero) < (tables.orderHints[rightID] ?? .zero)
  }
}
