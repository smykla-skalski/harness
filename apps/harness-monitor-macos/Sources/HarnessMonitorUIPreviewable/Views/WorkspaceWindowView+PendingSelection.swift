import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  @discardableResult
  func consumePendingWorkspaceSelection() -> Bool {
    guard let pending = store.consumePendingWorkspaceSelection() else {
      return false
    }
    applyProgrammaticSelection(pending, recordHistory: true)
    return true
  }

  func resolveInitialWorkspaceSelection() {
    _ = consumePendingWorkspaceSelection()
  }
}
