import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct WindowMenuCommands: Commands {
  @Environment(\.openWindow)
  private var openWindow
  private let supervisorToolbarSlice: SupervisorToolbarSlice

  init(supervisorToolbarSlice: SupervisorToolbarSlice) {
    self.supervisorToolbarSlice = supervisorToolbarSlice
  }

  var body: some Commands {
    @Bindable var supervisorToolbarSlice = supervisorToolbarSlice

    CommandGroup(after: .windowList) {
      Button("Agents") {
        openWindow(id: HarnessMonitorWindowID.agents)
      }
      .keyboardShortcut("1", modifiers: [.command, .shift])

      Button(Self.decisionsTitle(for: supervisorToolbarSlice.count)) {
        openWindow(id: HarnessMonitorWindowID.decisions)
      }
      .keyboardShortcut("2", modifiers: [.command, .shift])

      Button("Main") {
        openWindow(id: HarnessMonitorWindowID.main)
      }
      .keyboardShortcut("3", modifiers: [.command, .shift])
    }
  }

  nonisolated static func decisionsTitle(for count: Int) -> String {
    guard count > 0 else {
      return "Decisions"
    }
    return "Decisions (\(count))"
  }
}
