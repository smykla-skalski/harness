import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  func consumePendingWorkspaceSelection() {
    guard let pending = store.consumePendingWorkspaceSelection() else {
      return
    }
    applyProgrammaticSelection(pending, recordHistory: true)
  }
}
