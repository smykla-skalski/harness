import HarnessMonitorPolicyCanvasAlgorithms
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
      // Removing the primary; promote the first secondary in stable model
      // order (nodes first, then edges, then groups, each in document
      // order). The set itself is unordered, but a deterministic
      // promotion keeps repeat shift-click-on-primary gestures landing on
      // the same inspector contents regardless of insertion-order hash
      // collisions.
      if let promoted = stablePromotionCandidate() {
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

  func replaceSelections(with captured: Set<PolicyCanvasSelection>) {
    guard !captured.isEmpty else {
      clearSelection()
      return
    }

    let primary = preferredPrimary(in: captured, keeping: selection)
    selection = primary
    secondarySelections = captured.subtracting([primary])
  }

  func addSelections(_ captured: Set<PolicyCanvasSelection>) {
    guard !captured.isEmpty else {
      return
    }

    if let selection {
      secondarySelections.formUnion(captured.subtracting([selection]))
      return
    }

    let primary = preferredPrimary(in: captured, keeping: nil)
    selection = primary
    secondarySelections = captured.subtracting([primary])
  }

  /// Stable head element of the secondary set, used by `extendSelection` to
  /// promote when the user shift-clicks the current primary off. Walks the
  /// model arrays so the chosen candidate is deterministic across runs even
  /// though `Set<PolicyCanvasSelection>` does not preserve insertion order.
  private func stablePromotionCandidate() -> PolicyCanvasSelection? {
    for node in nodes where secondarySelections.contains(.node(node.id)) {
      return .node(node.id)
    }
    for edge in edges where secondarySelections.contains(.edge(edge.id)) {
      return .edge(edge.id)
    }
    for group in groups where secondarySelections.contains(.group(group.id)) {
      return .group(group.id)
    }
    return nil
  }

  private func preferredPrimary(
    in captured: Set<PolicyCanvasSelection>,
    keeping currentPrimary: PolicyCanvasSelection?
  ) -> PolicyCanvasSelection {
    if let currentPrimary, captured.contains(currentPrimary) {
      return currentPrimary
    }

    if let first = stableSelectionOrder(in: captured).first {
      return first
    }

    let fallbackOrder = captured.sorted(by: stableSelectionFallbackLessThan)
    if let first = fallbackOrder.first {
      return first
    }

    preconditionFailure("preferredPrimary requires a non-empty captured set")
  }

  private func stableSelectionOrder(
    in selections: Set<PolicyCanvasSelection>
  ) -> [PolicyCanvasSelection] {
    var ordered: [PolicyCanvasSelection] = []
    ordered.reserveCapacity(selections.count)

    for node in nodes {
      let candidate = PolicyCanvasSelection.node(node.id)
      if selections.contains(candidate) {
        ordered.append(candidate)
      }
    }

    for edge in edges {
      let candidate = PolicyCanvasSelection.edge(edge.id)
      if selections.contains(candidate) {
        ordered.append(candidate)
      }
    }

    for group in groups {
      let candidate = PolicyCanvasSelection.group(group.id)
      if selections.contains(candidate) {
        ordered.append(candidate)
      }
    }

    return ordered
  }

  private func stableSelectionFallbackLessThan(
    _ lhs: PolicyCanvasSelection,
    _ rhs: PolicyCanvasSelection
  ) -> Bool {
    switch (lhs, rhs) {
    case (.node(let left), .node(let right)):
      return left < right
    case (.node, _):
      return true
    case (_, .node):
      return false
    case (.edge(let left), .edge(let right)):
      return left < right
    case (.edge, .group):
      return true
    case (.group, .edge):
      return false
    case (.group(let left), .group(let right)):
      return left < right
    }
  }

  /// Cmd+A selects every node, edge, and group currently on the canvas.
  /// Primary stays whatever it was if it is still on-canvas; otherwise the
  /// first node (or edge if no nodes, or group if neither) takes over.
  /// Document state is untouched. Writes the secondary set first and then
  /// the primary so observers that depend on the combined set still see a
  /// consistent value either way; `@Observable` already coalesces sequential
  /// writes inside the same actor tick.
  func selectAll() {
    var collected: Set<PolicyCanvasSelection> = []
    collected.reserveCapacity(nodes.count + edges.count + groups.count)
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
      if selection != nil {
        selection = nil
      }
      if !secondarySelections.isEmpty {
        secondarySelections = []
      }
      return
    }
    collected.remove(head)
    // Write secondary first, then primary, so any observer that subscribes
    // through `allSelections` (primary + secondary union) reads at most one
    // intermediate state where the head element is in the secondary set
    // instead of the primary slot — still a consistent superset.
    secondarySelections = collected
    selection = head
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
