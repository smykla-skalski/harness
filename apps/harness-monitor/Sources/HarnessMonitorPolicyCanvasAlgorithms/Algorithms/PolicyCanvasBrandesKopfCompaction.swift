import CoreGraphics
import Foundation

// Horizontal compaction stage of the Brandes & Köpf coordinate assignment.
// Each aligned block is placed once, then sink shifts are propagated so every
// block keeps at least `rowStep` of separation from its in-layer neighbor.

func policyCanvasBKHorizontalCompaction(
  layers: [[String]],
  positions: [String: PolicyCanvasBKPosition],
  alignment: PolicyCanvasBKAlignment,
  direction: PolicyCanvasBKDirection,
  rowStep: CGFloat
) -> [String: CGFloat] {
  let allNodeIDs = layers.flatMap { $0 }
  var initialSink: [String: String] = [:]
  for nodeID in allNodeIDs {
    initialSink[nodeID] = nodeID
  }

  let context = PolicyCanvasBKCompactionContext(
    layers: layers,
    positions: positions,
    alignment: alignment,
    direction: direction,
    rowStep: rowStep
  )
  var state = PolicyCanvasBKCompactionState(
    sink: initialSink,
    x: [:],
    placed: []
  )
  for nodeID in allNodeIDs where (alignment.root[nodeID] ?? nodeID) == nodeID {
    policyCanvasBKPlaceBlock(
      blockRootID: nodeID,
      context: context,
      state: &state
    )
  }
  let sink = state.sink
  let x = state.x

  // Alg. 3b: shift whole classes apart for separation, accumulating each higher
  // class's own offset (the term flaw A dropped).
  let shift = policyCanvasBKAccumulateShifts(
    layers: layers,
    positions: positions,
    sink: sink,
    x: x,
    direction: direction,
    rowStep: rowStep
  )

  var finalX: [String: CGFloat] = [:]
  for nodeID in allNodeIDs {
    // Alg. 3a assigns x and sink to every block member, not only the root.
    let nodeSink = sink[nodeID] ?? nodeID
    finalX[nodeID] = (x[nodeID] ?? 0) + (shift[nodeSink] ?? 0)
  }
  return finalX
}

// Class-offset pass from the Brandes-Köpf erratum (Brandes, Walter, Zink 2020,
// Alg. 3b). Block placement (Alg. 3a) leaves each class compacted relative to
// its own sink; this pass then shifts whole classes so neighbouring classes keep
// `rowStep` separation. The original Alg. 3 folded this into place_block and
// omitted the `shift[sink[v]]` term (flaw A), so shifts did not accumulate along
// a diagonal of three or more classes. Here each class-adjacency is bucketed by
// the layer of the higher (read) class's sink and processed top-to-bottom, so a
// class's own shift is final before a lower class reads it. A class never shifted
// by a higher one keeps an absent (zero) offset.
func policyCanvasBKAccumulateShifts(
  layers: [[String]],
  positions: [String: PolicyCanvasBKPosition],
  sink: [String: String],
  x: [String: CGFloat],
  direction: PolicyCanvasBKDirection,
  rowStep: CGFloat
) -> [String: CGFloat] {
  let prefersLeftmost = direction.prefersLeftmostNeighbor
  var bucketedAdjacencies: [Int: [(write: String, read: String, value: CGFloat)]] = [:]
  for layer in layers where layer.count > 1 {
    for index in 0..<(layer.count - 1) {
      let leftID = layer[index]
      let rightID = layer[index + 1]
      // The higher (read) class is the predecessor side: the right neighbour for
      // left-biased passes, the left neighbour for right-biased passes.
      let writeID = prefersLeftmost ? leftID : rightID
      let readID = prefersLeftmost ? rightID : leftID
      let writeSink = sink[writeID] ?? writeID
      let readSink = sink[readID] ?? readID
      guard writeSink != readSink else {
        continue
      }
      let separation = prefersLeftmost ? -rowStep : rowStep
      let value = (x[readID] ?? 0) - (x[writeID] ?? 0) + separation
      let bucket = positions[readSink]?.layer ?? 0
      bucketedAdjacencies[bucket, default: []].append(
        (write: writeSink, read: readSink, value: value)
      )
    }
  }

  var shift: [String: CGFloat] = [:]
  for bucketLayer in 0..<layers.count {
    for adjacency in bucketedAdjacencies[bucketLayer] ?? [] {
      // Accumulate the higher class's own offset (absent == unshifted == 0). This
      // is the term the original Alg. 3 omitted; processing buckets in ascending
      // sink-layer order guarantees it is already final here.
      let readShift = shift[adjacency.read] ?? 0
      let candidate = readShift + adjacency.value
      if let existing = shift[adjacency.write] {
        shift[adjacency.write] =
          prefersLeftmost ? min(existing, candidate) : max(existing, candidate)
      } else {
        shift[adjacency.write] = candidate
      }
    }
  }
  return shift
}

struct PolicyCanvasBKCompactionContext {
  let layers: [[String]]
  let positions: [String: PolicyCanvasBKPosition]
  let alignment: PolicyCanvasBKAlignment
  let direction: PolicyCanvasBKDirection
  let rowStep: CGFloat
}

struct PolicyCanvasBKCompactionState {
  var sink: [String: String]
  var x: [String: CGFloat]
  var placed: Set<String>
}

private func policyCanvasBKPlaceBlock(
  blockRootID: String,
  context: PolicyCanvasBKCompactionContext,
  state: inout PolicyCanvasBKCompactionState
) {
  guard !state.placed.contains(blockRootID) else {
    return
  }
  state.placed.insert(blockRootID)
  state.x[blockRootID] = 0
  var blockMember = blockRootID

  repeat {
    guard let memberPos = context.positions[blockMember] else {
      break
    }
    let memberLayer = context.layers[memberPos.layer]
    let neighborIndex: Int?
    if context.direction.prefersLeftmostNeighbor {
      neighborIndex = memberPos.index > 0 ? memberPos.index - 1 : nil
    } else {
      neighborIndex = memberPos.index < memberLayer.count - 1 ? memberPos.index + 1 : nil
    }
    if let neighborIndex {
      let neighborID = memberLayer[neighborIndex]
      let neighborRoot = context.alignment.root[neighborID] ?? neighborID
      policyCanvasBKPlaceBlock(
        blockRootID: neighborRoot,
        context: context,
        state: &state
      )
      policyCanvasBKMergeNeighborBlock(
        blockRootID: blockRootID,
        neighborRoot: neighborRoot,
        context: context,
        state: &state
      )
    }
    blockMember = context.alignment.align[blockMember] ?? blockMember
  } while blockMember != blockRootID

  // Alg. 3a: align the whole block - propagate the root's coordinate and sink to
  // every member so the class-offset pass can read x/sink for any vertex, not
  // just block roots.
  var member = context.alignment.align[blockRootID] ?? blockRootID
  while member != blockRootID {
    state.x[member] = state.x[blockRootID]
    state.sink[member] = state.sink[blockRootID] ?? blockRootID
    member = context.alignment.align[member] ?? member
  }
}

private func policyCanvasBKMergeNeighborBlock(
  blockRootID: String,
  neighborRoot: String,
  context: PolicyCanvasBKCompactionContext,
  state: inout PolicyCanvasBKCompactionState
) {
  if state.sink[blockRootID] == blockRootID {
    state.sink[blockRootID] = state.sink[neighborRoot] ?? neighborRoot
  }
  // Class offsets between differing sinks are deferred to the Alg. 3b pass; here
  // place_block only compacts blocks that share a sink (same class).
  guard (state.sink[blockRootID] ?? blockRootID) == (state.sink[neighborRoot] ?? neighborRoot)
  else {
    return
  }
  let neighborX = state.x[neighborRoot] ?? 0
  let current = state.x[blockRootID] ?? 0
  if context.direction.prefersLeftmostNeighbor {
    state.x[blockRootID] = max(current, neighborX + context.rowStep)
  } else {
    state.x[blockRootID] = min(current, neighborX - context.rowStep)
  }
}
