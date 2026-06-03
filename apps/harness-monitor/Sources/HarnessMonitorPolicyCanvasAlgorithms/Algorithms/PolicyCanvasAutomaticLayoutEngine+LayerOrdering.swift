import CoreGraphics
import Foundation

// Crossing-reduction layer ordering (barycenter sweeps plus adjacent
// transpose), inversion-count crossing measurement, per-item center-Y
// relaxation, and the shared grid-snapping helpers.
func policyCanvasReducedLayerOrders(
  graph: PolicyCanvasLayeredOrderingGraph,
  maxPasses: Int
) -> [[String]] {
  var layers = graph.layers
  var bestLayers = layers
  var bestCrossings = policyCanvasLayeredOrderingCrossingCount(
    graph: graph,
    layers: layers
  )
  let passLimit = max(1, maxPasses)
  for _ in 0..<passLimit {
    var changed = false
    changed =
      policyCanvasSweepLayerOrders(layers: &layers, graph: graph, forward: true) || changed
    changed =
      policyCanvasSweepLayerOrders(layers: &layers, graph: graph, forward: false) || changed
    // Sugiyama barycenter + transpose is not monotonic in crossing count;
    // a later pass can replace a better intermediate layout. Keep the
    // minimum-crossing layout seen so the engine never ships worse output
    // than it produced mid-loop.
    let currentCrossings = policyCanvasLayeredOrderingCrossingCount(
      graph: graph,
      layers: layers
    )
    if currentCrossings < bestCrossings {
      bestCrossings = currentCrossings
      bestLayers = layers
    }
    if !changed {
      break
    }
  }
  return bestLayers
}

/// Count total cross-layer edge crossings for a layered ordering. Used by
/// `policyCanvasReducedLayerOrders` to track the best layout seen across
/// barycenter passes, and exposed for tests that pin the monotonic improvement
/// invariant.
func policyCanvasLayeredOrderingCrossingCount(
  graph: PolicyCanvasLayeredOrderingGraph,
  layers: [[String]]
) -> Int {
  guard layers.count > 1 else {
    return 0
  }
  var total = 0
  for index in 1..<layers.count {
    let upper = layers[index - 1]
    let lower = layers[index]
    let lowerOrder = Dictionary(
      uniqueKeysWithValues: lower.enumerated().map { ($1, $0) }
    )
    var edgeColumns: [(upper: Int, lower: Int)] = []
    for (upperPos, upperID) in upper.enumerated() {
      let successors = graph.outgoing[upperID] ?? []
      for successor in successors {
        guard let lowerPos = lowerOrder[successor] else {
          continue
        }
        edgeColumns.append((upperPos, lowerPos))
      }
    }
    // Sort edges by upper position; the crossing count is then the number of
    // inversions in the resulting `lower` sequence. Merge-sort gives this in
    // O(N log N) instead of the O(N^2) nested loop, which is the difference
    // between sub-second and seconds on dense graphs (60-wide × 5 layers).
    edgeColumns.sort { lhs, rhs in
      if lhs.upper != rhs.upper { return lhs.upper < rhs.upper }
      return lhs.lower < rhs.lower
    }
    var lowerSequence = edgeColumns.map { $0.lower }
    total += policyCanvasInversionCount(&lowerSequence)
  }
  return total
}

private func policyCanvasInversionCount(_ values: inout [Int]) -> Int {
  guard values.count > 1 else {
    return 0
  }
  var scratch = values
  return policyCanvasMergeCountInversions(&values, scratch: &scratch, lo: 0, hi: values.count)
}

private func policyCanvasMergeCountInversions(
  _ values: inout [Int],
  scratch: inout [Int],
  lo: Int,
  hi: Int
) -> Int {
  guard hi - lo > 1 else {
    return 0
  }
  let mid = (lo + hi) / 2
  var inversions = policyCanvasMergeCountInversions(
    &values,
    scratch: &scratch,
    lo: lo,
    hi: mid
  )
  inversions += policyCanvasMergeCountInversions(
    &values,
    scratch: &scratch,
    lo: mid,
    hi: hi
  )
  var leftIndex = lo
  var rightIndex = mid
  var mergeIndex = lo
  while leftIndex < mid && rightIndex < hi {
    if values[leftIndex] <= values[rightIndex] {
      scratch[mergeIndex] = values[leftIndex]
      leftIndex += 1
    } else {
      scratch[mergeIndex] = values[rightIndex]
      inversions += mid - leftIndex
      rightIndex += 1
    }
    mergeIndex += 1
  }
  while leftIndex < mid {
    scratch[mergeIndex] = values[leftIndex]
    leftIndex += 1
    mergeIndex += 1
  }
  while rightIndex < hi {
    scratch[mergeIndex] = values[rightIndex]
    rightIndex += 1
    mergeIndex += 1
  }
  for index in lo..<hi {
    values[index] = scratch[index]
  }
  return inversions
}

private func policyCanvasSweepLayerOrders(
  layers: inout [[String]],
  graph: PolicyCanvasLayeredOrderingGraph,
  forward: Bool
) -> Bool {
  guard layers.count > 1 else {
    return false
  }
  let layerIndexes =
    forward
    ? Array(1..<layers.count)
    : Array(stride(from: layers.count - 2, through: 0, by: -1))
  var changed = false

  for movingRank in layerIndexes {
    let fixedRank = forward ? movingRank - 1 : movingRank + 1
    let currentOrder = Dictionary(
      uniqueKeysWithValues: layers[movingRank].enumerated().map { ($1, $0) })
    let fixedOrder = Dictionary(
      uniqueKeysWithValues: layers[fixedRank].enumerated().map { ($1, $0) })
    var reorderedLayer = layers[movingRank].sorted { leftID, rightID in
      let leftScore = policyCanvasBarycenterScore(
        itemID: leftID,
        graph: graph,
        fixedOrder: fixedOrder,
        forward: forward,
        fallbackOrder: currentOrder[leftID] ?? 0
      )
      let rightScore = policyCanvasBarycenterScore(
        itemID: rightID,
        graph: graph,
        fixedOrder: fixedOrder,
        forward: forward,
        fallbackOrder: currentOrder[rightID] ?? 0
      )
      if leftScore != rightScore {
        return leftScore < rightScore
      }
      return (currentOrder[leftID] ?? 0) < (currentOrder[rightID] ?? 0)
    }
    if reorderedLayer != layers[movingRank] {
      changed = true
    }
    let upperLayer = movingRank > 0 ? layers[movingRank - 1] : []
    let lowerLayer = movingRank < layers.count - 1 ? layers[movingRank + 1] : []
    policyCanvasTransposeLayer(
      movingLayer: &reorderedLayer,
      upperLayer: upperLayer,
      lowerLayer: lowerLayer,
      graph: graph
    )
    if reorderedLayer != layers[movingRank] {
      changed = true
    }
    layers[movingRank] = reorderedLayer
  }

  return changed
}

private func policyCanvasBarycenterScore(
  itemID: String,
  graph: PolicyCanvasLayeredOrderingGraph,
  fixedOrder: [String: Int],
  forward: Bool,
  fallbackOrder: Int
) -> Double {
  let neighbors = forward ? (graph.incoming[itemID] ?? []) : (graph.outgoing[itemID] ?? [])
  let neighborOrders = neighbors.compactMap { neighborID in
    fixedOrder[neighborID].map(Double.init)
  }
  guard !neighborOrders.isEmpty else {
    return Double(fallbackOrder)
  }
  return neighborOrders.reduce(0, +) / Double(neighborOrders.count)
}

// Graphviz `transpose_step`: an adjacent swap in one layer is accepted when it
// lowers the *joint* crossing count against both neighbour layers. Counting
// only one side (as an upper-or-lower sweep would) lets a swap that helps one
// side while hurting the other slip through, so crossing reduction stalls well
// above the achievable minimum. Empty neighbour layers (the graph's first or
// last rank) contribute zero crossings, which is exactly right.
func policyCanvasTransposeLayer(
  movingLayer: inout [String],
  upperLayer: [String],
  lowerLayer: [String],
  graph: PolicyCanvasLayeredOrderingGraph
) {
  guard movingLayer.count > 1 else {
    return
  }

  let upperOrder = Dictionary(uniqueKeysWithValues: upperLayer.enumerated().map { ($1, $0) })
  let lowerOrder = Dictionary(uniqueKeysWithValues: lowerLayer.enumerated().map { ($1, $0) })
  var upperOrderCache: [String: [Int]] = [:]
  var lowerOrderCache: [String: [Int]] = [:]

  // A `compactMap` through the neighbour-layer order table keeps only the
  // neighbours that actually sit in that adjacent layer, which subsumes the
  // explicit rank guards the one-sided version needed.
  func upperNeighborOrders(for itemID: String) -> [Int] {
    if let cached = upperOrderCache[itemID] {
      return cached
    }
    let orders = (graph.incoming[itemID] ?? []).compactMap { upperOrder[$0] }.sorted()
    upperOrderCache[itemID] = orders
    return orders
  }

  func lowerNeighborOrders(for itemID: String) -> [Int] {
    if let cached = lowerOrderCache[itemID] {
      return cached
    }
    let orders = (graph.outgoing[itemID] ?? []).compactMap { lowerOrder[$0] }.sorted()
    lowerOrderCache[itemID] = orders
    return orders
  }

  func countOrdersBefore(_ order: Int, in sortedOrders: [Int]) -> Int {
    var lowerBound = sortedOrders.startIndex
    var upperBound = sortedOrders.endIndex
    while lowerBound < upperBound {
      let midpoint = lowerBound + ((upperBound - lowerBound) / 2)
      if sortedOrders[midpoint] < order {
        lowerBound = midpoint + 1
      } else {
        upperBound = midpoint
      }
    }
    return lowerBound
  }

  func crossingCount(leadingOrders: [Int], trailingOrders: [Int]) -> Int {
    var crossings = 0
    for leadingOrder in leadingOrders {
      crossings += countOrdersBefore(leadingOrder, in: trailingOrders)
    }
    return crossings
  }

  var improved = true
  while improved {
    improved = false
    for index in 0..<(movingLayer.count - 1) {
      let leftID = movingLayer[index]
      let rightID = movingLayer[index + 1]
      let leftUpper = upperNeighborOrders(for: leftID)
      let rightUpper = upperNeighborOrders(for: rightID)
      let leftLower = lowerNeighborOrders(for: leftID)
      let rightLower = lowerNeighborOrders(for: rightID)
      let existingCrossings =
        crossingCount(leadingOrders: leftUpper, trailingOrders: rightUpper)
        + crossingCount(leadingOrders: leftLower, trailingOrders: rightLower)
      let swappedCrossings =
        crossingCount(leadingOrders: rightUpper, trailingOrders: leftUpper)
        + crossingCount(leadingOrders: rightLower, trailingOrders: leftLower)
      if swappedCrossings < existingCrossings {
        movingLayer.swapAt(index, index + 1)
        improved = true
      }
    }
  }
}

func policyCanvasLayeredItemCenterY(
  layers: [[String]],
  graph: PolicyCanvasLayeredOrderingGraph,
  rowStep: CGFloat
) -> [String: CGFloat] {
  var centers: [String: CGFloat] = [:]
  for layer in layers {
    let initialCenters = policyCanvasCenteredLayerCenters(count: layer.count, rowStep: rowStep)
    for (itemID, centerY) in zip(layer, initialCenters) {
      centers[itemID] = centerY
    }
  }

  for _ in 0..<8 {
    var changed = false
    var nextCenters = centers
    for layer in layers {
      let targetCenters = layer.map { itemID -> CGFloat in
        let neighborCenters = ((graph.incoming[itemID] ?? []) + (graph.outgoing[itemID] ?? []))
          .compactMap { centers[$0] }
        guard !neighborCenters.isEmpty else {
          return centers[itemID] ?? 0
        }
        return neighborCenters.reduce(0, +) / CGFloat(neighborCenters.count)
      }
      let compactedCenters = policyCanvasCompactedLayerCenters(
        targetCenters: targetCenters,
        rowStep: rowStep
      )
      for (itemID, centerY) in zip(layer, compactedCenters) {
        if abs((nextCenters[itemID] ?? 0) - centerY) >= (PolicyCanvasLayout.gridSize / 2) {
          changed = true
        }
        nextCenters[itemID] = centerY
      }
    }
    centers = nextCenters
    if !changed {
      break
    }
  }
  return centers
}

private func policyCanvasCenteredLayerCenters(
  count: Int,
  rowStep: CGFloat
) -> [CGFloat] {
  guard count > 0 else {
    return []
  }
  let totalHeight = CGFloat(max(0, count - 1)) * rowStep
  return (0..<count).map { index in
    (CGFloat(index) * rowStep) - (totalHeight / 2)
  }
}

private func policyCanvasCompactedLayerCenters(
  targetCenters: [CGFloat],
  rowStep: CGFloat
) -> [CGFloat] {
  guard !targetCenters.isEmpty else {
    return []
  }
  var compactedCenters = targetCenters
  for index in 1..<compactedCenters.count {
    compactedCenters[index] = max(
      targetCenters[index],
      compactedCenters[index - 1] + rowStep
    )
  }
  guard let targetFirst = targetCenters.first, let targetLast = targetCenters.last,
    let compactedFirst = compactedCenters.first, let compactedLast = compactedCenters.last
  else {
    return compactedCenters
  }
  let targetMidpoint = (targetFirst + targetLast) / 2
  let compactedMidpoint = (compactedFirst + compactedLast) / 2
  let shift = targetMidpoint - compactedMidpoint
  return compactedCenters.map { $0 + shift }
}

func snappedLayoutPoint(_ point: CGPoint) -> CGPoint {
  CGPoint(
    x: (point.x / PolicyCanvasLayout.gridSize).rounded() * PolicyCanvasLayout.gridSize,
    y: (point.y / PolicyCanvasLayout.gridSize).rounded() * PolicyCanvasLayout.gridSize
  )
}

func snappedLayoutDelta(_ value: CGFloat) -> CGFloat {
  (value / PolicyCanvasLayout.gridSize).rounded() * PolicyCanvasLayout.gridSize
}
