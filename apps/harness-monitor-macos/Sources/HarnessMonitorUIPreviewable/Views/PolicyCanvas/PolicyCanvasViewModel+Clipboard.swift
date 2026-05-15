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
    let ids = selectionIDSets()
    guard !ids.isEmpty else {
      notifyStatus("Nothing selected to copy")
      return false
    }
    let copiedNodes = nodes.filter { ids.nodeIDs.contains($0.id) }
    let copiedEdges = edges.filter { edge in
      ids.edgeIDs.contains(edge.id)
        && ids.nodeIDs.contains(edge.source.nodeID)
        && ids.nodeIDs.contains(edge.target.nodeID)
    }
    let copiedGroups = groups.filter { ids.groupIDs.contains($0.id) }
    let memberIDs: [String: [String]] = copiedGroups.reduce(into: [:]) { partial, group in
      partial[group.id] = nodes(in: group.id).map(\.id)
    }
    clipboard = PolicyCanvasClipboard(
      nodes: copiedNodes,
      edges: copiedEdges,
      groups: copiedGroups,
      groupMemberIDs: memberIDs
    )
    notifyStatus(
      copyStatusMessage(
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
    let offset: CGFloat = policyCanvasPasteOffset
    let plan = buildPasteOrDuplicatePlan(
      sourceNodes: clipboard.nodes,
      sourceEdges: clipboard.edges,
      sourceGroups: clipboard.groups,
      sourceMemberIDs: clipboard.groupMemberIDs,
      offset: offset
    )
    let priorSelection = selection
    let priorSecondaries = secondarySelections
    mutate(
      .bulkAdd(
        nodes: plan.nodes,
        edges: plan.edges,
        groups: plan.groups,
        restoreSelection: priorSelection,
        restoreSecondaries: priorSecondaries,
        primarySelection: plan.primarySelection
      ))
    return true
  }

  /// Build a paste/duplicate plan: rewrites ids, applies the visual offset,
  /// and stages a primary selection for the cloned head element. Shared by
  /// `pasteFromClipboard` and `duplicateSelection` so the two paths cannot
  /// drift on offset, id-minting, or selection promotion.
  func buildPasteOrDuplicatePlan(
    sourceNodes: [PolicyCanvasNode],
    sourceEdges: [PolicyCanvasEdge],
    sourceGroups: [PolicyCanvasGroup],
    sourceMemberIDs: [String: [String]],
    offset: CGFloat
  ) -> PolicyCanvasBulkAddPlan {
    let delta = CGSize(width: offset, height: offset)
    let groupIDRemap = cloneGroupIDRemap(sourceGroups)
    var nodeIDRemap: [String: String] = [:]
    let clonedNodes = clonedPasteNodes(
      sourceNodes,
      groupIDRemap: groupIDRemap,
      nodeIDRemap: &nodeIDRemap,
      delta: delta
    )
    let clonedEdges = clonedPasteEdges(sourceEdges, nodeIDRemap: nodeIDRemap)
    _ = sourceMemberIDs  // member ids are reconstructed by node.groupID during apply.
    let clonedGroups = clonedPasteGroups(
      sourceGroups,
      groupIDRemap: groupIDRemap,
      delta: delta
    )
    return PolicyCanvasBulkAddPlan(
      nodes: clonedNodes,
      edges: clonedEdges,
      groups: clonedGroups,
      primarySelection: primarySelection(
        nodes: clonedNodes,
        edges: clonedEdges,
        groups: clonedGroups
      )
    )
  }

  private func cloneGroupIDRemap(
    _ sourceGroups: [PolicyCanvasGroup]
  ) -> [String: String] {
    var groupIDRemap: [String: String] = [:]
    for sourceGroup in sourceGroups {
      groupIDRemap[sourceGroup.id] = mintFreshGroupID(seed: sourceGroup.id)
    }
    return groupIDRemap
  }

  private func clonedPasteNodes(
    _ sourceNodes: [PolicyCanvasNode],
    groupIDRemap: [String: String],
    nodeIDRemap: inout [String: String],
    delta: CGSize
  ) -> [PolicyCanvasNode] {
    sourceNodes.map { sourceNode in
      let newID = mintFreshNodeID(seed: sourceNode.kind.rawValue)
      nodeIDRemap[sourceNode.id] = newID
      var clone = PolicyCanvasNode(
        id: newID,
        title: sourceNode.title,
        kind: sourceNode.kind,
        position: shiftedNodePosition(sourceNode.position, delta: delta)
      )
      clone.subtitle = sourceNode.subtitle
      clone.policyKind = sourceNode.policyKind
      clone.inputPorts = sourceNode.inputPorts
      clone.outputPorts = sourceNode.outputPorts
      if let originalGroup = sourceNode.groupID {
        clone.groupID = groupIDRemap[originalGroup] ?? originalGroup
      }
      return clone
    }
  }

  private func shiftedNodePosition(_ position: CGPoint, delta: CGSize) -> CGPoint {
    snapped(
      CGPoint(
        x: position.x + delta.width,
        y: position.y + delta.height
      )
    )
  }

  private func clonedPasteEdges(
    _ sourceEdges: [PolicyCanvasEdge],
    nodeIDRemap: [String: String]
  ) -> [PolicyCanvasEdge] {
    sourceEdges.compactMap { sourceEdge in
      clonedPasteEdge(sourceEdge, nodeIDRemap: nodeIDRemap)
    }
  }

  private func clonedPasteEdge(
    _ sourceEdge: PolicyCanvasEdge,
    nodeIDRemap: [String: String]
  ) -> PolicyCanvasEdge? {
    guard
      let newSourceNodeID = nodeIDRemap[sourceEdge.source.nodeID],
      let newTargetNodeID = nodeIDRemap[sourceEdge.target.nodeID]
    else {
      return nil
    }
    let newEdgeID = mintFreshEdgeID(
      sourceNodeID: newSourceNodeID,
      sourcePortID: sourceEdge.source.portID,
      targetNodeID: newTargetNodeID,
      targetPortID: sourceEdge.target.portID
    )
    return PolicyCanvasEdge(
      id: newEdgeID,
      source: clonedEndpoint(sourceEdge.source, nodeID: newSourceNodeID),
      target: clonedEndpoint(sourceEdge.target, nodeID: newTargetNodeID),
      label: sourceEdge.label
    )
  }

  private func clonedEndpoint(
    _ endpoint: PolicyCanvasPortEndpoint,
    nodeID: String
  ) -> PolicyCanvasPortEndpoint {
    PolicyCanvasPortEndpoint(
      nodeID: nodeID,
      portID: endpoint.portID,
      kind: endpoint.kind,
      side: endpoint.side
    )
  }

  private func clonedPasteGroups(
    _ sourceGroups: [PolicyCanvasGroup],
    groupIDRemap: [String: String],
    delta: CGSize
  ) -> [PolicyCanvasGroup] {
    sourceGroups.compactMap { sourceGroup in
      guard let newID = groupIDRemap[sourceGroup.id] else { return nil }
      return PolicyCanvasGroup(
        id: newID,
        title: sourceGroup.title,
        frame: shiftedGroupFrame(sourceGroup.frame, delta: delta),
        tone: sourceGroup.tone
      )
    }
  }

  private func shiftedGroupFrame(_ frame: CGRect, delta: CGSize) -> CGRect {
    CGRect(
      origin: CGPoint(
        x: frame.origin.x + delta.width,
        y: frame.origin.y + delta.height
      ),
      size: frame.size
    )
  }

  private func primarySelection(
    nodes: [PolicyCanvasNode],
    edges: [PolicyCanvasEdge],
    groups: [PolicyCanvasGroup]
  ) -> PolicyCanvasSelection? {
    if let first = nodes.first {
      return .node(first.id)
    }
    if let first = edges.first {
      return .edge(first.id)
    }
    if let first = groups.first {
      return .group(first.id)
    }
    return nil
  }

  func mintFreshNodeID(seed: String) -> String {
    var candidate = "\(seed)-\(nextNodeNumber)"
    nextNodeNumber += 1
    while nodes.contains(where: { $0.id == candidate }) {
      candidate = "\(seed)-\(nextNodeNumber)"
      nextNodeNumber += 1
    }
    return candidate
  }

  func mintFreshGroupID(seed: String) -> String {
    var index = 1
    var candidate = "\(seed)-copy"
    while groups.contains(where: { $0.id == candidate }) {
      index += 1
      candidate = "\(seed)-copy-\(index)"
    }
    return candidate
  }

  func mintFreshEdgeID(
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

/// Plan computed by `buildPasteOrDuplicatePlan` and consumed by both the
/// paste and duplicate funnels. Kept above the type-internal boundary so
/// the two callers share the same staged-bulk-add shape.
struct PolicyCanvasBulkAddPlan {
  let nodes: [PolicyCanvasNode]
  let edges: [PolicyCanvasEdge]
  let groups: [PolicyCanvasGroup]
  let primarySelection: PolicyCanvasSelection?
}

/// Offset (in points, both axes) applied to pasted/duplicated nodes,
/// edges, and groups so the cloned set is visually distinct from its
/// source instead of stacking on top. 20pt = 1x grid step, large enough
/// to feel like a deliberate clone, small enough that the cloned set
/// stays inside the user's current viewport.
let policyCanvasPasteOffset: CGFloat = 20
