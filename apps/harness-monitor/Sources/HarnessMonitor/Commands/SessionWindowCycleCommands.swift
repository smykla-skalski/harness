import HarnessMonitorUIPreviewable
import SwiftUI

/// Restores the native Cmd+\` rotation for session windows that are merged
/// into AppKit tab groups. The system menu walks `NSApp.windows` in last-key
/// order, which skips tab siblings; our cycler expands tab groups so every
/// tab is a first-class rotation entry.
struct SessionWindowCycleCommands: Commands {
  nonisolated static let nextTitle = "Cycle Through Windows"
  nonisolated static let previousTitle = "Cycle Through Windows in Reverse"
  nonisolated static let cycleShortcut: KeyEquivalent = "`"

  var body: some Commands {
    CommandGroup(after: .windowArrangement) {
      Button(Self.nextTitle) {
        SessionWindowCycler.cycle(direction: .forward)
      }
      .keyboardShortcut(Self.cycleShortcut, modifiers: .command)

      Button(Self.previousTitle) {
        SessionWindowCycler.cycle(direction: .backward)
      }
      .keyboardShortcut(Self.cycleShortcut, modifiers: [.command, .shift])
    }
  }
}
