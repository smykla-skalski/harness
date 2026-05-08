import SwiftUI

struct SessionSidebarMultiSelectChange<ID: Hashable>: Equatable {
  let selectedIDs: Set<ID>
  let anchorID: ID?
  let activatesRow: Bool
}

enum SessionSidebarMultiSelect {
  static func resolve<ID: Hashable>(
    rowID: ID,
    orderedVisibleIDs: [ID],
    selectedIDs: Set<ID>,
    anchorID: ID?,
    modifiers: EventModifiers
  ) -> SessionSidebarMultiSelectChange<ID> {
    if modifiers.contains(.shift) {
      return extendSelection(
        rowID: rowID,
        orderedVisibleIDs: orderedVisibleIDs,
        selectedIDs: selectedIDs,
        anchorID: anchorID
      )
    }

    if modifiers.contains(.command) {
      var nextSelection = selectedIDs
      if nextSelection.contains(rowID) {
        nextSelection.remove(rowID)
      } else {
        nextSelection.insert(rowID)
      }
      return .init(selectedIDs: nextSelection, anchorID: rowID, activatesRow: false)
    }

    if selectedIDs.contains(rowID) {
      return .init(selectedIDs: selectedIDs, anchorID: rowID, activatesRow: true)
    }

    return .init(selectedIDs: [rowID], anchorID: rowID, activatesRow: true)
  }

  private static func extendSelection<ID: Hashable>(
    rowID: ID,
    orderedVisibleIDs: [ID],
    selectedIDs: Set<ID>,
    anchorID: ID?
  ) -> SessionSidebarMultiSelectChange<ID> {
    guard
      let anchorID,
      let anchorIndex = orderedVisibleIDs.firstIndex(of: anchorID),
      let rowIndex = orderedVisibleIDs.firstIndex(of: rowID)
    else {
      return .init(selectedIDs: [rowID], anchorID: rowID, activatesRow: false)
    }

    let bounds = min(anchorIndex, rowIndex)...max(anchorIndex, rowIndex)
    let rangeSelection = Set(orderedVisibleIDs[bounds])
    return .init(
      selectedIDs: selectedIDs.union(rangeSelection),
      anchorID: anchorID,
      activatesRow: false
    )
  }
}

struct SessionSidebarMultiSelectRowGesture: ViewModifier {
  let isEnabled: Bool
  let perform: () -> Void

  func body(content: Content) -> some View {
    if isEnabled {
      content.highPriorityGesture(
        TapGesture().onEnded(perform),
        including: .gesture
      )
    } else {
      content
    }
  }
}
