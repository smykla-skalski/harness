import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  @discardableResult
  func consumePendingWorkspaceSelection() -> Bool {
    guard let pending = store.consumePendingWorkspaceSelectionRequest() else {
      return false
    }
    if pending.resetDecisionFilters {
      WorkspaceDecisionFilterDefaults.reset()
      decisionFilters = Self.initialDecisionFilters
    }
    applyProgrammaticSelection(pending.selection, recordHistory: true)
    return true
  }

  func resolveInitialWorkspaceSelection() {
    _ = consumePendingWorkspaceSelection()
  }
}
