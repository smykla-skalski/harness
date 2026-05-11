import HarnessMonitorKit
import SwiftUI

extension AgentDetailSendUpdateSection {
  var isSessionReadOnly: Bool {
    store.isSessionReadOnly
  }

  var statusTint: Color {
    isSessionReadOnly ? HarnessMonitorTheme.secondaryInk : HarnessMonitorTheme.caution
  }

  var statusSymbolName: String {
    isSessionReadOnly ? "lock.fill" : "exclamationmark.circle"
  }
}
