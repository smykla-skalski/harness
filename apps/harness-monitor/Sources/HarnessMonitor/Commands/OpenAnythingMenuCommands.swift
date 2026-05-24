import HarnessMonitorKit
import SwiftUI

/// Top-level Commands struct that contributes the Open Anything entries to
/// the File menu. Lifted out of `HarnessMonitorAppCommands.fileAndEditCommands`
/// because nesting multiple `CommandGroup(after: .newItem)` blocks inside a
/// single Commands struct silently drops every group except the first on
/// macOS. Keeping this as a sibling of the other `(after: .newItem)`
/// command contributors guarantees the menu actually renders the items.
struct OpenAnythingMenuCommands: Commands {
  let presentOpenAnything: () -> Void
  let presentOpenAnythingSessions: () -> Void
  let openAnythingCorpusSize: () -> Int

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button(menuTitle, action: presentOpenAnything)
        .keyboardShortcut("k", modifiers: .command)
      Button("Open Anything (Sessions)", action: presentOpenAnythingSessions)
        .keyboardShortcut("k", modifiers: [.command, .shift])
    }
  }

  private var menuTitle: LocalizedStringKey {
    #if DEBUG
      "Open Anything (\(openAnythingCorpusSize()))"
    #else
      "Open Anything"
    #endif
  }
}
