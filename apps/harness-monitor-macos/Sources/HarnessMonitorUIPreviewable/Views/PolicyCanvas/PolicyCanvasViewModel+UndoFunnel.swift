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
      // Open and close an explicit undo group around the registration. In
      // `groupsByEvent=true` mode this becomes a nested sub-group inside
      // the auto event group; in `groupsByEvent=false` mode it's the only
      // way to attach an action name without raising an
      // internal-consistency exception. Either way, each mutate produces
      // a well-named entry the system menu's "Undo X" can surface.
      manager.beginUndoGrouping()
      manager.registerUndo(withTarget: self) { target in
        target.mutate(inverse)
      }
      manager.setActionName(change.actionName)
      manager.endUndoGrouping()
    }
    documentDirty = true
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
    case .moveNode(let id, let from, let to):
      return applyMoveNode(id: id, from: from, to: to)
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
    for edge in incidentEdges where !edges.contains(where: { $0.id == edge.id }) {
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
    to: CGPoint
  ) -> PolicyCanvasChange {
    guard let index = nodes.firstIndex(where: { $0.id == id }) else {
      return .moveNode(id: id, from: to, to: to)
    }
    nodes[index].position = to
    if let groupID = containingGroupID(
      for: nodeCenter(nodes[index]),
      excluding: nodes[index].groupID
    ) {
      nodes[index].groupID = groupID
    } else if nodes[index].groupID == nil {
      nodes[index].groupID = containingGroupID(for: nodeCenter(nodes[index]))
    }
    reconcileGroupFrames()
    return .moveNode(id: id, from: to, to: from)
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

  // MARK: - Group lifecycle

  private func applyMoveGroup(
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

  private func applyRemoveGroup(
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

  private func applyRestoreGroup(
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
  private func statusMessage(
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
    }
  }
}
