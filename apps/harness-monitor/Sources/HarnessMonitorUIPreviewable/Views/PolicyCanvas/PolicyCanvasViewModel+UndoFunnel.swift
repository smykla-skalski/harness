import HarnessMonitorKit
import SwiftUI

private func policyCanvasChangeInvalidatesRoutingHints(
  _ change: PolicyCanvasChange
) -> Bool {
  switch change {
  case .addNode,
    .removeNode,
    .restoreNode,
    .moveNode,
    .bulkMove,
    .addEdge,
    .removeEdge,
    .restoreEdge,
    .moveGroup,
    .removeNodeFromGroup,
    .bulkAdd,
    .bulkRemove,
    .setNodeKind,
    .setNodeSwitchCases,
    .setNodeGroup,
    .removeGroup,
    .restoreGroup:
    true
  case .reflowLayout,
    .renameNode,
    .setNodeTitle,
    .setNodeSubtitle,
    .setNodePolicyKind,
    .setNodeAutomationBinding,
    .setEdgeCondition,
    .setEdgeLabel,
    .setEdgeKind,
    .setEdgePinnedPortSide,
    .setGroupTitle,
    .setGroupTone:
    false
  }
}

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
  /// bookkeeping (dirty reconciliation, validation-cache invalidation, status
  /// line). The registered inverse routes back through `mutate(_:)`, which is
  /// what gives the system free redo: undoing once re-registers the original
  /// change as the redo step.
  ///
  /// Callers must NOT bypass this method for any document-state mutation that
  /// belongs in the undo register; otherwise the user sees a step on screen
  /// that Cmd+Z cannot reach. Inspector commits (subtitle, title, kind,
  /// group, picker properties) route through here on Enter/focus-loss so the
  /// undo stack carries one entry per committed edit; per-keystroke writes
  /// stay local to the inspector text fields.
  func mutate(_ change: PolicyCanvasChange) {
    if policyCanvasChangeInvalidatesRoutingHints(change) {
      routingHints = nil
    }
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
    updateDocumentDirtyAfterCommittedMutation()
    invalidateValidationCache()
    notifyStatus(statusMessage(for: change, inverse: inverse))
    if case .reflowLayout = change {
      requestViewportCentering(.document)
    }
  }

  // MARK: - Apply dispatch

  private func applyChange(_ change: PolicyCanvasChange) -> PolicyCanvasChange {
    switch change {
    case .addNode,
      .removeNode,
      .restoreNode,
      .addEdge,
      .removeEdge,
      .restoreEdge,
      .removeGroup,
      .restoreGroup:
      return applyLifecycleChange(change)
    case .moveNode,
      .bulkMove,
      .reflowLayout,
      .moveGroup,
      .renameNode,
      .removeNodeFromGroup,
      .bulkAdd,
      .bulkRemove:
      return applySpatialOrBulkChange(change)
    case .setNodeTitle,
      .setNodeKind,
      .setNodeSwitchCases,
      .setNodeGroup,
      .setNodeSubtitle,
      .setNodePolicyKind,
      .setNodeAutomationBinding,
      .setEdgeCondition,
      .setEdgeLabel,
      .setEdgeKind,
      .setEdgePinnedPortSide,
      .setGroupTitle,
      .setGroupTone:
      return applyPropertyChange(change)
    }

  }

  private func applyLifecycleChange(_ change: PolicyCanvasChange) -> PolicyCanvasChange {
    switch change {
    case .addNode(let node, let restoreSelection):
      return applyAddNode(node, restoreSelection: restoreSelection)
    case .removeNode(let id, let priorSelection):
      return applyRemoveNode(id: id, priorSelection: priorSelection)
    case .restoreNode(let node, let incidentEdges, let cleanNode, let cleanEdges, let selection):
      return applyRestoreNode(
        node,
        incidentEdges: incidentEdges,
        cleanEphemeralNodeIncluded: cleanNode,
        cleanEphemeralEdgeIDs: cleanEdges,
        restoreSelection: selection
      )
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
    case .removeGroup(let id, let priorSelection):
      return applyRemoveGroup(id: id, priorSelection: priorSelection)
    case .restoreGroup(let group, let memberIDs, let restoreSelection):
      return applyRestoreGroup(group, memberIDs: memberIDs, restoreSelection: restoreSelection)
    default:
      preconditionFailure("Unsupported lifecycle change")
    }
  }

  private func applySpatialOrBulkChange(_ change: PolicyCanvasChange) -> PolicyCanvasChange {
    switch change {
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
    case .reflowLayout(let nodeChanges, let edgeChanges, let fromRoutingHints, let toRoutingHints):
      return applyReflowLayout(
        nodeChanges: nodeChanges,
        edgeChanges: edgeChanges,
        fromRoutingHints: fromRoutingHints,
        toRoutingHints: toRoutingHints
      )
    case .moveGroup(let id, let fromOrigin, let toOrigin, let memberOrigins, let destinations):
      return applyMoveGroup(
        id: id,
        fromOrigin: fromOrigin,
        toOrigin: toOrigin,
        memberOrigins: memberOrigins,
        memberDestinations: destinations
      )
    case .renameNode(let id, let from, let to):
      return applyRenameNode(id: id, from: from, to: to)
    case .removeNodeFromGroup(let id, let fromGroupID, let toGroupID):
      return applyRemoveNodeFromGroup(id: id, fromGroupID: fromGroupID, toGroupID: toGroupID)
    case .bulkAdd(let nodes, let edges, let groups, let selection, let secondaries, let primary):
      return applyBulkAdd(
        nodes: nodes,
        edges: edges,
        groups: groups,
        restore: PolicyCanvasBulkSelectionRestore(
          selection: selection,
          secondaries: secondaries
        ),
        primarySelection: primary
      )
    case .bulkRemove(let nodeIDs, let edgeIDs, let groupIDs, let selection, let secondaries):
      return applyBulkRemove(
        nodeIDs: nodeIDs,
        edgeIDs: edgeIDs,
        groupIDs: groupIDs,
        restoreSelection: selection,
        restoreSecondaries: secondaries
      )
    default:
      preconditionFailure("Unsupported spatial or bulk change")
    }
  }

  private func applyPropertyChange(_ change: PolicyCanvasChange) -> PolicyCanvasChange {
    if let nodeChange = applyNodePropertyChange(change) {
      return nodeChange
    }
    if let edgeChange = applyEdgePropertyChange(change) {
      return edgeChange
    }
    if let groupChange = applyGroupPropertyChange(change) {
      return groupChange
    }
    preconditionFailure("Unsupported property change")
  }

  private func applyNodePropertyChange(_ change: PolicyCanvasChange) -> PolicyCanvasChange? {
    switch change {
    case .setNodeTitle(let id, let from, let to):
      return applySetNodeTitle(id: id, from: from, to: to)
    case .setNodeKind(
      let id,
      let from,
      let to,
      let fromSubtitle,
      let toSubtitle,
      let fromPolicyKind,
      let toPolicyKind,
      let removedEdges
    ):
      return applySetNodeKind(
        PolicyCanvasNodeKindChange(
          id: id,
          from: from,
          to: to,
          fromSubtitle: fromSubtitle,
          toSubtitle: toSubtitle,
          fromPolicyKind: fromPolicyKind,
          toPolicyKind: toPolicyKind,
          removedEdges: removedEdges
        )
      )
    case .setNodeGroup(let id, let from, let to):
      return applySetNodeGroup(id: id, from: from, to: to)
    case .setNodeSubtitle(let id, let from, let to):
      return applySetNodeSubtitle(id: id, from: from, to: to)
    case .setNodePolicyKind(let id, let from, let to):
      return applySetNodePolicyKind(id: id, from: from, to: to)
    case .setNodeSwitchCases(
      let id,
      let from,
      let to,
      let fromOutputPortTitles,
      let toOutputPortTitles,
      let fromEdges,
      let toEdges
    ):
      return applySetNodeSwitchCases(
        id: id,
        from: from,
        to: to,
        fromOutputPortTitles: fromOutputPortTitles,
        toOutputPortTitles: toOutputPortTitles,
        fromEdges: fromEdges,
        toEdges: toEdges
      )
    case .setNodeAutomationBinding(let id, let from, let to):
      return applySetNodeAutomationBinding(id: id, from: from, to: to)
    default:
      return nil
    }
  }

  private func applyEdgePropertyChange(_ change: PolicyCanvasChange) -> PolicyCanvasChange? {
    switch change {
    case .setEdgeCondition(let id, let from, let to):
      return applySetEdgeCondition(id: id, from: from, to: to)
    case .setEdgeLabel(let id, let from, let to):
      return applySetEdgeLabel(id: id, from: from, to: to)
    case .setEdgeKind(let id, let from, let to):
      return applySetEdgeKind(id: id, from: from, to: to)
    case .setEdgePinnedPortSide(let id, let from, let to):
      return applySetEdgePinnedPortSide(id: id, from: from, to: to)
    default:
      return nil
    }
  }

  private func applyGroupPropertyChange(_ change: PolicyCanvasChange) -> PolicyCanvasChange? {
    switch change {
    case .setGroupTitle(let id, let from, let to):
      return applySetGroupTitle(id: id, from: from, to: to)
    case .setGroupTone(let id, let from, let to):
      return applySetGroupTone(id: id, from: from, to: to)
    default:
      return nil
    }
  }

}
