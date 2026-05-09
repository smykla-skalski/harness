import HarnessMonitorUIPreviewable
import SwiftUI

struct SessionCreateCommands: Commands {
  @FocusedValue(\.sessionCreateContext)
  private var sessionCreate

  static func shouldShowExplicitCommand(
    for kind: SessionCreateKind,
    primaryKind: SessionCreateKind?
  ) -> Bool {
    primaryKind != kind
  }

  var body: some Commands {
    let primaryKind = sessionCreate?.primaryKind
    CommandGroup(after: .newItem) {
      if Self.shouldShowExplicitCommand(for: .agent, primaryKind: primaryKind) {
        Button("New Agent") { sessionCreate?.createAgent() }
          .keyboardShortcut("a", modifiers: [.command, .option])
          .disabled(sessionCreate == nil)
      }
      Button("New Codex Agent") { sessionCreate?.createCodexAgent() }
        .disabled(sessionCreate == nil)
      if Self.shouldShowExplicitCommand(for: .task, primaryKind: primaryKind) {
        Button("New Task") { sessionCreate?.createTask() }
          .keyboardShortcut("t", modifiers: [.command, .option])
          .disabled(sessionCreate == nil)
      }
      if Self.shouldShowExplicitCommand(for: .decision, primaryKind: primaryKind) {
        Button("New Decision") { sessionCreate?.createDecision() }
          .keyboardShortcut("d", modifiers: [.command, .option])
          .disabled(sessionCreate == nil)
      }
    }
  }
}
