import HarnessMonitorKit
import SwiftUI

struct OpenFolderCommand: Commands {
  let store: HarnessMonitorStore

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Open Folder…") { store.requestOpenFolder() }
        .keyboardShortcut("o", modifiers: [.command])
    }
  }
}
