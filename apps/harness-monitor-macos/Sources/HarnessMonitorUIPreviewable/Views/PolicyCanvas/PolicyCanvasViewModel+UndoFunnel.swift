import HarnessMonitorKit
import SwiftUI

extension PolicyCanvasViewModel {
  /// Wire the host view's `@Environment(\.undoManager)` into the view model so
  /// subsequent `mutate(_:)` calls register inverses on the system stack. Safe
  /// to call repeatedly; idempotent on identical input. The view model holds
  /// the manager weakly so a window-close that tears down the environment does
  /// not keep a dead pointer alive.
  func attachUndoManager(_ manager: UndoManager?) {
    undoManager = manager
  }

  /// Drop every action registered against this view model from the attached
  /// undo manager. Called after `restoreState(_:)` rolls the graph back to the
  /// pre-attempt snapshot: the user's mental model is "discard the failed
  /// attempt" — keeping the rejected mutations in the undo stack would let
  /// Cmd+Z replay edits that the daemon already refused.
  ///
  /// The canvas's undo manager is window-scoped in production
  /// (`@Environment(\.undoManager)`); foreign actions registered by text
  /// fields elsewhere in the window must survive a canvas reset. The
  /// per-target removal preserves those, and the runloop tick that follows
  /// the rollback closes any in-flight event group automatically.
  func clearUndoStack() {
    undoManager?.removeAllActions(withTarget: self)
  }

  /// Apply `change` to the editable graph, register its inverse on the undo
  /// stack (if a manager is attached), and emit the standard post-mutation
  /// bookkeeping (`documentDirty`, validation-cache invalidation, status
  /// line). The registered inverse routes back through `mutate(_:)`, which is
  /// what gives the system free redo: undoing once re-registers the original
  /// change as the redo step.
  ///
  /// Callers must NOT bypass this method for any document-state mutation that
  /// belongs in the undo register; otherwise the user sees a step on screen
  /// that Cmd+Z cannot reach. Per-keystroke editing-pane writes (title, label,
  /// reason code) intentionally stay outside the funnel — flooding the stack
  /// with one entry per character is worse than no undo for those fields.
  func mutate(_ change: PolicyCanvasChange) {
    let inverse = applyChange(change)
    if let manager = undoManager {
      // Delegate grouping to the AppKit runloop event group
      // (`groupsByEvent=true` is the default for window-attached managers,
      // which is what `@Environment(\.undoManager)` resolves to). Each user
      // gesture lands on its own runloop tick, so the event group already
      // collapses one gesture's mutations into a single Edit-menu entry —
      // an inner explicit group would only nest a degenerate sub-group
      // inside that and leak whichever `setActionName` ran last when two
      // mutations land in the same tick. Test code that needs synchronous
      // step boundaries opens its own explicit groups around each
      // mutation.
      manager.registerUndo(withTarget: self) { target in
        target.mutate(inverse)
      }
      manager.setActionName(change.actionName)
    }
    markDocumentDirty()
    invalidateValidationCache()
    notifyStatus(statusMessage(for: change, inverse: inverse))
  }

  // MARK: - Apply dispatch

  private func applyChange(_ change: PolicyCanvasChange) -> PolicyCanvasChange {
    switch change {
    case .addNode(let node, let restoreSelection):
      return applyAddNode(node, restoreSelection: restoreSelection)
    case .removeNode(let id, let priorSelection):
      return applyRemoveNode(id: id, priorSelection: priorSelection)
    case .restoreNode(
      let node,
      let incidentEdges,
      let cleanEphemeralNodeIncluded,
      let cleanEphemeralEdgeIDs,
      let restoreSelection
    ):
      return applyRestoreNode(
        node,
        incidentEdges: incidentEdges,
        cleanEphemeralNodeIncluded: cleanEphemeralNodeIncluded,
        cleanEphemeralEdgeIDs: cleanEphemeralEdgeIDs,
        restoreSelection: restoreSelection
      )
    case .moveNode(let id, let from, let to, let fromGroupID, let toGroupID):
      return applyMoveNode(
        id: id,
        from: from,
        to: to,
        fromGroupID: fromGroupID,
        toGroupID: toGroupID
      )
    case .bulkMove(let nodeMoves, let groupMoves):
      return applyBulkMove(nodeMoves: nodeMoves, groupMoves: groupMoves)
    case .addEdge(let edge, let restoreSelection):
      return applyAddEdge(edge, restoreSelection: restoreSelection)
    case .removeEdge(let id, let priorSelection):
      return applyRemoveEdge(id: id, priorSelection: priorSelection)
    case .restoreEdge(let edge, let cleanEphemeralEdgeIncluded, let restoreSelection):
      return applyRestoreEdge(
        edge,
        cleanEphemeralEdgeIncluded: cleanEphemeralEdgeIncluded,
        restoreSelection: restoreSelection
      )
    case .moveGroup(let id, let fromOrigin, let toOrigin, let memberOrigins, let memberDestinations):
      return applyMoveGroup(
        id: id,
        fromOrigin: fromOrigin,
        toOrigin: toOrigin,
        memberOrigins: memberOrigins,
        memberDestinations: memberDestinations
      )
    case .removeGroup(let id, let priorSelection):
      return applyRemoveGroup(id: id, priorSelection: priorSelection)
    case .restoreGroup(let group, let memberIDs, let restoreSelection):
      return applyRestoreGroup(group, memberIDs: memberIDs, restoreSelection: restoreSelection)
    case .renameNode(let id, let from, let to):
      return applyRenameNode(id: id, from: from, to: to)
    case .removeNodeFromGroup(let id, let fromGroupID, let toGroupID):
      return applyRemoveNodeFromGroup(id: id, fromGroupID: fromGroupID, toGroupID: toGroupID)
    case .bulkAdd(
      let nodes,
      let edges,
      let groups,
      let restoreSelection,
      let restoreSecondaries,
      let primarySelection
    ):
      return applyBulkAdd(
        nodes: nodes,
        edges: edges,
        groups: groups,
        restoreSelection: restoreSelection,
        restoreSecondaries: restoreSecondaries,
        primarySelection: primarySelection
      )
    case .bulkRemove(
      let nodeIDs,
      let edgeIDs,
      let groupIDs,
      let restoreSelection,
      let restoreSecondaries
    ):
      return applyBulkRemove(
        nodeIDs: nodeIDs,
        edgeIDs: edgeIDs,
        groupIDs: groupIDs,
        restoreSelection: restoreSelection,
        restoreSecondaries: restoreSecondaries
      )
    }
  }

  // MARK: - Node lifecycle

  private func applyAddNode(
    _ node: PolicyCanvasNode,
    restoreSelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    nodes.append(node)
    cleanEphemeralNodeIDs.insert(node.id)
    reconcileGroupFrames()
    selection = .node(node.id)
    return .removeNode(id: node.id, priorSelection: restoreSelection)
  }

  private func applyRemoveNode(
    id: String,
    priorSelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    guard let removedNode = nodes.first(where: { $0.id == id }) else {
      return .addNode(
        PolicyCanvasNode(id: id, title: id, kind: .source, position: .zero),
        restoreSelection: priorSelection
      )
    }
    let incidentEdges = edges.filter { edge in
      edge.source.nodeID == id || edge.target.nodeID == id
    }
    let cleanEphemeralNodeIncluded = cleanEphemeralNodeIDs.contains(id)
    let cleanEphemeralEdgeIDsCaptured = cleanEphemeralEdgeIDs.intersection(
      Set(incidentEdges.map(\.id))
    )
    nodes.removeAll { $0.id == id }
    edges.removeAll { edge in
      edge.source.nodeID == id || edge.target.nodeID == id
    }
    cleanEphemeralNodeIDs.remove(id)
    for edge in incidentEdges {
      cleanEphemeralEdgeIDs.remove(edge.id)
    }
    if selection == .node(id) {
      selection = nil
    }
    reconcileGroupFrames()
    clearTransientGestureState()
    return .restoreNode(
      removedNode,
      incidentEdges: incidentEdges,
      cleanEphemeralNodeIncluded: cleanEphemeralNodeIncluded,
      cleanEphemeralEdgeIDs: cleanEphemeralEdgeIDsCaptured,
      restoreSelection: priorSelection
    )
  }

  private func applyRestoreNode(
    _ node: PolicyCanvasNode,
    incidentEdges: [PolicyCanvasEdge],
    cleanEphemeralNodeIncluded: Bool,
    cleanEphemeralEdgeIDs storedEdgeIDs: Set<String>,
    restoreSelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    nodes.append(node)
    // If the daemon republished while this node was removed, an incident
    // edge may now reference a node that no longer exists locally. Filter
    // rather than crash — the user can replay the missing edge via remote
    // re-load (load-seam dirty-protect lets them keep their other local
    // edits). Live-node set is the freshly appended node id plus every
    // other id currently in `nodes`.
    let liveNodeIDs = Set(nodes.map(\.id))
    for edge in incidentEdges where !edges.contains(where: { $0.id == edge.id }) {
      guard
        liveNodeIDs.contains(edge.source.nodeID),
        liveNodeIDs.contains(edge.target.nodeID)
      else {
        continue
      }
      edges.append(edge)
    }
    if cleanEphemeralNodeIncluded {
      cleanEphemeralNodeIDs.insert(node.id)
    }
    for edgeID in storedEdgeIDs {
      cleanEphemeralEdgeIDs.insert(edgeID)
    }
    reconcileGroupFrames()
    selection = restoreSelection
    return .removeNode(id: node.id, priorSelection: restoreSelection)
  }

  private func applyMoveNode(
    id: String,
    from: CGPoint,
    to: CGPoint,
    fromGroupID: String?,
    toGroupID: String?
  ) -> PolicyCanvasChange {
    guard let index = nodes.firstIndex(where: { $0.id == id }) else {
      return .moveNode(
        id: id,
        from: to,
        to: to,
        fromGroupID: toGroupID,
        toGroupID: fromGroupID
      )
    }
    nodes[index].position = to
    // Replay the caller-supplied group membership when present (undo path),
    // otherwise compute auto-attach from the destination position the same
    // way drag-end and arrow-nudge do. Capturing the prior membership lets
    // the inverse restore it even when the destination is itself outside
    // any group (which the original implementation could only express as
    // an implicit clear).
    let previousGroupID = nodes[index].groupID
    if let toGroupID {
      nodes[index].groupID = toGroupID
    } else if let groupID = containingGroupID(
      for: nodeCenter(nodes[index]),
      excluding: nodes[index].groupID
    ) {
      nodes[index].groupID = groupID
    } else if nodes[index].groupID == nil {
      nodes[index].groupID = containingGroupID(for: nodeCenter(nodes[index]))
    }
    reconcileGroupFrames()
    return .moveNode(
      id: id,
      from: to,
      to: from,
      fromGroupID: nodes[index].groupID,
      toGroupID: fromGroupID ?? previousGroupID
    )
  }

  // MARK: - Edge lifecycle

  private func applyAddEdge(
    _ edge: PolicyCanvasEdge,
    restoreSelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    edges.append(edge)
    cleanEphemeralEdgeIDs.insert(edge.id)
    selection = .edge(edge.id)
    return .removeEdge(id: edge.id, priorSelection: restoreSelection)
  }

  private func applyRemoveEdge(
    id: String,
    priorSelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    guard let removedEdge = edges.first(where: { $0.id == id }) else {
      return .addEdge(
        PolicyCanvasEdge(
          id: id,
          source: PolicyCanvasPortEndpoint(nodeID: "", portID: "", kind: .output),
          target: PolicyCanvasPortEndpoint(nodeID: "", portID: "", kind: .input),
          label: ""
        ),
        restoreSelection: priorSelection
      )
    }
    let cleanEphemeralEdgeIncluded = cleanEphemeralEdgeIDs.contains(id)
    edges.removeAll { $0.id == id }
    cleanEphemeralEdgeIDs.remove(id)
    if selection == .edge(id) {
      selection = nil
    }
    clearTransientGestureState()
    return .restoreEdge(
      removedEdge,
      cleanEphemeralEdgeIncluded: cleanEphemeralEdgeIncluded,
      restoreSelection: priorSelection
    )
  }

  private func applyRestoreEdge(
    _ edge: PolicyCanvasEdge,
    cleanEphemeralEdgeIncluded: Bool,
    restoreSelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    if !edges.contains(where: { $0.id == edge.id }) {
      edges.append(edge)
    }
    if cleanEphemeralEdgeIncluded {
      cleanEphemeralEdgeIDs.insert(edge.id)
    }
    selection = restoreSelection
    return .removeEdge(id: edge.id, priorSelection: restoreSelection)
  }

}
