import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct WindowMenuCommands: Commands {
  nonisolated static let mainTitle = "Dashboard"

  @Environment(\.openWindow)
  private var openWindow

  var body: some Commands {
    CommandGroup(after: .windowList) {
      Button(Self.mainTitle) {
        openWindow.openHarnessDashboardWindow()
      }
      .keyboardShortcut("1", modifiers: [.command, .shift])
    }
  }
}
