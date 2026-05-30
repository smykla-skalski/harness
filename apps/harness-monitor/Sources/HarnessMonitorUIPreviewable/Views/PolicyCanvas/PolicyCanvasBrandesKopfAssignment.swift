import CoreGraphics
import Foundation

// Brandes & Köpf, "Fast and Simple Horizontal Coordinate Assignment" (2001).
// Adapted for a layered graph whose layers run left-to-right in this app's
// canvas; the algorithm's "horizontal coordinate" output therefore becomes
// the Y coordinate of each item.

func policyCanvasBrandesKopfYAssignment(
  layers: [[String]],
  graph: PolicyCanvasLayeredOrderingGraph,
  rowStep: CGFloat
) -> [String: CGFloat] {
  guard !layers.isEmpty else {
    return [:]
  }

  let positions = policyCanvasBKBuildPositions(layers: layers)
  let conflicts = policyCanvasBKMarkType1Conflicts(
    layers: layers,
    graph: graph,
    positions: positions
  )

  var perDirectionAssignments: [[String: CGFloat]] = []
  perDirectionAssignments.reserveCapacity(PolicyCanvasBKDirection.allCases.count)
  for direction in PolicyCanvasBKDirection.allCases {
    let alignment = policyCanvasBKVerticalAlignment(
      layers: layers,
      graph: graph,
      conflicts: conflicts,
      positions: positions,
      direction: direction
    )
    let coords = policyCanvasBKHorizontalCompaction(
      layers: layers,
      positions: positions,
      alignment: alignment,
      direction: direction,
      rowStep: rowStep
    )
    perDirectionAssignments.append(coords)
  }

  return policyCanvasBKBalance(
    assignments: perDirectionAssignments,
    allNodeIDs: layers.flatMap { $0 }
  )
}

enum PolicyCanvasBKDirection: CaseIterable {
  case upLeft
  case upRight
  case downLeft
  case downRight

  var traversesLayersTopFirst: Bool {
    self == .upLeft || self == .upRight
  }

  var prefersLeftmostNeighbor: Bool {
    self == .upLeft || self == .downLeft
  }
}

struct PolicyCanvasBKPosition: Equatable {
  let layer: Int
  let index: Int
}

struct PolicyCanvasBKEdgeKey: Hashable {
  let source: String
  let target: String
}

struct PolicyCanvasBKAlignment {
  let root: [String: String]
  let align: [String: String]
}

func policyCanvasBKBuildPositions(layers: [[String]]) -> [String: PolicyCanvasBKPosition] {
  var positions: [String: PolicyCanvasBKPosition] = [:]
  for (layerIndex, layer) in layers.enumerated() {
    for (itemIndex, itemID) in layer.enumerated() {
      positions[itemID] = PolicyCanvasBKPosition(layer: layerIndex, index: itemIndex)
    }
  }
  return positions
}

func policyCanvasBKMarkType1Conflicts(
  layers: [[String]],
  graph: PolicyCanvasLayeredOrderingGraph,
  positions: [String: PolicyCanvasBKPosition]
) -> Set<PolicyCanvasBKEdgeKey> {
  var conflicts: Set<PolicyCanvasBKEdgeKey> = []
  guard layers.count >= 2 else {
    return conflicts
  }

  for layerIndex in 0..<(layers.count - 1) {
    let upperLayer = layers[layerIndex]
    let lowerLayer = layers[layerIndex + 1]
    var k0 = 0
    var l = 0

    for l1 in 0..<lowerLayer.count {
      let v = lowerLayer[l1]
      let innerSegmentSourceID = policyCanvasBKIncidentInnerSegmentSource(
        itemID: v,
        upperLayer: upperLayer,
        graph: graph
      )
      let isLastInLowerLayer = l1 == lowerLayer.count - 1

      if isLastInLowerLayer || innerSegmentSourceID != nil {
        let k1: Int
        if let innerSource = innerSegmentSourceID, let pos = positions[innerSource] {
          k1 = pos.index
        } else {
          k1 = max(0, upperLayer.count - 1)
        }

        while l <= l1 {
          let vl = lowerLayer[l]
          for u in graph.incoming[vl] ?? [] {
            guard let uPos = positions[u] else {
              continue
            }
            if uPos.layer != layerIndex {
              continue
            }
            if uPos.index < k0 || uPos.index > k1 {
              conflicts.insert(PolicyCanvasBKEdgeKey(source: u, target: vl))
            }
          }
          l += 1
        }
        k0 = k1
      }
    }
  }

  return conflicts
}

private func policyCanvasBKIncidentInnerSegmentSource(
  itemID: String,
  upperLayer: [String],
  graph: PolicyCanvasLayeredOrderingGraph
) -> String? {
  guard graph.itemsByID[itemID]?.isDummy == true else {
    return nil
  }
  for predecessorID in graph.incoming[itemID] ?? [] {
    if graph.itemsByID[predecessorID]?.isDummy == true,
      upperLayer.contains(predecessorID)
    {
      return predecessorID
    }
  }
  return nil
}

func policyCanvasBKVerticalAlignment(
  layers: [[String]],
  graph: PolicyCanvasLayeredOrderingGraph,
  conflicts: Set<PolicyCanvasBKEdgeKey>,
  positions: [String: PolicyCanvasBKPosition],
  direction: PolicyCanvasBKDirection
) -> PolicyCanvasBKAlignment {
  let allNodeIDs = layers.flatMap { $0 }
  var root: [String: String] = [:]
  var align: [String: String] = [:]
  for nodeID in allNodeIDs {
    root[nodeID] = nodeID
    align[nodeID] = nodeID
  }

  let layerOrder: [Int]
  if direction.traversesLayersTopFirst {
    layerOrder = Array(1..<layers.count)
  } else {
    layerOrder = Array((0..<max(0, layers.count - 1)).reversed())
  }

  for layerIndex in layerOrder {
    let currentLayer = layers[layerIndex]
    let traversal: [(Int, String)]
    if direction.prefersLeftmostNeighbor {
      traversal = Array(currentLayer.enumerated())
    } else {
      traversal = Array(currentLayer.enumerated().reversed())
    }

    var rBoundary: Int = direction.prefersLeftmostNeighbor ? -1 : Int.max

    for (_, v) in traversal {
      let referenceLayerIDs: [String]
      if direction.traversesLayersTopFirst {
        referenceLayerIDs = graph.incoming[v] ?? []
      } else {
        referenceLayerIDs = graph.outgoing[v] ?? []
      }
      let sortedNeighborPositions: [(id: String, index: Int)] =
        referenceLayerIDs
        .compactMap { neighborID -> (id: String, index: Int)? in
          guard let pos = positions[neighborID] else {
            return nil
          }
          return (id: neighborID, index: pos.index)
        }
        .sorted { $0.index < $1.index }

      guard !sortedNeighborPositions.isEmpty else {
        continue
      }

      let count = sortedNeighborPositions.count
      let medianIndices: [Int]
      if count.isMultiple(of: 2) {
        let leftMedian = (count / 2) - 1
        let rightMedian = count / 2
        medianIndices =
          direction.prefersLeftmostNeighbor
          ? [leftMedian, rightMedian] : [rightMedian, leftMedian]
      } else {
        medianIndices = [count / 2]
      }

      for medianIndex in medianIndices {
        let candidate = sortedNeighborPositions[medianIndex]
        let edgeKey =
          direction.traversesLayersTopFirst
          ? PolicyCanvasBKEdgeKey(source: candidate.id, target: v)
          : PolicyCanvasBKEdgeKey(source: v, target: candidate.id)
        guard align[v] == v, !conflicts.contains(edgeKey) else {
          continue
        }
        let satisfies =
          direction.prefersLeftmostNeighbor
          ? rBoundary < candidate.index
          : rBoundary > candidate.index
        guard satisfies else {
          continue
        }
        align[candidate.id] = v
        root[v] = root[candidate.id] ?? candidate.id
        align[v] = root[v] ?? v
        rBoundary = candidate.index
      }
    }
  }

  return PolicyCanvasBKAlignment(root: root, align: align)
}

func policyCanvasBKHorizontalCompaction(
  layers: [[String]],
  positions: [String: PolicyCanvasBKPosition],
  alignment: PolicyCanvasBKAlignment,
  direction: PolicyCanvasBKDirection,
  rowStep: CGFloat
) -> [String: CGFloat] {
  let allNodeIDs = layers.flatMap { $0 }
  var sink: [String: String] = [:]
  var shift: [String: CGFloat] = [:]
  var x: [String: CGFloat] = [:]
  var placed: Set<String> = []
  let infiniteShift = direction.prefersLeftmostNeighbor ? CGFloat.infinity : -CGFloat.infinity
  for nodeID in allNodeIDs {
    sink[nodeID] = nodeID
    shift[nodeID] = infiniteShift
  }

  for nodeID in allNodeIDs where (alignment.root[nodeID] ?? nodeID) == nodeID {
    policyCanvasBKPlaceBlock(
      blockRootID: nodeID,
      layers: layers,
      positions: positions,
      alignment: alignment,
      direction: direction,
      rowStep: rowStep,
      sink: &sink,
      shift: &shift,
      x: &x,
      placed: &placed
    )
  }

  var finalX: [String: CGFloat] = [:]
  for nodeID in allNodeIDs {
    let rootID = alignment.root[nodeID] ?? nodeID
    var rootX = x[rootID] ?? 0
    let sinkOfRoot = sink[rootID] ?? rootID
    if let extraShift = shift[sinkOfRoot], extraShift.isFinite {
      rootX += extraShift
    }
    finalX[nodeID] = rootX
  }
  return finalX
}

private func policyCanvasBKPlaceBlock(
  blockRootID: String,
  layers: [[String]],
  positions: [String: PolicyCanvasBKPosition],
  alignment: PolicyCanvasBKAlignment,
  direction: PolicyCanvasBKDirection,
  rowStep: CGFloat,
  sink: inout [String: String],
  shift: inout [String: CGFloat],
  x: inout [String: CGFloat],
  placed: inout Set<String>
) {
  guard !placed.contains(blockRootID) else {
    return
  }
  placed.insert(blockRootID)
  x[blockRootID] = 0
  var w = blockRootID

  repeat {
    guard let wPos = positions[w] else {
      break
    }
    let wLayer = layers[wPos.layer]
    let neighborIndex: Int?
    if direction.prefersLeftmostNeighbor {
      neighborIndex = wPos.index > 0 ? wPos.index - 1 : nil
    } else {
      neighborIndex = wPos.index < wLayer.count - 1 ? wPos.index + 1 : nil
    }
    if let nIndex = neighborIndex {
      let neighborID = wLayer[nIndex]
      let neighborRoot = alignment.root[neighborID] ?? neighborID
      policyCanvasBKPlaceBlock(
        blockRootID: neighborRoot,
        layers: layers,
        positions: positions,
        alignment: alignment,
        direction: direction,
        rowStep: rowStep,
        sink: &sink,
        shift: &shift,
        x: &x,
        placed: &placed
      )
      if sink[blockRootID] == blockRootID {
        sink[blockRootID] = sink[neighborRoot] ?? neighborRoot
      }
      if (sink[blockRootID] ?? blockRootID) != (sink[neighborRoot] ?? neighborRoot) {
        let sinkOfNeighbor = sink[neighborRoot] ?? neighborRoot
        let blockX = x[blockRootID] ?? 0
        let neighborX = x[neighborRoot] ?? 0
        let proposedShift: CGFloat
        if direction.prefersLeftmostNeighbor {
          proposedShift = blockX - neighborX - rowStep
          shift[sinkOfNeighbor] = min(shift[sinkOfNeighbor] ?? .infinity, proposedShift)
        } else {
          proposedShift = blockX - neighborX + rowStep
          shift[sinkOfNeighbor] = max(shift[sinkOfNeighbor] ?? -.infinity, proposedShift)
        }
      } else {
        let neighborX = x[neighborRoot] ?? 0
        let current = x[blockRootID] ?? 0
        if direction.prefersLeftmostNeighbor {
          x[blockRootID] = max(current, neighborX + rowStep)
        } else {
          x[blockRootID] = min(current, neighborX - rowStep)
        }
      }
    }
    w = alignment.align[w] ?? w
  } while w != blockRootID
}

func policyCanvasBKBalance(
  assignments: [[String: CGFloat]],
  allNodeIDs: [String]
) -> [String: CGFloat] {
  var balanced: [String: CGFloat] = [:]
  guard !assignments.isEmpty else {
    return balanced
  }
  for nodeID in allNodeIDs {
    let coords = assignments.compactMap { $0[nodeID] }
    guard !coords.isEmpty else {
      continue
    }
    if coords.count < 4 {
      let total = coords.reduce(CGFloat.zero, +)
      balanced[nodeID] = total / CGFloat(coords.count)
      continue
    }
    let sorted = coords.sorted()
    balanced[nodeID] = (sorted[1] + sorted[2]) / 2
  }
  return balanced
}
