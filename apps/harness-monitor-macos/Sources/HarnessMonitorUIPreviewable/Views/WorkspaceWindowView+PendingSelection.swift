import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  func consumePendingWorkspaceSelection() {
    guard let pending = store.consumePendingWorkspaceSelection() else {
      return
    }
    applyProgrammaticSelection(pending, recordHistory: true)
  }
}
