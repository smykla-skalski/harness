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

  let alignedAssignments = policyCanvasBKAlignCoordinates(
    assignments: perDirectionAssignments,
    directions: Array(PolicyCanvasBKDirection.allCases)
  )
  return policyCanvasBKBalance(
    assignments: alignedAssignments,
    allNodeIDs: layers.flatMap { $0 }
  )
}

// Width-align the four candidate layouts before balancing. Each Brandes & Köpf
// layout is compacted in its own frame: the two left-biased passes pack toward
// their minimum coordinate, the two right-biased passes toward their maximum.
// Pick the narrowest layout as the reference and slide every other layout so
// its matching edge (minimum for left-biased, maximum for right-biased) lines
// up with the reference. Without this the per-node median mixes layouts that
// sit at unrelated offsets, which bends otherwise-straight long edges.
func policyCanvasBKAlignCoordinates(
  assignments: [[String: CGFloat]],
  directions: [PolicyCanvasBKDirection]
) -> [[String: CGFloat]] {
  func span(_ coords: [String: CGFloat]) -> CGFloat {
    guard let minValue = coords.values.min(), let maxValue = coords.values.max() else {
      return 0
    }
    return maxValue - minValue
  }
  guard
    let referenceIndex = assignments.indices.min(by: {
      span(assignments[$0]) < span(assignments[$1])
    }),
    let referenceMin = assignments[referenceIndex].values.min(),
    let referenceMax = assignments[referenceIndex].values.max()
  else {
    return assignments
  }
  return assignments.enumerated().map { index, coords in
    guard
      index < directions.count,
      let minValue = coords.values.min(),
      let maxValue = coords.values.max()
    else {
      return coords
    }
    let delta =
      directions[index].prefersLeftmostNeighbor
      ? referenceMin - minValue
      : referenceMax - maxValue
    return coords.mapValues { $0 + delta }
  }
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
    var lowerBound = 0
    var scanIndex = 0

    for lowerIndex in 0..<lowerLayer.count {
      let lowerItemID = lowerLayer[lowerIndex]
      let innerSegmentSourceID = policyCanvasBKIncidentInnerSegmentSource(
        itemID: lowerItemID,
        upperLayer: upperLayer,
        graph: graph
      )
      let isLastInLowerLayer = lowerIndex == lowerLayer.count - 1

      if isLastInLowerLayer || innerSegmentSourceID != nil {
        let upperBound: Int
        if let innerSource = innerSegmentSourceID, let pos = positions[innerSource] {
          upperBound = pos.index
        } else {
          upperBound = max(0, upperLayer.count - 1)
        }

        while scanIndex <= lowerIndex {
          let scanItemID = lowerLayer[scanIndex]
          for predecessorID in graph.incoming[scanItemID] ?? [] {
            guard let predecessorPos = positions[predecessorID] else {
              continue
            }
            if predecessorPos.layer != layerIndex {
              continue
            }
            if predecessorPos.index < lowerBound || predecessorPos.index > upperBound {
              conflicts.insert(PolicyCanvasBKEdgeKey(source: predecessorID, target: scanItemID))
            }
          }
          scanIndex += 1
        }
        lowerBound = upperBound
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

    var rightmostBoundary: Int = direction.prefersLeftmostNeighbor ? -1 : Int.max

    for (_, vertexID) in traversal {
      let sortedNeighborPositions = policyCanvasBKSortedNeighborPositions(
        vertexID: vertexID,
        graph: graph,
        positions: positions,
        direction: direction
      )
      guard !sortedNeighborPositions.isEmpty else {
        continue
      }

      for medianIndex in policyCanvasBKMedianIndices(
        count: sortedNeighborPositions.count,
        direction: direction
      ) {
        let candidate = sortedNeighborPositions[medianIndex]
        let edgeKey =
          direction.traversesLayersTopFirst
          ? PolicyCanvasBKEdgeKey(source: candidate.id, target: vertexID)
          : PolicyCanvasBKEdgeKey(source: vertexID, target: candidate.id)
        guard align[vertexID] == vertexID, !conflicts.contains(edgeKey) else {
          continue
        }
        let satisfies =
          direction.prefersLeftmostNeighbor
          ? rightmostBoundary < candidate.index
          : rightmostBoundary > candidate.index
        guard satisfies else {
          continue
        }
        align[candidate.id] = vertexID
        root[vertexID] = root[candidate.id] ?? candidate.id
        align[vertexID] = root[vertexID] ?? vertexID
        rightmostBoundary = candidate.index
      }
    }
  }

  return PolicyCanvasBKAlignment(root: root, align: align)
}

private func policyCanvasBKSortedNeighborPositions(
  vertexID: String,
  graph: PolicyCanvasLayeredOrderingGraph,
  positions: [String: PolicyCanvasBKPosition],
  direction: PolicyCanvasBKDirection
) -> [(id: String, index: Int)] {
  let referenceLayerIDs: [String]
  if direction.traversesLayersTopFirst {
    referenceLayerIDs = graph.incoming[vertexID] ?? []
  } else {
    referenceLayerIDs = graph.outgoing[vertexID] ?? []
  }
  return
    referenceLayerIDs
    .compactMap { neighborID -> (id: String, index: Int)? in
      guard let pos = positions[neighborID] else {
        return nil
      }
      return (id: neighborID, index: pos.index)
    }
    .sorted { $0.index < $1.index }
}

private func policyCanvasBKMedianIndices(
  count: Int,
  direction: PolicyCanvasBKDirection
) -> [Int] {
  guard count.isMultiple(of: 2) else {
    return [count / 2]
  }
  let leftMedian = (count / 2) - 1
  let rightMedian = count / 2
  return direction.prefersLeftmostNeighbor
    ? [leftMedian, rightMedian] : [rightMedian, leftMedian]
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
