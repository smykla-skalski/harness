import HarnessKit
import SwiftUI

struct HarnessAppCommands: Commands {
  @Environment(\.openWindow)
  private var openWindow
  let store: HarnessStore
  let textSizeIndex: Int
  let inspectorVisibility: Binding<Bool>?
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
    HarnessTextSize.canIncrease(textSizeIndex)
  }

  private var canDecreaseTextSize: Bool {
    HarnessTextSize.canDecrease(textSizeIndex)
  }

  private var isInspectorVisible: Bool {
    inspectorVisibility?.wrappedValue == true
  }

  var body: some Commands {
    SidebarCommands()
    TextEditingCommands()
    CommandGroup(replacing: .appSettings) {
      Button("Settings…") {
        openWindow(id: HarnessWindowID.preferences)
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
        .disabled(textSizeIndex == HarnessTextSize.defaultIndex)
    }
    CommandGroup(replacing: .help) {
      Link(
        "Harness Documentation",
        destination: URL(string: "https://github.com/smykla-skalski/harness")!
      )
    }
    CommandMenu("Harness") {
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
      .disabled(!store.canNavigateBack)

      Button("Forward") {
        Task { await store.navigateForward() }
      }
      .keyboardShortcut("]", modifiers: [.command])
      .disabled(!store.canNavigateForward)

      Divider()

      Button("Observe Selected Session", action: observeSelectedSession)
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(store.selectedSessionID == nil || store.isSessionReadOnly)

      Button("End Selected Session", action: endSelectedSession)
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(store.selectedSessionID == nil || store.isSessionReadOnly)

      Divider()

      Button(store.selectedSessionBookmarkTitle) {
        store.toggleSelectedSessionBookmark()
      }
      .keyboardShortcut("b", modifiers: [.command, .shift])
      .disabled(store.selectedSessionID == nil || !store.isPersistenceAvailable)

      Button("Copy Selection ID") {
        store.copySelectedItemID()
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])
      .disabled(store.selectedSessionID == nil)

      Divider()

      Button("Inspect Session Overview", action: inspectSessionOverview)
        .keyboardShortcut("1", modifiers: [.command, .option])
        .disabled(store.selectedSessionID == nil)

      Button("Inspect Observer", action: inspectObserver)
        .keyboardShortcut("2", modifiers: [.command, .option])
        .disabled(store.selectedSession?.observer == nil)

      Divider()

      Button {
        inspectorVisibility?.wrappedValue.toggle()
      } label: {
        Text(isInspectorVisible ? "Hide Inspector" : "Show Inspector")
      }
      .keyboardShortcut("i", modifiers: [.command, .option])
      .disabled(inspectorVisibility == nil)
    }
  }
}
