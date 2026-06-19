// Spatial frame index and label-clearance helpers extracted from
// PolicyCanvasEdgeLabelPlacement+Support to satisfy the file-length limit.
import CoreGraphics
import Foundation

struct PolicyCanvasIndexedLabelFrame {
  let ownerID: String
  let frame: CGRect
}

struct PolicyCanvasLabelFrameIndex {
  private let cellSize: CGFloat
  private var cells: [Cell: [StoredFrame]]
  private var nextFrameID: Int

  init(
    entries: [PolicyCanvasIndexedLabelFrame],
    cellSize: CGFloat = PolicyCanvasLayout.nodeSize.width
  ) {
    self.cellSize = max(cellSize, 1)
    cells = [:]
    nextFrameID = 0
    for entry in entries {
      insert(entry)
    }
  }

  mutating func insert(_ entry: PolicyCanvasIndexedLabelFrame) {
    guard !entry.frame.isNull else {
      return
    }
    let stored = StoredFrame(
      id: nextFrameID,
      ownerID: entry.ownerID,
      frame: entry.frame
    )
    nextFrameID += 1
    for cell in cellsIntersecting(entry.frame) {
      cells[cell, default: []].append(stored)
    }
  }

  func frames(
    intersecting rect: CGRect,
    excluding ownerID: String? = nil
  ) -> [CGRect] {
    guard !rect.isNull else {
      return []
    }
    var seen: Set<Int> = []
    var result: [CGRect] = []
    for cell in cellsIntersecting(rect) {
      for entry in cells[cell, default: []] where entry.ownerID != ownerID {
        guard entry.frame.intersects(rect) else {
          continue
        }
        guard seen.insert(entry.id).inserted else {
          continue
        }
        result.append(entry.frame)
      }
    }
    return result
  }

  private func cellsIntersecting(_ rect: CGRect) -> [Cell] {
    guard !rect.isNull else {
      return []
    }
    let minX = Int(floor(rect.minX / cellSize))
    let maxX = Int(floor(rect.maxX / cellSize))
    let minY = Int(floor(rect.minY / cellSize))
    let maxY = Int(floor(rect.maxY / cellSize))
    var result: [Cell] = []
    result.reserveCapacity(max(0, (maxX - minX + 1) * (maxY - minY + 1)))
    for x in minX...maxX {
      for y in minY...maxY {
        result.append(Cell(x: x, y: y))
      }
    }
    return result
  }

  private struct Cell: Hashable {
    let x: Int
    let y: Int
  }

  private struct StoredFrame {
    let id: Int
    let ownerID: String
    let frame: CGRect
  }
}

func policyCanvasFirstClearLabelCandidate(
  _ candidates: [CGPoint],
  size: CGSize,
  obstacleFrames: PolicyCanvasLabelObstacleFrames,
  requiresGraphHull: Bool
) -> CGPoint? {
  for candidate in candidates {
    let frame = policyCanvasLabelFrame(center: candidate, size: size)
    guard policyCanvasLabelFrameIsClear(frame, obstacleFrames: obstacleFrames) else {
      continue
    }
    if requiresGraphHull, !policyCanvasFitsGraphHull(frame, obstacleFrames: obstacleFrames) {
      continue
    }
    return candidate
  }
  return nil
}

func policyCanvasLeastBadGraphHullCandidate(
  _ candidates: [CGPoint],
  size: CGSize,
  obstacleFrames: PolicyCanvasLabelObstacleFrames,
  lineBlockers: [CGRect],
  fallback: CGPoint
) -> CGPoint? {
  let inHullCandidates = candidates.filter { candidate in
    policyCanvasFitsGraphHull(
      policyCanvasLabelFrame(center: candidate, size: size),
      obstacleFrames: obstacleFrames
    )
  }
  guard !inHullCandidates.isEmpty else {
    return nil
  }
  return policyCanvasLeastBadLabelCandidate(
    inHullCandidates,
    size: size,
    nodeFrames: obstacleFrames.nodes,
    lineBlockers: lineBlockers,
    fallback: fallback
  )
}

func policyCanvasLabelFrameIsClear(
  _ frame: CGRect,
  obstacleFrames: PolicyCanvasLabelObstacleFrames
) -> Bool {
  !obstacleFrames.occupied.contains(where: { $0.intersects(frame) })
    && !obstacleFrames.nodes.contains(where: { $0.intersects(frame) })
    && !obstacleFrames.routes.contains(where: { $0.intersects(frame) })
}

func policyCanvasFitsGraphHull(
  _ frame: CGRect,
  obstacleFrames: PolicyCanvasLabelObstacleFrames
) -> Bool {
  guard let graphHull = obstacleFrames.graphHull else {
    return true
  }
  return graphHull.contains(frame)
}
