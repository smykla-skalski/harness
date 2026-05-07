import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct WindowMenuCommands: Commands {
  nonisolated static let mainTitle = "Open Recent Session"
  nonisolated static let newTabTitle = "New Tab"
  nonisolated static let newTabShortcut: KeyEquivalent = "t"

  @Environment(\.openWindow)
  private var openWindow
  let store: HarnessMonitorStore
  let displayState: CommandsDisplayState

  var body: some Commands {
    CommandGroup(after: .windowList) {
      Button(Self.newTabTitle) {
        openSessionTab()
      }
      .keyboardShortcut(Self.newTabShortcut, modifiers: .command)

      Button(Self.mainTitle) {
        openWindow(id: HarnessMonitorWindowID.main)
      }
      .keyboardShortcut("1", modifiers: [.command, .shift])
    }
  }

  private func openSessionTab() {
    guard displayState.hasSelectedSession, let sessionID = store.selectedSessionID else {
      store.presentedSheet = .newSession
      return
    }
    openWindow(
      id: HarnessMonitorWindowID.main,
      value: SessionWindowToken(sessionID: sessionID)
    )
  }
}
