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
  @AppStorage("showInspector")
  private var showInspector = true
  let store: HarnessMonitorStore
  let agentTuiNavigationBridge: AgentTuiWindowNavigationBridge
  let windowCommandRouting: WindowCommandRoutingState
  let displayState: CommandsDisplayState
  let textSizeIndex: Int
  let increaseTextSize: () -> Void
  let decreaseTextSize: () -> Void
  let resetTextSize: () -> Void
  let refreshStore: () -> Void
  let focusSidebarSearch: () -> Void
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

  private var canNavigateBack: Bool {
    switch activeWindowNavigationScope {
    case .agents:
      agentTuiNavigationBridge.state.canGoBack
    case .main:
      displayState.canNavigateBack
    }
  }

  private var canNavigateForward: Bool {
    switch activeWindowNavigationScope {
    case .agents:
      agentTuiNavigationBridge.state.canGoForward
    case .main:
      displayState.canNavigateForward
    }
  }

  private var activeWindowNavigationScope: WindowNavigationScope {
    windowCommandRouting.activeScope ?? .main
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
    CommandGroup(replacing: .help) {
      Link(
        "Harness Monitor Documentation",
        destination: Self.documentationURL
      )
    }
    CommandGroup(after: .newItem) {
      Button("Attach External Session…") {
        store.requestAttachExternalSession()
      }
      .keyboardShortcut("a", modifiers: [.command, .shift])
    }
    CommandMenu("Harness Monitor") {
      Button("Find in Sessions", action: focusSidebarSearch)
        .keyboardShortcut("f", modifiers: .command)

      Button("Refresh", action: refreshStore)
        .keyboardShortcut("r", modifiers: [.command, .shift])

      Divider()

      Button("Start Daemon", action: startDaemon)
      Button("Install Launch Agent", action: installLaunchAgent)

      Divider()

      Button("Back") {
        navigateBack()
      }
      .keyboardShortcut("[", modifiers: [.command])
      .disabled(!canNavigateBack)

      Button("Forward") {
        navigateForward()
      }
      .keyboardShortcut("]", modifiers: [.command])
      .disabled(!canNavigateForward)

      Divider()

      Button("Observe Selected Session", action: observeSelectedSession)
        .keyboardShortcut("o", modifiers: [.command, .option])
        .disabled(!displayState.hasSelectedSession || displayState.isSessionReadOnly)

      Button("End Selected Session", action: endSelectedSession)
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(!displayState.hasSelectedSession || displayState.isSessionReadOnly)

      Divider()

      Button(displayState.bookmarkTitle) {
        store.toggleSelectedSessionBookmark()
      }
      .keyboardShortcut("b", modifiers: [.command, .shift])
      .disabled(!displayState.hasSelectedSession || !displayState.isPersistenceAvailable)

      Button("Copy Selection ID") {
        store.copySelectedItemID()
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])
      .disabled(!displayState.hasSelectedSession)

      Divider()

      Button("Inspect Session Overview", action: inspectSessionOverview)
        .keyboardShortcut("1", modifiers: [.command, .option])
        .disabled(!displayState.hasSelectedSession)

      Button("Inspect Observer", action: inspectObserver)
        .keyboardShortcut("2", modifiers: [.command, .option])
        .disabled(!displayState.hasObserver)

      Divider()

      Button {
        showInspector.toggle()
      } label: {
        Text(showInspector ? "Hide Inspector" : "Show Inspector")
      }
      .keyboardShortcut("i", modifiers: [.command, .option])
    }
  }

  private func navigateBack() {
    let scope = activeWindowNavigationScope
    Task {
      switch scope {
      case .agents:
        await agentTuiNavigationBridge.navigateBack()
      case .main:
        await store.navigateBack()
      }
    }
  }

  private func navigateForward() {
    let scope = activeWindowNavigationScope
    Task {
      switch scope {
      case .agents:
        await agentTuiNavigationBridge.navigateForward()
      case .main:
        await store.navigateForward()
      }
    }
  }
}
