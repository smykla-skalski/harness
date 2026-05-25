import HarnessMonitorUIPreviewable
import SwiftUI

struct ReviewCommands: Commands {
  @FocusedValue(\.dashboardReviewsCommands)
  private var reviewCommands
  @FocusedValue(\.dashboardReviewFilesConversationCommand)
  private var filesConversationCommand

  var body: some Commands {
    CommandMenu("Reviews") {
      Button("Approve Selection") {
        reviewCommands?.approve()
      }
      .keyboardShortcut("a", modifiers: [.command, .option, .shift])
      .disabled(reviewCommands?.canApprove != true)

      Button("Merge Selection") {
        reviewCommands?.merge()
      }
      .keyboardShortcut("m", modifiers: [.command, .option, .shift])
      .disabled(reviewCommands?.canMerge != true)

      Button("Rerun Checks") {
        reviewCommands?.rerunChecks()
      }
      .keyboardShortcut("r", modifiers: [.command, .option, .shift])
      .disabled(reviewCommands?.canRerunChecks != true)

      Button(reviewCommands?.pinSelectionTitle ?? "Pin Selection") {
        reviewCommands?.togglePinSelection()
      }
      .keyboardShortcut("p", modifiers: [.command, .option, .shift])
      .disabled(reviewCommands?.canTogglePinSelection != true)

      Divider()

      Button("Open Pull Request") {
        reviewCommands?.openPullRequest()
      }
      .keyboardShortcut("o", modifiers: [.command, .option, .shift])
      .disabled(reviewCommands?.canOpenPullRequest != true)

      Button("Copy Diagnostics") {
        reviewCommands?.copyDiagnostics()
      }
      .keyboardShortcut("d", modifiers: [.command, .option, .shift])
      .disabled(reviewCommands?.canCopyDiagnostics != true)

      Divider()

      Toggle("Failed Checks Only", isOn: failedChecksOnlyBinding)
        .keyboardShortcut("f", modifiers: [.command, .option, .shift])
        .disabled(reviewCommands == nil)

      Button(filesConversationCommandTitle) {
        filesConversationCommand?.cycle()
      }
      .keyboardShortcut("c", modifiers: [.command, .option, .shift])
      .disabled(filesConversationCommand == nil)
    }
  }

  private var filesConversationCommandTitle: String {
    guard let current = filesConversationCommand?.currentTitle else {
      return "Cycle Inline Conversations"
    }
    return "Cycle Inline Conversations (\(current))"
  }

  private var failedChecksOnlyBinding: Binding<Bool> {
    Binding(
      get: { reviewCommands?.hasProblemChecksFilter ?? false },
      set: { _ in reviewCommands?.toggleProblemChecksFilter() }
    )
  }
}
