import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct HarnessMonitorAppCommands: Commands {
  private static var documentationURL: URL {
    guard let documentationURL = URL(string: "https://github.com/smykla-skalski/harness") else {
      preconditionFailure("Harness documentation URL must remain valid")
    }
    return documentationURL
  }

  @Environment(\.openWindow)
  private var openWindow
  @FocusedValue(\.harnessSidebarSearchFocusAction)
  private var sidebarSearchFocus
  let store: HarnessMonitorStore
  let displayState: CommandsDisplayState
  let textSizeIndex: Int
  let increaseTextSize: () -> Void
  let decreaseTextSize: () -> Void
  let resetTextSize: () -> Void
  let refreshStore: () -> Void

  private var canIncreaseTextSize: Bool {
    HarnessMonitorTextSize.canIncrease(textSizeIndex)
  }

  private var canDecreaseTextSize: Bool {
    HarnessMonitorTextSize.canDecrease(textSizeIndex)
  }

  var body: some Commands {
    systemCommands
    fileAndEditCommands
    viewCommands
    helpCommands
  }

  @CommandsBuilder private var systemCommands: some Commands {
    SidebarCommands()
    TextEditingCommands()
    CommandGroup(replacing: .appSettings) {
      Button("Settings…") {
        openWindow(id: HarnessMonitorWindowID.preferences)
      }
      .keyboardShortcut(",", modifiers: .command)
    }
  }

  @CommandsBuilder private var fileAndEditCommands: some Commands {
    CommandGroup(after: .newItem) {
      Button("New Task") {
        store.requestCreateTaskSheet()
      }
      .keyboardShortcut("t", modifiers: .command)
      .disabled(!displayState.hasSelectedSession || displayState.isSessionReadOnly)
    }
    CommandGroup(after: .textEditing) {
      Button("Find in Sessions") {
        sidebarSearchFocus?.invoke()
      }
      .keyboardShortcut("f", modifiers: .command)
      .disabled(sidebarSearchFocus?.isAvailable != true)
    }
  }

  @CommandsBuilder private var viewCommands: some Commands {
    CommandGroup(after: .toolbar) {
      Button("Increase Text Size", action: increaseTextSize)
        .keyboardShortcut("+", modifiers: .command)
        .disabled(!canIncreaseTextSize)

      Button("Decrease Text Size", action: decreaseTextSize)
        .keyboardShortcut("-", modifiers: .command)
        .disabled(!canDecreaseTextSize)

      Button("Reset Text Size", action: resetTextSize)
        .keyboardShortcut("0", modifiers: .command)
        .disabled(textSizeIndex == HarnessMonitorTextSize.defaultIndex)

      Divider()

      Button("Refresh", action: refreshStore)
        .keyboardShortcut("r", modifiers: [.command])
    }
  }

  @CommandsBuilder private var helpCommands: some Commands {
    CommandGroup(after: .help) {
      Link(
        "Harness Monitor Documentation",
        destination: Self.documentationURL
      )
    }
  }
}
