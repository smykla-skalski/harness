import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct WindowMenuCommands: Commands {
  nonisolated static let workspaceTitle = "Workspace"
  nonisolated static let mainTitle = "Main"

  @Environment(\.openWindow)
  private var openWindow

  var body: some Commands {
    CommandGroup(after: .windowList) {
      Button(Self.workspaceTitle) {
        openWindow(id: HarnessMonitorWindowID.workspace)
      }
      .keyboardShortcut("1", modifiers: [.command, .shift])

      Button(Self.mainTitle) {
        openWindow(id: HarnessMonitorWindowID.main)
      }
      .keyboardShortcut("2", modifiers: [.command, .shift])
    }
  }
}
