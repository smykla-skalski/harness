import HarnessMonitorKit
import SwiftUI

extension AgentTuiWindowView {
  func consumePendingAgentsWindowSelection() {
    guard let pending = store.consumePendingAgentsWindowSelection() else {
      return
    }
    applyProgrammaticSelection(pending)
  }
}
