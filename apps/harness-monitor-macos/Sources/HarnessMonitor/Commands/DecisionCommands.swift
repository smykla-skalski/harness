import HarnessMonitorUIPreviewable
import SwiftUI

struct DecisionCommands: Commands {
  nonisolated static let menuTitle = "Decisions"
  nonisolated static let dismissSelectedTitle = "Dismiss Selected"
  nonisolated static let dismissVisibleTitle = "Dismiss All Visible"
  nonisolated static let reopenBatchTitle = "Reopen Dismissed Batch"

  @FocusedValue(\.sessionDecisionCommands)
  private var sessionDecisionCommands

  var body: some Commands {
    CommandMenu(Self.menuTitle) {
      Button(Self.dismissSelectedTitle) {
        sessionDecisionCommands?.dismissSelected()
      }
      .keyboardShortcut("d", modifiers: [.command, .shift])
      .disabled(sessionDecisionCommands?.canDismissSelected != true)

      Button(Self.dismissVisibleTitle) {
        sessionDecisionCommands?.dismissVisible()
      }
      .keyboardShortcut("d", modifiers: [.command, .option, .shift])
      .disabled(sessionDecisionCommands?.canDismissVisible != true)

      Button(Self.reopenBatchTitle) {
        sessionDecisionCommands?.reopenBatch()
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(sessionDecisionCommands?.canReopenBatch != true)
    }
  }
}
