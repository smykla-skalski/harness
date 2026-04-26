import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct SessionCommands: Commands {
  let store: HarnessMonitorStore
  let displayState: CommandsDisplayState

  var body: some Commands {
    CommandMenu("Session") {
      Button("Observe Selected Session", action: observeSelectedSession)
        .keyboardShortcut("o", modifiers: [.command, .option])
        .disabled(!displayState.hasSelectedSession || displayState.isSessionReadOnly)

      Button("End Selected Session", action: endSelectedSession)
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(!displayState.hasSelectedSession || displayState.isSessionReadOnly)

      Divider()

      Button(displayState.bookmarkTitle) {
        store.toggleSelectedSessionBookmark()
      }
      .keyboardShortcut("d", modifiers: [.command, .shift])
      .disabled(!displayState.hasSelectedSession || !displayState.isPersistenceAvailable)

      Button("Copy Selection ID") {
        store.copySelectedItemID()
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])
      .disabled(!displayState.hasSelectedSession)
    }
  }

  private func observeSelectedSession() {
    Task {
      await store.observeSelectedSession()
    }
  }

  private func endSelectedSession() {
    Task {
      await store.endSelectedSession()
    }
  }
}
