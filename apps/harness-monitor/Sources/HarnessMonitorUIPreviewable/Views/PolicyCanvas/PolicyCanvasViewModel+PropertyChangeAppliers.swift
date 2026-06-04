import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasNodeSwitchCasesChange {
  let id: String
  let from: TaskBoardPolicyPipelineNodeKind
  let to: TaskBoardPolicyPipelineNodeKind
  let fromOutputPortTitles: [String]
  let toOutputPortTitles: [String]
  let fromEdges: [PolicyCanvasEdge]
  let toEdges: [PolicyCanvasEdge]
}

/// Funnel appliers for every inspector property edit routed through
/// `mutate(_:)`. Each function lands the forward write on the editable graph
/// and returns the inverse for `mutate(_:)` to register on the undo stack.
/// Per-keystroke writes stay local to inspector text fields — only the
/// commit lands here so the undo stack carries one entry per committed
/// edit, not one per character. Picker writes are inherently atomic and
/// reach the funnel directly.
extension PolicyCanvasViewModel {
  func applySetNodeTitle(
    id: String,
    from: String,
    to: String
  ) -> PolicyCanvasChange {
    guard let index = nodes.firstIndex(where: { $0.id == id }) else {
      return .setNodeTitle(id: id, from: to, to: to)
    }
    markNodeEdited(id)
    nodes[index].title = to
    return .setNodeTitle(id: id, from: to, to: from)
  }

  /// Apply a kind switch and either prune incident edges (forward direction)
  /// or restore them (inverse direction). `removedEdges == []` is the forward
  /// shape: the change carries no edges yet, the applier captures them after
  /// the prune and embeds them in the inverse. `removedEdges != []` is the
  /// inverse shape: the applier re-attaches the captured edges after writing
  /// the prior kind back. This single funnel keeps Cmd-Z and Cmd-Shift-Z
  /// byte-equal — undo restores both the prior kind and every edge the kind
  /// switch dropped; redo replays the switch and re-prunes the same set.
  ///
  /// Without this funnel a kind switch silently destroyed connections that
  /// Cmd-Z could not bring back.
  func applySetNodeKind(_ change: PolicyCanvasNodeKindChange) -> PolicyCanvasChange {
    guard let index = nodes.firstIndex(where: { $0.id == change.id }) else {
      return change.missingNodeInverse
    }
    markNodeEdited(change.id)
    nodes[index].kind = change.to
    nodes[index].subtitle = change.toSubtitle
    nodes[index].inputPorts = Self.ports(for: change.to.inputPortTitles, kind: .input)
    nodes[index].outputPorts = Self.ports(for: change.to.outputPortTitles, kind: .output)
    nodes[index].policyKind = change.toPolicyKind

    let inverseRemovedEdges: [PolicyCanvasEdge]
    if change.removedEdges.isEmpty {
      // Forward direction: prune edges that the new kind's ports cannot
      // host, capture the pruned set as inverse data.
      inverseRemovedEdges = pruneDanglingEdgesAndReturnRemoved()
    } else {
      // Inverse direction: restore the edges captured on the forward call.
      // Port set is now the prior kind's, so the captured edges land as
      // valid connections; the prune here is a defensive no-op (the new
      // edges already match the active ports).
      let liveNodeIDs = Set(nodes.map(\.id))
      for edge in change.removedEdges where !edges.contains(where: { $0.id == edge.id }) {
        guard
          liveNodeIDs.contains(edge.source.nodeID),
          liveNodeIDs.contains(edge.target.nodeID)
        else {
          continue
        }
        edges.append(edge)
      }
      inverseRemovedEdges = []
    }

    return .setNodeKind(
      id: change.id,
      from: change.to,
      to: change.from,
      fromSubtitle: change.toSubtitle,
      toSubtitle: change.fromSubtitle,
      fromPolicyKind: change.toPolicyKind,
      toPolicyKind: change.fromPolicyKind,
      removedEdges: inverseRemovedEdges
    )
  }

  func applySetNodeGroup(
    id: String,
    from: String?,
    to: String?
  ) -> PolicyCanvasChange {
    guard let index = nodes.firstIndex(where: { $0.id == id }) else {
      return .setNodeGroup(id: id, from: to, to: to)
    }
    markNodeEdited(id)
    nodes[index].groupID = to
    reconcileGroupFrames()
    return .setNodeGroup(id: id, from: to, to: from)
  }

  func applySetNodeSubtitle(
    id: String,
    from: String,
    to: String
  ) -> PolicyCanvasChange {
    guard let index = nodes.firstIndex(where: { $0.id == id }) else {
      return .setNodeSubtitle(id: id, from: to, to: to)
    }
    markNodeEdited(id)
    nodes[index].subtitle = to
    return .setNodeSubtitle(id: id, from: to, to: from)
  }

  func applySetNodePolicyKind(
    id: String,
    from: TaskBoardPolicyPipelineNodeKind?,
    to: TaskBoardPolicyPipelineNodeKind?
  ) -> PolicyCanvasChange {
    guard let index = nodes.firstIndex(where: { $0.id == id }) else {
      return .setNodePolicyKind(id: id, from: to, to: to)
    }
    markNodeEdited(id)
    nodes[index].policyKind = to
    return .setNodePolicyKind(id: id, from: to, to: from)
  }

  func applySetNodeSwitchCases(
    _ change: PolicyCanvasNodeSwitchCasesChange
  ) -> PolicyCanvasChange {
    guard let index = nodes.firstIndex(where: { $0.id == change.id }) else {
      return .setNodeSwitchCases(
        id: change.id,
        from: change.to,
        to: change.to,
        fromOutputPortTitles: change.toOutputPortTitles,
        toOutputPortTitles: change.toOutputPortTitles,
        fromEdges: change.toEdges,
        toEdges: change.toEdges
      )
    }
    markNodeEdited(change.id)
    nodes[index].policyKind = change.to
    nodes[index].outputPorts = Self.ports(for: change.toOutputPortTitles, kind: .output)
    replaceOutgoingEdges(for: change.id, with: change.toEdges)
    return .setNodeSwitchCases(
      id: change.id,
      from: change.to,
      to: change.from,
      fromOutputPortTitles: change.toOutputPortTitles,
      toOutputPortTitles: change.fromOutputPortTitles,
      fromEdges: change.toEdges,
      toEdges: change.fromEdges
    )
  }

  func applySetNodeAutomationBinding(
    id: String,
    from: TaskBoardPolicyPipelineAutomationBinding?,
    to: TaskBoardPolicyPipelineAutomationBinding?
  ) -> PolicyCanvasChange {
    guard let index = nodes.firstIndex(where: { $0.id == id }) else {
      return .setNodeAutomationBinding(id: id, from: to, to: to)
    }
    markNodeEdited(id)
    nodes[index].automationBinding = to
    return .setNodeAutomationBinding(id: id, from: to, to: from)
  }

  func applySetEdgeCondition(
    id: String,
    from: String,
    to: String
  ) -> PolicyCanvasChange {
    guard let index = edges.firstIndex(where: { $0.id == id }) else {
      return .setEdgeCondition(id: id, from: to, to: to)
    }
    markEdgeEdited(id)
    edges[index].condition = to
    return .setEdgeCondition(id: id, from: to, to: from)
  }

  func applySetEdgeLabel(
    id: String,
    from: String,
    to: String
  ) -> PolicyCanvasChange {
    guard let index = edges.firstIndex(where: { $0.id == id }) else {
      return .setEdgeLabel(id: id, from: to, to: to)
    }
    markEdgeEdited(id)
    edges[index].label = to
    return .setEdgeLabel(id: id, from: to, to: from)
  }

  func applySetEdgeKind(
    id: String,
    from: PolicyCanvasEdgeKind,
    to: PolicyCanvasEdgeKind
  ) -> PolicyCanvasChange {
    guard let index = edges.firstIndex(where: { $0.id == id }) else {
      return .setEdgeKind(id: id, from: to, to: to)
    }
    markEdgeEdited(id)
    edges[index].kind = to
    return .setEdgeKind(id: id, from: to, to: from)
  }

  func applySetEdgePinnedPortSide(
    id: String,
    from: Bool,
    to: Bool
  ) -> PolicyCanvasChange {
    guard let index = edges.firstIndex(where: { $0.id == id }) else {
      return .setEdgePinnedPortSide(id: id, from: to, to: to)
    }
    markEdgeEdited(id)
    edges[index].pinnedPortSide = to
    return .setEdgePinnedPortSide(id: id, from: to, to: from)
  }

  func applySetGroupTitle(
    id: String,
    from: String,
    to: String
  ) -> PolicyCanvasChange {
    guard let index = groups.firstIndex(where: { $0.id == id }) else {
      return .setGroupTitle(id: id, from: to, to: to)
    }
    groups[index].title = to
    return .setGroupTitle(id: id, from: to, to: from)
  }

  func applySetGroupTone(
    id: String,
    from: PolicyCanvasGroupTone,
    to: PolicyCanvasGroupTone
  ) -> PolicyCanvasChange {
    guard let index = groups.firstIndex(where: { $0.id == id }) else {
      return .setGroupTone(id: id, from: to, to: to)
    }
    groups[index].tone = to
    return .setGroupTone(id: id, from: to, to: from)
  }

  /// Drop every edge whose source or target references a port that no
  /// longer exists, return the dropped edges so callers can capture them
  /// as part of an undo payload. Used by the `setNodeKind` applier to
  /// capture the pruned cascade as inverse data so Cmd-Z restores both the
  /// prior kind and every connection the kind switch dropped.
  func pruneDanglingEdgesAndReturnRemoved() -> [PolicyCanvasEdge] {
    var removed: [PolicyCanvasEdge] = []
    var kept: [PolicyCanvasEdge] = []
    kept.reserveCapacity(edges.count)
    for edge in edges {
      if portExistsForApplier(edge.source) && portExistsForApplier(edge.target) {
        kept.append(edge)
      } else {
        removed.append(edge)
      }
    }
    if !removed.isEmpty {
      edges = kept
      for edge in removed {
        cleanEphemeralEdgeIDs.remove(edge.id)
      }
    }
    return removed
  }

  /// Build port models for the given titles and kind. Produces the same
  /// port-id strings the legacy direct-write path used so the daemon
  /// round-trip is byte-equal across the refactor.
  static func ports(
    for titles: [String],
    kind: PolicyCanvasPortKind
  ) -> [PolicyCanvasPort] {
    titles.map { title in
      PolicyCanvasPort(id: "\(kind.rawValue)-\(title)", title: title, kind: kind)
    }
  }

  /// Port-existence check used by the kind-switch prune. Kept fileprivate
  /// to this applier file — non-funnel callers must not silently drop
  /// edges by reading membership outside `mutate(_:)`.
  fileprivate func portExistsForApplier(_ endpoint: PolicyCanvasPortEndpoint) -> Bool {
    guard let node = node(endpoint.nodeID) else {
      return false
    }
    let ports = endpoint.kind == .input ? node.inputPorts : node.outputPorts
    return ports.contains { $0.id == endpoint.portID }
  }

  private func replaceOutgoingEdges(
    for nodeID: String,
    with replacementEdges: [PolicyCanvasEdge]
  ) {
    var updated: [PolicyCanvasEdge] = []
    updated.reserveCapacity(edges.count - outgoingEdgeCount(for: nodeID) + replacementEdges.count)
    var inserted = false
    for edge in edges {
      guard edge.source.nodeID == nodeID else {
        updated.append(edge)
        continue
      }
      if !inserted {
        updated.append(contentsOf: replacementEdges)
        inserted = true
      }
    }
    if !inserted {
      updated.append(contentsOf: replacementEdges)
    }
    edges = updated
    cleanEphemeralEdgeIDs.formIntersection(Set(edges.map(\.id)))
    for edge in replacementEdges {
      markEdgeEdited(edge.id)
    }
  }

  private func outgoingEdgeCount(for nodeID: String) -> Int {
    edges.reduce(into: 0) { count, edge in
      if edge.source.nodeID == nodeID {
        count += 1
      }
    }
  }
}
