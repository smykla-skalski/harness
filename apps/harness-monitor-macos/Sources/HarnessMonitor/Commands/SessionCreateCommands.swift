import HarnessMonitorUIPreviewable
import SwiftUI

struct SessionCreateCommands: Commands {
  @FocusedValue(\.sessionCreateContext)
  private var sessionCreate

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("New Agent") { sessionCreate?.createAgent() }
        .keyboardShortcut("a", modifiers: [.command, .option])
        .disabled(sessionCreate == nil)
      Button("New Task") { sessionCreate?.createTask() }
        .keyboardShortcut("t", modifiers: [.command, .option])
        .disabled(sessionCreate == nil)
      Button("New Decision") { sessionCreate?.createDecision() }
        .keyboardShortcut("d", modifiers: [.command, .option])
        .disabled(sessionCreate == nil)
    }
  }
}
