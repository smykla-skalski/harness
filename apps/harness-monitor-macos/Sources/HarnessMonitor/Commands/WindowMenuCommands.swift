import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct WindowMenuCommands: Commands {
  nonisolated static let mainTitle = "Welcome Recents"

  @Environment(\.openWindow)
  private var openWindow

  var body: some Commands {
    CommandGroup(after: .windowList) {
      Button(Self.mainTitle) {
        openWindow(id: HarnessMonitorWindowID.main)
      }
      .keyboardShortcut("1", modifiers: [.command, .shift])
    }
  }
}
