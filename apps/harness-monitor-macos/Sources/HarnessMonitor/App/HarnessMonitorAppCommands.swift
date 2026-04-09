import HarnessMonitorKit
import HarnessMonitorUI
import SwiftUI

struct HarnessMonitorAppCommands: Commands {
  @Environment(\.openWindow)
  private var openWindow
  @FocusedValue(\.commandsDisplayState)
  private var displayState
  @AppStorage("showInspector")
  private var showInspector = true
  let store: HarnessMonitorStore
  let searchController: SidebarSearchController
  let textSizeIndex: Int
  let increaseTextSize: () -> Void
  let decreaseTextSize: () -> Void
  let resetTextSize: () -> Void
  let refreshStore: () -> Void
  let startDaemon: () -> Void
  let installLaunchAgent: () -> Void
  let observeSelectedSession: () -> Void
  let endSelectedSession: () -> Void
  let inspectSessionOverview: () -> Void
  let inspectObserver: () -> Void

  private var canIncreaseTextSize: Bool {
    HarnessMonitorTextSize.canIncrease(textSizeIndex)
  }

  private var canDecreaseTextSize: Bool {
    HarnessMonitorTextSize.canDecrease(textSizeIndex)
  }

  var body: some Commands {
    SidebarCommands()
    TextEditingCommands()
    CommandGroup(replacing: .appSettings) {
      Button("Settings…") {
        openWindow(id: HarnessMonitorWindowID.preferences)
      }
      .keyboardShortcut(",", modifiers: .command)
    }
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
    }
    CommandGroup(before: .textEditing) {
      Button("Find Sessions") {
        searchController.requestFocus()
      }
      .keyboardShortcut("f", modifiers: .command)
    }
    CommandGroup(replacing: .help) {
      Link(
        "Harness Monitor Documentation",
        destination: URL(string: "https://github.com/smykla-skalski/harness")!
      )
    }
    CommandMenu("Harness Monitor") {
      Button("Refresh", action: refreshStore)
        .keyboardShortcut("r", modifiers: [.command, .shift])

      Divider()

      Button("Start Daemon", action: startDaemon)
      Button("Install Launch Agent", action: installLaunchAgent)

      Divider()

      Button("Back") {
        Task { await store.navigateBack() }
      }
      .keyboardShortcut("[", modifiers: [.command])
      .disabled(displayState?.canNavigateBack != true)

      Button("Forward") {
        Task { await store.navigateForward() }
      }
      .keyboardShortcut("]", modifiers: [.command])
      .disabled(displayState?.canNavigateForward != true)

      Divider()

      Button("Observe Selected Session", action: observeSelectedSession)
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(displayState?.hasSelectedSession != true || displayState?.isSessionReadOnly == true)

      Button("End Selected Session", action: endSelectedSession)
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(displayState?.hasSelectedSession != true || displayState?.isSessionReadOnly == true)

      Divider()

      Button(displayState?.bookmarkTitle ?? "Bookmark") {
        store.toggleSelectedSessionBookmark()
      }
      .keyboardShortcut("b", modifiers: [.command, .shift])
      .disabled(displayState?.hasSelectedSession != true || displayState?.isPersistenceAvailable != true)

      Button("Copy Selection ID") {
        store.copySelectedItemID()
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])
      .disabled(displayState?.hasSelectedSession != true)

      Divider()

      Button("Inspect Session Overview", action: inspectSessionOverview)
        .keyboardShortcut("1", modifiers: [.command, .option])
        .disabled(displayState?.hasSelectedSession != true)

      Button("Inspect Observer", action: inspectObserver)
        .keyboardShortcut("2", modifiers: [.command, .option])
        .disabled(displayState?.hasObserver != true)

      Divider()

      Button {
        showInspector.toggle()
      } label: {
        Text(showInspector ? "Hide Inspector" : "Show Inspector")
      }
      .keyboardShortcut("i", modifiers: [.command, .option])
    }
  }
}
