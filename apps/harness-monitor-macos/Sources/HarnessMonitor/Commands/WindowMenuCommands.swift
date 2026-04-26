import HarnessMonitorUIPreviewable
import SwiftUI

struct WindowMenuCommands: Commands {
  @Environment(\.openWindow)
  private var openWindow

  var body: some Commands {
    CommandGroup(after: .windowList) {
      Button("Agents") {
        openWindow(id: HarnessMonitorWindowID.agents)
      }
      .keyboardShortcut("1", modifiers: [.command, .shift])

      Button("Decisions") {
        openWindow(id: HarnessMonitorWindowID.decisions)
      }
      .keyboardShortcut("2", modifiers: [.command, .shift])

      Button("Main") {
        openWindow(id: HarnessMonitorWindowID.main)
      }
      .keyboardShortcut("3", modifiers: [.command, .shift])
    }
  }
}
