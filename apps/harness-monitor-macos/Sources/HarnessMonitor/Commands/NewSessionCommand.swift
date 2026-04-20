import HarnessMonitorKit
import SwiftUI

struct NewSessionCommand: Commands {
  let store: HarnessMonitorStore

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("New Session") { store.presentedSheet = .newSession }
        .keyboardShortcut("n", modifiers: [.command])
        .disabled(store.connectionState != .online)
    }
  }
}
