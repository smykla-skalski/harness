import HarnessMonitorKit
import SwiftUI

struct AttachExternalSessionCommand: Commands {
  let store: HarnessMonitorStore

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Attach External Session…") {
        store.requestAttachExternalSession()
      }
      .keyboardShortcut("o", modifiers: [.command, .shift])
    }
  }
}
