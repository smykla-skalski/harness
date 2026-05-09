import Foundation

struct SessionSidebarContextMenuScope: Equatable {
  let kind: SessionSidebarSelectionKind
  let primaryID: String
  let ids: [String]

  var isMulti: Bool { ids.count > 1 }
  var count: Int { ids.count }

  /// The legacy rule: if the right-clicked row is part of the multi-selection
  /// set, batch-action labels operate on the whole set; otherwise the menu
  /// scopes to the single right-clicked row.
  static func resolve(
    kind: SessionSidebarSelectionKind,
    rowID: String,
    selectedIDs: Set<String>,
    orderedVisibleIDs: [String]
  ) -> SessionSidebarContextMenuScope {
    if selectedIDs.contains(rowID), selectedIDs.count > 1 {
      let ordered = orderedVisibleIDs.filter { selectedIDs.contains($0) }
      let resolved = ordered.isEmpty ? Array(selectedIDs).sorted() : ordered
      return SessionSidebarContextMenuScope(kind: kind, primaryID: rowID, ids: resolved)
    }
    return SessionSidebarContextMenuScope(kind: kind, primaryID: rowID, ids: [rowID])
  }

  var copyIDsLabel: String {
    switch kind {
    case .agent: isMulti ? "Copy \(count) Agent IDs" : "Copy Agent ID"
    case .task: isMulti ? "Copy \(count) Task IDs" : "Copy Task ID"
    case .decision: isMulti ? "Copy \(count) Decision IDs" : "Copy Decision ID"
    }
  }

  var destructiveLabel: String {
    switch kind {
    case .agent: isMulti ? "Remove \(count) Agents" : "Remove Agent"
    case .task: isMulti ? "Delete \(count) Tasks" : "Delete Task"
    case .decision: isMulti ? "Dismiss \(count) Decisions" : "Dismiss Decision"
    }
  }

  var clipboardText: String {
    ids.joined(separator: "\n")
  }
}
