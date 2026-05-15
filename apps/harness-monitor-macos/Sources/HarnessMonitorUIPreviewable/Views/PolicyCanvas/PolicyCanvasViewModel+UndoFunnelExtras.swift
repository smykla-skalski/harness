import SwiftUI

/// Apply-side helpers for the Wave 4J power-edit `PolicyCanvasChange` cases
/// (`renameNode`, `removeNodeFromGroup`, `bulkAdd`, `bulkRemove`). Kept
/// adjacent to `PolicyCanvasViewModel+UndoFunnel.swift` but in a separate
/// file so the parent funnel stays under the 420-line cap. Each apply
/// returns its inverse so the `mutate(_:)` register-undo path stays uniform
/// regardless of which case landed.
extension PolicyCanvasViewModel {
  func applyRenameNode(
    id: String,
    from: String,
    to: String
  ) -> PolicyCanvasChange {
    guard let index = nodes.firstIndex(where: { $0.id == id }) else {
      return .renameNode(id: id, from: to, to: to)
    }
    nodes[index].title = to
    markNodeEdited(id)
    return .renameNode(id: id, from: to, to: from)
  }

  func applyRemoveNodeFromGroup(
    id: String,
    fromGroupID: String?,
    toGroupID: String?
  ) -> PolicyCanvasChange {
    guard let index = nodes.firstIndex(where: { $0.id == id }) else {
      return .removeNodeFromGroup(id: id, fromGroupID: toGroupID, toGroupID: fromGroupID)
    }
    // Capture the current `groupID` before writing so the inverse always
    // restores the state we just displaced — even if the caller passed a
    // stale `fromGroupID` (e.g. after an intervening daemon republish).
    let previous = nodes[index].groupID
    nodes[index].groupID = toGroupID
    reconcileGroupFrames()
    return .removeNodeFromGroup(id: id, fromGroupID: toGroupID, toGroupID: previous)
  }

  func applyBulkAdd(
    nodes incomingNodes: [PolicyCanvasNode],
    edges incomingEdges: [PolicyCanvasEdge],
    groups incomingGroups: [PolicyCanvasGroup],
    restore: PolicyCanvasBulkSelectionRestore,
    primarySelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    var insertedNodeIDs: [String] = []
    var insertedEdgeIDs: [String] = []
    var insertedGroupIDs: [String] = []
    // Precompute the live-node id set once before the edge loop. The
    // previous version rebuilt the set inside the loop, walking `nodes` per
    // edge for an O(edges x nodes) cost; one pass before the loop is
    // O(edges + nodes).
    for group in incomingGroups where !groups.contains(where: { $0.id == group.id }) {
      groups.append(group)
      insertedGroupIDs.append(group.id)
    }
    for node in incomingNodes where !nodes.contains(where: { $0.id == node.id }) {
      nodes.append(node)
      cleanEphemeralNodeIDs.insert(node.id)
      insertedNodeIDs.append(node.id)
    }
    let liveNodeIDs = Set(nodes.map(\.id))
    for edge in incomingEdges where !edges.contains(where: { $0.id == edge.id }) {
      // Only insert edges whose endpoints exist after the node insert pass.
      // Edges in the clipboard whose endpoint nodes were dropped at copy
      // time (selection boundary cut) never reach here, but a stale
      // re-paste might. Filter rather than crash.
      guard
        liveNodeIDs.contains(edge.source.nodeID),
        liveNodeIDs.contains(edge.target.nodeID)
      else {
        continue
      }
      edges.append(edge)
      cleanEphemeralEdgeIDs.insert(edge.id)
      insertedEdgeIDs.append(edge.id)
    }
    reconcileGroupFrames()
    if let primarySelection {
      selection = primarySelection
      var secondary = Set<PolicyCanvasSelection>()
      for nodeID in insertedNodeIDs where .node(nodeID) != primarySelection {
        secondary.insert(.node(nodeID))
      }
      for edgeID in insertedEdgeIDs where .edge(edgeID) != primarySelection {
        secondary.insert(.edge(edgeID))
      }
      for groupID in insertedGroupIDs where .group(groupID) != primarySelection {
        secondary.insert(.group(groupID))
      }
      secondarySelections = secondary
    }
    return .bulkRemove(
      nodeIDs: insertedNodeIDs,
      edgeIDs: insertedEdgeIDs,
      groupIDs: insertedGroupIDs,
      restoreSelection: restore.selection,
      restoreSecondaries: restore.secondaries
    )
  }

  func applyBulkRemove(
    nodeIDs: [String],
    edgeIDs: [String],
    groupIDs: [String],
    restoreSelection: PolicyCanvasSelection?,
    restoreSecondaries: Set<PolicyCanvasSelection>
  ) -> PolicyCanvasChange {
    // Capture the displaced payload before any removal so the inverse can
    // rehydrate the exact insertion (including order-stable bulk-add).
    let displacedNodes = nodes.filter { nodeIDs.contains($0.id) }
    let displacedEdges = edges.filter { edgeIDs.contains($0.id) }
    let displacedGroups = groups.filter { groupIDs.contains($0.id) }

    let nodeIDSet = Set(nodeIDs)
    let edgeIDSet = Set(edgeIDs)
    let groupIDSet = Set(groupIDs)

    edges.removeAll { edge in
      edgeIDSet.contains(edge.id)
        || nodeIDSet.contains(edge.source.nodeID)
        || nodeIDSet.contains(edge.target.nodeID)
    }
    nodes.removeAll { nodeIDSet.contains($0.id) }
    for nodeIndex in nodes.indices {
      if let groupID = nodes[nodeIndex].groupID, groupIDSet.contains(groupID) {
        nodes[nodeIndex].groupID = nil
      }
    }
    groups.removeAll { groupIDSet.contains($0.id) }
    for nodeID in nodeIDs {
      cleanEphemeralNodeIDs.remove(nodeID)
    }
    for edgeID in edgeIDs {
      cleanEphemeralEdgeIDs.remove(edgeID)
    }
    // Drop selection entries that no longer reference live ids. Primary
    // selection clears first so the downstream `restoreSelection` can take
    // over without fighting a stale primary.
    if let primary = selection, !isSelectionLive(primary) {
      selection = nil
    }
    secondarySelections = secondarySelections.filter { isSelectionLive($0) }
    reconcileGroupFrames()
    clearTransientGestureState()
    let inverseSelection = selection
    let inverseSecondaries = secondarySelections
    selection = restoreSelection
    secondarySelections = restoreSecondaries.filter { isSelectionLive($0) }
    return .bulkAdd(
      nodes: displacedNodes,
      edges: displacedEdges,
      groups: displacedGroups,
      restoreSelection: inverseSelection,
      restoreSecondaries: inverseSecondaries,
      primarySelection: nil
    )
  }

  /// Apply a coalesced multi-element move. Returns the inverse `.bulkMove`
  /// so each held-arrow burst collapses to one undo step regardless of how
  /// many nodes or groups were under the cursor.
  func applyBulkMove(
    nodeMoves: [PolicyCanvasNodeMove],
    groupMoves: [PolicyCanvasGroupMove]
  ) -> PolicyCanvasChange {
    var nodeMoveIndex: [String: Int] = [:]
    for index in nodes.indices {
      nodeMoveIndex[nodes[index].id] = index
    }
    for move in nodeMoves {
      guard let index = nodeMoveIndex[move.id] else { continue }
      nodes[index].position = move.to
    }
    for move in groupMoves {
      if let index = groups.firstIndex(where: { $0.id == move.id }) {
        groups[index].frame.origin = move.toOrigin
      }
      for nodeIndex in nodes.indices where nodes[nodeIndex].groupID == move.id {
        if let destination = move.memberDestinations[nodes[nodeIndex].id] {
          nodes[nodeIndex].position = destination
        }
      }
    }
    reconcileGroupFrames()
    let inverseNodeMoves = nodeMoves.map { move in
      PolicyCanvasNodeMove(id: move.id, from: move.to, to: move.from)
    }
    let inverseGroupMoves = groupMoves.map { move in
      PolicyCanvasGroupMove(
        id: move.id,
        fromOrigin: move.toOrigin,
        toOrigin: move.fromOrigin,
        memberOrigins: move.memberDestinations,
        memberDestinations: move.memberOrigins
      )
    }
    return .bulkMove(nodeMoves: inverseNodeMoves, groupMoves: inverseGroupMoves)
  }
}
