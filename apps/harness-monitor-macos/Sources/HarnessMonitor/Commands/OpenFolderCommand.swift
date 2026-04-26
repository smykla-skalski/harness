import HarnessMonitorKit
import SwiftUI

struct OpenFolderCommand: Commands {
  @Binding var isPresented: Bool

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Open Folder…") { isPresented = true }
        .keyboardShortcut("o", modifiers: [.command])
    }
  }
}
