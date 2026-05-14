import SwiftUI

extension PolicyCanvasViewModel {
  /// Combined view of primary + secondary selections. Order is not stable
  /// across reads — callers that need a deterministic walk should sort by
  /// stable id. The set is non-empty exactly when `selection != nil` (the
  /// secondary set without a primary is not a representable state because
  /// secondary picks always extend an existing primary on shift-click).
  var allSelections: Set<PolicyCanvasSelection> {
    guard let primary = selection else {
      return []
    }
    var union = secondarySelections
    union.insert(primary)
    return union
  }

  /// True when `selection` itself OR a secondary selection equals this
  /// element id. Selection-aware views (node card, edge label, group ring)
  /// call this to decide whether to draw the highlight.
  func isSelected(_ candidate: PolicyCanvasSelection) -> Bool {
    selection == candidate || secondarySelections.contains(candidate)
  }

  /// Shift-click extension: if `target` is already part of the selection,
  /// unselect it (promoting another secondary to primary if the primary
  /// was the one removed). Otherwise add it to the secondary set with the
  /// existing primary untouched, OR promote it to primary if the canvas
  /// is currently selection-less.
  func extendSelection(_ target: PolicyCanvasSelection) {
    if selection == target {
      // Removing the primary; pick any secondary as the new primary so
      // the inspector still has something to render. The set is unordered
      // by design — the visible "primary" affordance after a remove is
      // intentionally arbitrary, since macOS multi-select inspectors
      // typically show a "Multiple selected" placeholder rather than a
      // strict head element.
      if let promoted = secondarySelections.first {
        secondarySelections.remove(promoted)
        selection = promoted
      } else {
        selection = nil
      }
      return
    }
    if secondarySelections.contains(target) {
      secondarySelections.remove(target)
      return
    }
    if selection == nil {
      selection = target
      return
    }
    secondarySelections.insert(target)
  }

  /// Cmd+A selects every node, edge, and group currently on the canvas.
  /// Primary stays whatever it was if it is still on-canvas; otherwise the
  /// first node (or edge if no nodes, or group if neither) takes over.
  /// Document state is untouched.
  func selectAll() {
    var collected: Set<PolicyCanvasSelection> = []
    for node in nodes {
      collected.insert(.node(node.id))
    }
    for edge in edges {
      collected.insert(.edge(edge.id))
    }
    for group in groups {
      collected.insert(.group(group.id))
    }
    guard let head = preferredPrimaryAfterSelectAll() ?? collected.first else {
      selection = nil
      secondarySelections = []
      return
    }
    collected.remove(head)
    selection = head
    secondarySelections = collected
  }

  /// Pick the next primary after a select-all: if the existing primary is
  /// still on-canvas keep it; otherwise prefer the first node, then the
  /// first edge, then the first group. The order matches the most common
  /// visual reading order for a canvas pipeline.
  private func preferredPrimaryAfterSelectAll() -> PolicyCanvasSelection? {
    if let selection, isSelectionLive(selection) {
      return selection
    }
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

  /// True when `value` references an id that still exists in the graph.
  /// Used to detect stale selections after a load or paste.
  func isSelectionLive(_ value: PolicyCanvasSelection) -> Bool {
    switch value {
    case .node(let id):
      return nodes.contains { $0.id == id }
    case .edge(let id):
      return edges.contains { $0.id == id }
    case .group(let id):
      return groups.contains { $0.id == id }
    }
  }

  /// Per-id list of nodes covered by the current selection (primary +
  /// secondary). Used by copy/duplicate/nudge to enumerate the affected
  /// node set. Order is stable: the model's `nodes` order is walked so
  /// repeated calls return the same sequence regardless of insertion order.
  var selectedNodeIDs: [String] {
    let set = nodeIDsInSelection()
    return nodes.compactMap { node in
      set.contains(node.id) ? node.id : nil
    }
  }

  /// Per-id list of edges covered by the current selection (primary +
  /// secondary). Stable order from the model's `edges` walk.
  var selectedEdgeIDs: [String] {
    let set = edgeIDsInSelection()
    return edges.compactMap { edge in
      set.contains(edge.id) ? edge.id : nil
    }
  }

  /// Per-id list of groups covered by the current selection. Stable order
  /// from the model's `groups` walk.
  var selectedGroupIDs: [String] {
    let set = groupIDsInSelection()
    return groups.compactMap { group in
      set.contains(group.id) ? group.id : nil
    }
  }

  private func nodeIDsInSelection() -> Set<String> {
    var collected: Set<String> = []
    for value in allSelections {
      if case .node(let id) = value {
        collected.insert(id)
      }
    }
    return collected
  }

  private func edgeIDsInSelection() -> Set<String> {
    var collected: Set<String> = []
    for value in allSelections {
      if case .edge(let id) = value {
        collected.insert(id)
      }
    }
    return collected
  }

  private func groupIDsInSelection() -> Set<String> {
    var collected: Set<String> = []
    for value in allSelections {
      if case .group(let id) = value {
        collected.insert(id)
      }
    }
    return collected
  }
}
