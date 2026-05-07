import HarnessMonitorUIPreviewable
import SwiftUI

struct InspectorCommands: Commands {
  @FocusedValue(\.sessionInspector) private var sessionInspector

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Button(inspectorMenuTitle) {
        sessionInspector?.toggle()
      }
      .keyboardShortcut("i", modifiers: [.command, .option])
      .disabled(sessionInspector == nil)
    }
  }

  private var inspectorMenuTitle: String {
    sessionInspector?.isVisible == true ? "Hide Inspector" : "Show Inspector"
  }
}
