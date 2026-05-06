import Foundation

struct SidebarSessionListSelectionChange: Equatable {
  enum StoreSelection: Equatable {
    case unchanged
    case cleared
    case selected(String)
  }

  let nextSelection: Set<String>
  let storeSelection: StoreSelection
}

/// The sidebar intentionally tracks two related but different concepts:
/// - native `List(selection:)` owns local sidebar highlight and multi-selection state
/// - the store owns the single session driving the cockpit/detail surface
///
/// Sync rules:
/// - a visible single selection may sync back to the store
/// - a visible multi-selection stays local to the sidebar
/// - filtered-out selections stay in local state until visibility changes again
/// - semantic MCP/accessibility row activation is an explicit single-target path
///   that collapses local selection to one row and targets the cockpit
enum SidebarSessionListSelectionSync {
  static func selection(for sessionID: String?) -> Set<String> {
    guard let sessionID else {
      return []
    }
    return [sessionID]
  }

  static func renderedSelection(
    from selection: Set<String>,
    visibleSessionIDs: Set<String>
  ) -> Set<String> {
    selection.intersection(visibleSessionIDs)
  }

  static func resolve(
    previousSelection: Set<String>,
    newRenderedSelection: Set<String>,
    visibleSessionIDs: Set<String>,
    storeSelectedSessionID: String?
  ) -> SidebarSessionListSelectionChange {
    let previousRenderedSelection = renderedSelection(
      from: previousSelection,
      visibleSessionIDs: visibleSessionIDs
    )

    if newRenderedSelection == previousRenderedSelection {
      return SidebarSessionListSelectionChange(
        nextSelection: previousSelection,
        storeSelection: .unchanged
      )
    }

    switch newRenderedSelection.count {
    case 0:
      return SidebarSessionListSelectionChange(
        nextSelection: [],
        storeSelection: .cleared
      )
    case 1:
      let sessionID = newRenderedSelection.first ?? ""
      if previousRenderedSelection.count > 1 {
        return SidebarSessionListSelectionChange(
          nextSelection: newRenderedSelection,
          storeSelection: .unchanged
        )
      }
      let storeSelection: SidebarSessionListSelectionChange.StoreSelection =
        if storeSelectedSessionID == sessionID {
          .unchanged
        } else {
          .selected(sessionID)
        }
      return SidebarSessionListSelectionChange(
        nextSelection: newRenderedSelection,
        storeSelection: storeSelection
      )
    default:
      return SidebarSessionListSelectionChange(
        nextSelection: newRenderedSelection,
        storeSelection: .unchanged
      )
    }
  }

  static func semanticActivation(
    sessionID: String,
    storeSelectedSessionID: String?
  ) -> SidebarSessionListSelectionChange {
    let storeSelection: SidebarSessionListSelectionChange.StoreSelection =
      if storeSelectedSessionID == sessionID {
        .unchanged
      } else {
        .selected(sessionID)
      }
    return SidebarSessionListSelectionChange(
      nextSelection: [sessionID],
      storeSelection: storeSelection
    )
  }
}
