import HarnessMonitorKit
import SwiftUI

extension AgentsWindowView {
  func consumePendingAgentsWindowSelection() {
    guard let pending = store.consumePendingAgentsWindowSelection() else {
      return
    }
    applyProgrammaticSelection(pending)
  }
}
