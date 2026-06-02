import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasViewModel {
  /// Magnitude (in canvas points) of a bare-arrow nudge. 1pt was below the
  /// just-noticeable-difference floor at common retina densities — the
  /// adjustment never reads as motion. 2pt clears JND while still feeling
  /// like a fine-grained tap; shift = 10pt and Cmd = grid step stay as
  /// before to preserve the "fine / medium / snap" ladder.
  static let bareArrowNudgeStep: CGFloat = 2

  /// Cmd+D shortcut. Duplicate the current multi-selection without going
  /// through the clipboard so a paste of a different set still has its
  /// clipboard buffer intact. Behavior is otherwise identical to paste —
  /// new ids, 20pt offset, becomes the new selection, single undo step.
  @discardableResult
  func duplicateSelection() -> Bool {
    let ids = selectionIDSets()
    guard !ids.isEmpty else {
      notifyStatus("Nothing selected to duplicate")
      return false
    }
    let sourceNodes = nodes.filter { ids.nodeIDs.contains($0.id) }
    let sourceEdges = edges.filter { edge in
      ids.edgeIDs.contains(edge.id)
        && ids.nodeIDs.contains(edge.source.nodeID)
        && ids.nodeIDs.contains(edge.target.nodeID)
    }
    let sourceGroups = groups.filter { ids.groupIDs.contains($0.id) }
    let memberIDs: [String: [String]] = sourceGroups.reduce(into: [:]) { partial, group in
      partial[group.id] = nodes(in: group.id).map(\.id)
    }
    let plan = buildPasteOrDuplicatePlan(
      sourceNodes: sourceNodes,
      sourceEdges: sourceEdges,
      sourceGroups: sourceGroups,
      sourceMemberIDs: memberIDs,
      offset: policyCanvasPasteOffset
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

  /// Arrow-key nudge funnel for the current selection. Builds a single
  /// `.bulkMove` change carrying every affected node and group so the entire
  /// burst lands as one undo step regardless of how many elements are
  /// selected. Skips group members whose group is also being nudged — the
  /// group's move already carries the member's offset.
  /// Returns true when any element actually moved (false when there is
  /// nothing to nudge or the delta resolves to a no-op).
  @discardableResult
  func nudgeSelection(by delta: CGSize) -> Bool {
    let ids = selectionIDSets()
    guard !(ids.nodeIDs.isEmpty && ids.groupIDs.isEmpty) else {
      return false
    }
    let nodeIndex = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    let groupIndex = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
    let nodeMoves = buildNodeNudgeMoves(
      delta: delta, ids: ids, nodeIndex: nodeIndex
    )
    let groupMoves = buildGroupNudgeMoves(
      delta: delta, ids: ids, groupIndex: groupIndex
    )
    guard !(nodeMoves.isEmpty && groupMoves.isEmpty) else {
      return false
    }
    mutate(.bulkMove(nodeMoves: nodeMoves, groupMoves: groupMoves))
    return true
  }

  private func buildNodeNudgeMoves(
    delta: CGSize,
    ids: PolicyCanvasSelectionIDSets,
    nodeIndex: [String: PolicyCanvasNode]
  ) -> [PolicyCanvasNodeMove] {
    var moves: [PolicyCanvasNodeMove] = []
    moves.reserveCapacity(ids.nodeIDs.count)
    for nodeID in selectedNodeIDs {
      guard let current = nodeIndex[nodeID] else { continue }
      // Skip nodes that already live inside a group ALSO being moved — the
      // group move will carry them along. Without this guard, the node
      // would shift by 2x delta (once via group move, once via own move).
      if let groupID = current.groupID, ids.groupIDs.contains(groupID) {
        continue
      }
      let destination = CGPoint(
        x: current.position.x + delta.width,
        y: current.position.y + delta.height
      )
      guard destination != current.position else { continue }
      moves.append(PolicyCanvasNodeMove(id: nodeID, from: current.position, to: destination))
    }
    return moves
  }

  private func buildGroupNudgeMoves(
    delta: CGSize,
    ids: PolicyCanvasSelectionIDSets,
    groupIndex: [String: PolicyCanvasGroup]
  ) -> [PolicyCanvasGroupMove] {
    var moves: [PolicyCanvasGroupMove] = []
    moves.reserveCapacity(ids.groupIDs.count)
    for groupID in selectedGroupIDs {
      guard let current = groupIndex[groupID] else { continue }
      let fromOrigin = current.frame.origin
      let toOrigin = CGPoint(
        x: fromOrigin.x + delta.width,
        y: fromOrigin.y + delta.height
      )
      guard toOrigin != fromOrigin else { continue }
      var memberOrigins: [String: CGPoint] = [:]
      var memberDestinations: [String: CGPoint] = [:]
      for node in nodes where node.groupID == groupID {
        memberOrigins[node.id] = node.position
        memberDestinations[node.id] = CGPoint(
          x: node.position.x + delta.width,
          y: node.position.y + delta.height
        )
      }
      moves.append(
        PolicyCanvasGroupMove(
          id: groupID,
          fromOrigin: fromOrigin,
          toOrigin: toOrigin,
          memberOrigins: memberOrigins,
          memberDestinations: memberDestinations
        )
      )
    }
    return moves
  }
}

/// Snapshot of the current selection broken out by element kind. Built once
/// per call by `selectionIDSets()` so copy/duplicate/nudge can walk the
/// model arrays once instead of rebuilding three separate id lists per
/// derived-property read.
struct PolicyCanvasSelectionIDSets {
  let nodeIDs: Set<String>
  let edgeIDs: Set<String>
  let groupIDs: Set<String>

  var isEmpty: Bool {
    nodeIDs.isEmpty && edgeIDs.isEmpty && groupIDs.isEmpty
  }
}

extension PolicyCanvasViewModel {
  /// Build the three id sets covering the current primary + secondary
  /// selection in a single pass over `allSelections`. Replaces three calls
  /// to `selectedNodeIDs` / `selectedEdgeIDs` / `selectedGroupIDs` which
  /// each walked their entire model array; one pass is O(s) instead of
  /// O(n+e+g) for the same data.
  func selectionIDSets() -> PolicyCanvasSelectionIDSets {
    var nodeIDs: Set<String> = []
    var edgeIDs: Set<String> = []
    var groupIDs: Set<String> = []
    for value in allSelections {
      switch value {
      case .node(let id):
        nodeIDs.insert(id)
      case .edge(let id):
        edgeIDs.insert(id)
      case .group(let id):
        groupIDs.insert(id)
      }
    }
    return PolicyCanvasSelectionIDSets(
      nodeIDs: nodeIDs,
      edgeIDs: edgeIDs,
      groupIDs: groupIDs
    )
  }
}
