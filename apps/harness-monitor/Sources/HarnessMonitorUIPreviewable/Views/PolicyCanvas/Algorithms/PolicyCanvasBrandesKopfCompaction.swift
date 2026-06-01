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
  var sink: [String: String] = [:]
  var shift: [String: CGFloat] = [:]
  var x: [String: CGFloat] = [:]
  let placed: Set<String> = []
  let infiniteShift = direction.prefersLeftmostNeighbor ? CGFloat.infinity : -CGFloat.infinity
  for nodeID in allNodeIDs {
    sink[nodeID] = nodeID
    shift[nodeID] = infiniteShift
  }

  let context = PolicyCanvasBKCompactionContext(
    layers: layers,
    positions: positions,
    alignment: alignment,
    direction: direction,
    rowStep: rowStep
  )
  var state = PolicyCanvasBKCompactionState(
    sink: sink,
    shift: shift,
    x: x,
    placed: placed
  )
  for nodeID in allNodeIDs where (alignment.root[nodeID] ?? nodeID) == nodeID {
    policyCanvasBKPlaceBlock(
      blockRootID: nodeID,
      context: context,
      state: &state
    )
  }
  sink = state.sink
  shift = state.shift
  x = state.x

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

struct PolicyCanvasBKCompactionContext {
  let layers: [[String]]
  let positions: [String: PolicyCanvasBKPosition]
  let alignment: PolicyCanvasBKAlignment
  let direction: PolicyCanvasBKDirection
  let rowStep: CGFloat
}

struct PolicyCanvasBKCompactionState {
  var sink: [String: String]
  var shift: [String: CGFloat]
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
  if (state.sink[blockRootID] ?? blockRootID) != (state.sink[neighborRoot] ?? neighborRoot) {
    let sinkOfNeighbor = state.sink[neighborRoot] ?? neighborRoot
    let blockX = state.x[blockRootID] ?? 0
    let neighborX = state.x[neighborRoot] ?? 0
    let proposedShift: CGFloat
    if context.direction.prefersLeftmostNeighbor {
      proposedShift = blockX - neighborX - context.rowStep
      state.shift[sinkOfNeighbor] = min(state.shift[sinkOfNeighbor] ?? .infinity, proposedShift)
    } else {
      proposedShift = blockX - neighborX + context.rowStep
      state.shift[sinkOfNeighbor] = max(state.shift[sinkOfNeighbor] ?? -.infinity, proposedShift)
    }
  } else {
    let neighborX = state.x[neighborRoot] ?? 0
    let current = state.x[blockRootID] ?? 0
    if context.direction.prefersLeftmostNeighbor {
      state.x[blockRootID] = max(current, neighborX + context.rowStep)
    } else {
      state.x[blockRootID] = min(current, neighborX - context.rowStep)
    }
  }
}
