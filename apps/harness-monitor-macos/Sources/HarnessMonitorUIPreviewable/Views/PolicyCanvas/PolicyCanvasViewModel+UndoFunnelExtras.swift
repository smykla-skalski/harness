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
    restoreSelection: PolicyCanvasSelection?,
    restoreSecondaries: Set<PolicyCanvasSelection>,
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
      restoreSelection: restoreSelection,
      restoreSecondaries: restoreSecondaries
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

// MARK: - Group lifecycle

extension PolicyCanvasViewModel {
  func applyMoveGroup(
    id: String,
    fromOrigin: CGPoint,
    toOrigin: CGPoint,
    memberOrigins: [String: CGPoint],
    memberDestinations: [String: CGPoint]
  ) -> PolicyCanvasChange {
    if let index = groups.firstIndex(where: { $0.id == id }) {
      groups[index].frame.origin = toOrigin
    }
    for nodeIndex in nodes.indices where nodes[nodeIndex].groupID == id {
      if let destination = memberDestinations[nodes[nodeIndex].id] {
        nodes[nodeIndex].position = destination
      }
    }
    reconcileGroupFrames()
    return .moveGroup(
      id: id,
      fromOrigin: toOrigin,
      toOrigin: fromOrigin,
      memberOrigins: memberDestinations,
      memberDestinations: memberOrigins
    )
  }

  func applyRemoveGroup(
    id: String,
    priorSelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    guard let removedGroup = groups.first(where: { $0.id == id }) else {
      return .restoreGroup(
        PolicyCanvasGroup(id: id, title: id, frame: .zero, tone: .intake),
        memberIDs: [],
        restoreSelection: priorSelection
      )
    }
    let formerMemberIDs = nodes.filter { $0.groupID == id }.map(\.id)
    groups.removeAll { $0.id == id }
    for nodeIndex in nodes.indices where nodes[nodeIndex].groupID == id {
      nodes[nodeIndex].groupID = nil
    }
    if selection == .group(id) {
      selection = nil
    }
    reconcileGroupFrames()
    clearTransientGestureState()
    return .restoreGroup(
      removedGroup,
      memberIDs: formerMemberIDs,
      restoreSelection: priorSelection
    )
  }

  func applyRestoreGroup(
    _ group: PolicyCanvasGroup,
    memberIDs: [String],
    restoreSelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    if !groups.contains(where: { $0.id == group.id }) {
      groups.append(group)
    }
    let memberSet = Set(memberIDs)
    for nodeIndex in nodes.indices where memberSet.contains(nodes[nodeIndex].id) {
      nodes[nodeIndex].groupID = group.id
    }
    reconcileGroupFrames()
    selection = restoreSelection
    return .removeGroup(id: group.id, priorSelection: restoreSelection)
  }

  /// Choose the status line each change publishes. The strings match what the
  /// non-funnelled paths used before the refactor so existing tests that
  /// assert on status prefixes keep passing.
  ///
  /// `change` is the forward direction the user asked for; `inverse` is the
  /// just-computed undo payload, which is the one carrying the displaced
  /// node/edge/group payload for `remove*` operations (the forward change
  /// only carries the id, since the entity has already been removed from
  /// the live graph by the time we read it).
  ///
  /// Single exhaustive switch over every `PolicyCanvasChange` case so the
  /// compiler catches future cases. The earlier two-switch shape silently
  /// fell through to "Canvas updated" when the new-case branch returned nil,
  /// which masked missing strings on power-edit cases.
  func statusMessage(
    for change: PolicyCanvasChange,
    inverse: PolicyCanvasChange
  ) -> String {
    switch change {
    case .addNode(let node, _):
      return "\(node.kind.title) node added"
    case .restoreNode(let node, _, _, _, _):
      return "Restored \(node.title)"
    case .removeNode:
      if case .restoreNode(let node, _, _, _, _) = inverse {
        return "Deleted \(node.title)"
      }
      return "Deleted node"
    case .moveNode:
      return "Node moved"
    case .bulkMove(let nodeMoves, let groupMoves):
      let count = nodeMoves.count + groupMoves.count
      if count <= 1 {
        return "Moved selection"
      }
      return "Moved \(count) items"
    case .addEdge:
      return "Edge created"
    case .restoreEdge(let edge, _, _):
      return "Restored \(edge.label) connection"
    case .removeEdge:
      if case .restoreEdge(let edge, _, _) = inverse {
        return "Deleted \(edge.label) connection"
      }
      return "Deleted connection"
    case .moveGroup:
      return "Group moved"
    case .restoreGroup(let group, _, _):
      return "Restored \(group.title)"
    case .removeGroup:
      if case .restoreGroup(let group, _, _) = inverse {
        return "Deleted \(group.title)"
      }
      return "Deleted group"
    case .renameNode(_, _, let to):
      return "Renamed to \(to)"
    case .removeNodeFromGroup(_, _, let toGroupID):
      if toGroupID == nil {
        return "Removed from group"
      }
      return "Moved to group"
    case .bulkAdd(let nodes, let edges, let groups, _, _, _):
      return pasteSummaryMessage(
        nodeCount: nodes.count,
        edgeCount: edges.count,
        groupCount: groups.count
      )
    case .bulkRemove:
      if case .bulkAdd(let nodes, _, _, _, _, _) = inverse, !nodes.isEmpty {
        return "Removed \(nodes.count) item\(nodes.count == 1 ? "" : "s")"
      }
      return "Removed items"
    }
  }

  /// Compact "Pasted N node(s), M edge(s), K group(s)" summary used by the
  /// post-paste status surface (norman feedback loop). The string omits
  /// zero-count parts so a paste of a single node reads "Pasted 1 node"
  /// instead of "Pasted 1 node, 0 edges, 0 groups".
  func pasteSummaryMessage(
    nodeCount: Int,
    edgeCount: Int,
    groupCount: Int
  ) -> String {
    var parts: [String] = []
    if nodeCount > 0 {
      parts.append("\(nodeCount) node\(nodeCount == 1 ? "" : "s")")
    }
    if edgeCount > 0 {
      parts.append("\(edgeCount) edge\(edgeCount == 1 ? "" : "s")")
    }
    if groupCount > 0 {
      parts.append("\(groupCount) group\(groupCount == 1 ? "" : "s")")
    }
    guard !parts.isEmpty else {
      return "Pasted"
    }
    return "Pasted \(parts.joined(separator: ", "))"
  }
}
