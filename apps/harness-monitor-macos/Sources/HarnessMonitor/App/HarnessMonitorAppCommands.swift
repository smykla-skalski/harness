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
  @FocusedValue(\.harnessAppSearchAction)
  private var appSearchFocus
  @FocusedValue(\.harnessSidebarVisibilityRequest)
  private var sidebarVisibilityRequest
  @FocusedValue(\.harnessSessionSidebarSelection)
  private var sidebarSelectionFocus
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
        openWindow(id: HarnessMonitorWindowID.settings)
      }
      .keyboardShortcut(",", modifiers: .command)
    }
  }

  @CommandsBuilder private var fileAndEditCommands: some Commands {
    CommandGroup(after: .newItem) {
      Button("New Task") {
        store.requestCreateTaskSheet()
      }
      .disabled(!displayState.hasSelectedSession || displayState.isSessionReadOnly)
      Button("Send Signal") {
        store.presentSendSignalSheetForSelectedSessionLeader()
      }
      .keyboardShortcut("s", modifiers: [.command, .shift])
      .disabled(!displayState.hasSelectedSession || displayState.isSessionReadOnly)
    }
    CommandGroup(after: .textEditing) {
      // Session-window unified search wins over the main app sidebar
      // search when its window is key, so Cmd-F lands in the toolbar
      // field for the focused session instead of the main sessions list.
      let resolvedLabel = appSearchFocus?.menuLabel
        ?? sidebarSearchFocus?.menuLabel
        ?? .findGeneric
      let resolvedIsAvailable = appSearchFocus?.isAvailable == true
        || sidebarSearchFocus?.isAvailable == true
      Button {
        if let appSearchFocus, appSearchFocus.isAvailable {
          appSearchFocus.invoke()
          return
        }
        // expand() is idempotent — the handler guards against no-op expansion.
        sidebarVisibilityRequest?.expander.expand()
        sidebarSearchFocus?.invoke()
      } label: {
        Text(resolvedLabel.localizedTitle)
      }
      .keyboardShortcut("f", modifiers: .command)
      .disabled(!resolvedIsAvailable)
      .help(resolvedIsAvailable ? "" : "Search isn't available on this view")
    }
    sidebarSelectionCommands
  }

  @CommandsBuilder private var sidebarSelectionCommands: some Commands {
    CommandGroup(after: .pasteboard) {
      Divider()
      Button("Select All in Sidebar") {
        sidebarSelectionFocus?.dispatcher.performSelectAll()
      }
      .keyboardShortcut("a", modifiers: [.command, .option])
      .disabled(sidebarSelectionFocus == nil)
      Button("Clear Sidebar Selection") {
        sidebarSelectionFocus?.dispatcher.performClearSelection()
      }
      .keyboardShortcut(.escape, modifiers: [])
      .disabled(sidebarSelectionFocus?.hasMultiSelection != true)
      Button("Delete Sidebar Selection") {
        sidebarSelectionFocus?.dispatcher.performDeleteSelection()
      }
      .keyboardShortcut(.delete, modifiers: [])
      .disabled(sidebarSelectionFocus?.canDelete != true)
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
