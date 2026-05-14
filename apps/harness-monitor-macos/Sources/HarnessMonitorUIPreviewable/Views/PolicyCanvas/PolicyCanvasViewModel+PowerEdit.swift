import SwiftUI

/// Clipboard payload captured by Cmd+C and replayed by Cmd+V. Holds the
/// minimum graph slice needed to rehydrate the copied selection: the source
/// nodes (with full kind/policy binding), any internal edges (those whose
/// source and target are both in the copied node set), and any selected
/// groups along with their member node ids. Edges that cross the selection
/// boundary are intentionally dropped — paste must not strand an edge whose
/// endpoint is not on the canvas afterward.
///
/// The struct is value-typed so a copy taken now survives later canvas
/// mutations; the pasted graph references new ids generated at paste time so
/// nothing in the clipboard references a stale id by the time it is replayed.
struct PolicyCanvasClipboard {
  let nodes: [PolicyCanvasNode]
  let edges: [PolicyCanvasEdge]
  let groups: [PolicyCanvasGroup]
  /// Per-group member ids captured at copy time. We never read live group
  /// frames during paste — the inverse-of-the-inverse uses the captured
  /// payload, so the member list must be stable across canvas mutations
  /// between copy and paste.
  let groupMemberIDs: [String: [String]]

  var isEmpty: Bool {
    nodes.isEmpty && edges.isEmpty && groups.isEmpty
  }
}

extension PolicyCanvasViewModel {
  /// Capture the current multi-selection into the in-memory clipboard.
  /// Edges only enter the clipboard if both endpoints are also in the
  /// selection (otherwise paste would strand the edge). Selected groups
  /// pull their full member list at copy time so a later paste re-creates
  /// the same membership regardless of intervening canvas mutations.
  /// Returns true when the clipboard ended up non-empty (i.e. something
  /// was actually copied), false otherwise so the host can surface the
  /// no-op via the status line.
  @discardableResult
  func copySelectionToClipboard() -> Bool {
    let nodeIDs = Set(selectedNodeIDs)
    let edgeIDs = Set(selectedEdgeIDs)
    let groupIDs = Set(selectedGroupIDs)
    guard !(nodeIDs.isEmpty && edgeIDs.isEmpty && groupIDs.isEmpty) else {
      notifyStatus("Nothing selected to copy")
      return false
    }
    let copiedNodes = nodes.filter { nodeIDs.contains($0.id) }
    let copiedEdges = edges.filter { edge in
      edgeIDs.contains(edge.id)
        && nodeIDs.contains(edge.source.nodeID)
        && nodeIDs.contains(edge.target.nodeID)
    }
    let copiedGroups = groups.filter { groupIDs.contains($0.id) }
    let memberIDs: [String: [String]] = copiedGroups.reduce(into: [:]) { partial, group in
      partial[group.id] = nodes(in: group.id).map(\.id)
    }
    clipboard = PolicyCanvasClipboard(
      nodes: copiedNodes,
      edges: copiedEdges,
      groups: copiedGroups,
      groupMemberIDs: memberIDs
    )
    notifyStatus(copyStatusMessage(
      nodeCount: copiedNodes.count,
      edgeCount: copiedEdges.count,
      groupCount: copiedGroups.count
    ))
    return true
  }

  /// Paste the in-memory clipboard back onto the canvas with newly-minted
  /// ids and an offset position. Returns true on success. The newly-pasted
  /// set becomes the primary + secondary selection so the user can chain
  /// follow-up edits (move, rename, delete) on the fresh nodes without
  /// re-clicking. Routes through `mutate(.bulkAdd)` so Cmd+Z reverts the
  /// paste as a single step.
  @discardableResult
  func pasteFromClipboard() -> Bool {
    guard let clipboard, !clipboard.isEmpty else {
      notifyStatus("Nothing to paste")
      return false
    }
    let offset: CGFloat = PolicyCanvasPasteOffset
    let plan = buildPasteOrDuplicatePlan(
      sourceNodes: clipboard.nodes,
      sourceEdges: clipboard.edges,
      sourceGroups: clipboard.groups,
      sourceMemberIDs: clipboard.groupMemberIDs,
      offset: offset
    )
    let priorSelection = selection
    mutate(.bulkAdd(
      nodes: plan.nodes,
      edges: plan.edges,
      groups: plan.groups,
      restoreSelection: priorSelection,
      primarySelection: plan.primarySelection
    ))
    return true
  }

  /// Cmd+D shortcut. Duplicate the current multi-selection without going
  /// through the clipboard so a paste of a different set still has its
  /// clipboard buffer intact. Behavior is otherwise identical to paste —
  /// new ids, 20pt offset, becomes the new selection, single undo step.
  @discardableResult
  func duplicateSelection() -> Bool {
    let nodeIDs = Set(selectedNodeIDs)
    let edgeIDs = Set(selectedEdgeIDs)
    let groupIDs = Set(selectedGroupIDs)
    guard !(nodeIDs.isEmpty && edgeIDs.isEmpty && groupIDs.isEmpty) else {
      notifyStatus("Nothing selected to duplicate")
      return false
    }
    let sourceNodes = nodes.filter { nodeIDs.contains($0.id) }
    let sourceEdges = edges.filter { edge in
      edgeIDs.contains(edge.id)
        && nodeIDs.contains(edge.source.nodeID)
        && nodeIDs.contains(edge.target.nodeID)
    }
    let sourceGroups = groups.filter { groupIDs.contains($0.id) }
    let memberIDs: [String: [String]] = sourceGroups.reduce(into: [:]) { partial, group in
      partial[group.id] = nodes(in: group.id).map(\.id)
    }
    let plan = buildPasteOrDuplicatePlan(
      sourceNodes: sourceNodes,
      sourceEdges: sourceEdges,
      sourceGroups: sourceGroups,
      sourceMemberIDs: memberIDs,
      offset: PolicyCanvasPasteOffset
    )
    let priorSelection = selection
    mutate(.bulkAdd(
      nodes: plan.nodes,
      edges: plan.edges,
      groups: plan.groups,
      restoreSelection: priorSelection,
      primarySelection: plan.primarySelection
    ))
    return true
  }

  /// Inspector rename funnel. Routes through `mutate(.renameNode)` so a
  /// commit-on-Enter is reversible by Cmd+Z. No-op when the title did not
  /// change (avoids a degenerate undo step that the user did not earn).
  func renameNode(_ id: String, to newTitle: String) {
    guard let current = node(id), current.title != newTitle else {
      return
    }
    mutate(.renameNode(id: id, from: current.title, to: newTitle))
  }

  /// Right-click "Remove from group" funnel. Detaches the node from its
  /// current group and reconciles the group's frame. Inverse re-attaches.
  /// No-op when the node is already group-less.
  func removeNodeFromGroup(_ id: String) {
    guard let current = node(id), let fromGroupID = current.groupID else {
      return
    }
    mutate(.removeNodeFromGroup(id: id, fromGroupID: fromGroupID, toGroupID: nil))
  }

  /// Arrow-key nudge funnel for the current selection. Walks the selected
  /// node and group ids, computing a destination = position + delta for
  /// each, and routes each through the existing `.moveNode` / `.moveGroup`
  /// cases. Groups carry their member offsets through the same change
  /// shape used by drag-end so undo round-trips the same way.
  /// Returns true when any element actually moved (false when there's
  /// nothing to nudge or the delta resolves to a no-op).
  @discardableResult
  func nudgeSelection(by delta: CGSize) -> Bool {
    let nodeIDs = selectedNodeIDs
    let groupIDs = selectedGroupIDs
    guard !(nodeIDs.isEmpty && groupIDs.isEmpty) else {
      return false
    }
    // Snapshot the affected ids so the per-step mutate sequence does not
    // race a concurrent reconcile that drops a group out from under us.
    let movedNodeIDs = nodeIDs.filter { id in
      // Skip nodes that already live inside a group ALSO being moved —
      // the group move will carry them along. Without this guard, the
      // node would shift by 2x delta (once via group move, once via own
      // move).
      guard let groupID = node(id)?.groupID else {
        return true
      }
      return !groupIDs.contains(groupID)
    }
    var anyMoved = false
    for nodeID in movedNodeIDs {
      guard let current = node(nodeID) else { continue }
      let destination = CGPoint(
        x: current.position.x + delta.width,
        y: current.position.y + delta.height
      )
      guard destination != current.position else { continue }
      mutate(.moveNode(id: nodeID, from: current.position, to: destination))
      anyMoved = true
    }
    for groupID in groupIDs {
      guard let current = group(groupID) else { continue }
      let fromOrigin = current.frame.origin
      let toOrigin = CGPoint(
        x: fromOrigin.x + delta.width,
        y: fromOrigin.y + delta.height
      )
      guard toOrigin != fromOrigin else { continue }
      let memberOrigins: [String: CGPoint] = nodes(in: groupID)
        .reduce(into: [:]) { partial, node in
          partial[node.id] = node.position
        }
      let memberDestinations: [String: CGPoint] = memberOrigins.mapValues { origin in
        CGPoint(x: origin.x + delta.width, y: origin.y + delta.height)
      }
      mutate(.moveGroup(
        id: groupID,
        fromOrigin: fromOrigin,
        toOrigin: toOrigin,
        memberOrigins: memberOrigins,
        memberDestinations: memberDestinations
      ))
      anyMoved = true
    }
    return anyMoved
  }

  private struct PolicyCanvasBulkAddPlan {
    let nodes: [PolicyCanvasNode]
    let edges: [PolicyCanvasEdge]
    let groups: [PolicyCanvasGroup]
    let primarySelection: PolicyCanvasSelection?
  }

  private func buildPasteOrDuplicatePlan(
    sourceNodes: [PolicyCanvasNode],
    sourceEdges: [PolicyCanvasEdge],
    sourceGroups: [PolicyCanvasGroup],
    sourceMemberIDs: [String: [String]],
    offset: CGFloat
  ) -> PolicyCanvasBulkAddPlan {
    var nodeIDRemap: [String: String] = [:]
    var groupIDRemap: [String: String] = [:]
    let delta = CGSize(width: offset, height: offset)
    for sourceGroup in sourceGroups {
      let newID = mintFreshGroupID(seed: sourceGroup.id)
      groupIDRemap[sourceGroup.id] = newID
    }
    var clonedNodes: [PolicyCanvasNode] = []
    for sourceNode in sourceNodes {
      let newID = mintFreshNodeID(seed: sourceNode.kind.rawValue)
      nodeIDRemap[sourceNode.id] = newID
      var clone = PolicyCanvasNode(
        id: newID,
        title: sourceNode.title,
        kind: sourceNode.kind,
        position: snapped(
          CGPoint(
            x: sourceNode.position.x + delta.width,
            y: sourceNode.position.y + delta.height
          )
        )
      )
      clone.subtitle = sourceNode.subtitle
      clone.policyKind = sourceNode.policyKind
      clone.inputPorts = sourceNode.inputPorts
      clone.outputPorts = sourceNode.outputPorts
      if let originalGroup = sourceNode.groupID {
        clone.groupID = groupIDRemap[originalGroup] ?? originalGroup
      }
      clonedNodes.append(clone)
    }
    var clonedEdges: [PolicyCanvasEdge] = []
    for sourceEdge in sourceEdges {
      guard
        let newSourceNodeID = nodeIDRemap[sourceEdge.source.nodeID],
        let newTargetNodeID = nodeIDRemap[sourceEdge.target.nodeID]
      else {
        continue
      }
      let newEdgeID = mintFreshEdgeID(
        sourceNodeID: newSourceNodeID,
        sourcePortID: sourceEdge.source.portID,
        targetNodeID: newTargetNodeID,
        targetPortID: sourceEdge.target.portID
      )
      var newSource = sourceEdge.source
      newSource = PolicyCanvasPortEndpoint(
        nodeID: newSourceNodeID,
        portID: newSource.portID,
        kind: newSource.kind,
        side: newSource.side
      )
      var newTarget = sourceEdge.target
      newTarget = PolicyCanvasPortEndpoint(
        nodeID: newTargetNodeID,
        portID: newTarget.portID,
        kind: newTarget.kind,
        side: newTarget.side
      )
      clonedEdges.append(PolicyCanvasEdge(
        id: newEdgeID,
        source: newSource,
        target: newTarget,
        label: sourceEdge.label
      ))
    }
    var clonedGroups: [PolicyCanvasGroup] = []
    for sourceGroup in sourceGroups {
      guard let newID = groupIDRemap[sourceGroup.id] else { continue }
      let shiftedFrame = CGRect(
        origin: CGPoint(
          x: sourceGroup.frame.origin.x + delta.width,
          y: sourceGroup.frame.origin.y + delta.height
        ),
        size: sourceGroup.frame.size
      )
      clonedGroups.append(PolicyCanvasGroup(
        id: newID,
        title: sourceGroup.title,
        frame: shiftedFrame,
        tone: sourceGroup.tone
      ))
    }
    let primary: PolicyCanvasSelection? = {
      if let first = clonedNodes.first {
        return .node(first.id)
      }
      if let first = clonedEdges.first {
        return .edge(first.id)
      }
      if let first = clonedGroups.first {
        return .group(first.id)
      }
      return nil
    }()
    return PolicyCanvasBulkAddPlan(
      nodes: clonedNodes,
      edges: clonedEdges,
      groups: clonedGroups,
      primarySelection: primary
    )
  }

  private func mintFreshNodeID(seed: String) -> String {
    var candidate = "\(seed)-\(nextNodeNumber)"
    nextNodeNumber += 1
    while nodes.contains(where: { $0.id == candidate }) {
      candidate = "\(seed)-\(nextNodeNumber)"
      nextNodeNumber += 1
    }
    return candidate
  }

  private func mintFreshGroupID(seed: String) -> String {
    var index = 1
    var candidate = "\(seed)-copy"
    while groups.contains(where: { $0.id == candidate }) {
      index += 1
      candidate = "\(seed)-copy-\(index)"
    }
    return candidate
  }

  private func mintFreshEdgeID(
    sourceNodeID: String,
    sourcePortID: String,
    targetNodeID: String,
    targetPortID: String
  ) -> String {
    let base = "edge-\(sourceNodeID)-\(sourcePortID)-\(targetNodeID)-\(targetPortID)"
    if !edges.contains(where: { $0.id == base }) {
      return base
    }
    var index = 2
    var candidate = "\(base)-\(index)"
    while edges.contains(where: { $0.id == candidate }) {
      index += 1
      candidate = "\(base)-\(index)"
    }
    return candidate
  }

  private func copyStatusMessage(
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
    return "Copied \(parts.joined(separator: ", "))"
  }
}

/// Offset (in points, both axes) applied to pasted/duplicated nodes,
/// edges, and groups so the cloned set is visually distinct from its
/// source instead of stacking on top. 20pt = 1x grid step, large enough
/// to feel like a deliberate clone, small enough that the cloned set
/// stays inside the user's current viewport.
let PolicyCanvasPasteOffset: CGFloat = 20
