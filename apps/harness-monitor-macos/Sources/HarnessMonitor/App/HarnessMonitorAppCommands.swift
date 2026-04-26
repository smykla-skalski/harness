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
  @AppStorage("showInspector")
  private var showInspector = true
  let store: HarnessMonitorStore
  let agentsNavigationBridge: AgentsWindowNavigationBridge
  let windowCommandRouting: WindowCommandRoutingState
  let displayState: CommandsDisplayState
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

  private var canNavigateBack: Bool {
    switch activeWindowNavigationScope {
    case .agents:
      agentsNavigationBridge.state.canGoBack
    case .main:
      displayState.canNavigateBack
    }
  }

  private var canNavigateForward: Bool {
    switch activeWindowNavigationScope {
    case .agents:
      agentsNavigationBridge.state.canGoForward
    case .main:
      displayState.canNavigateForward
    }
  }

  private var activeWindowNavigationScope: WindowNavigationScope {
    windowCommandRouting.activeScope ?? .main
  }

  var body: some Commands {
    systemCommands
    fileAndEditCommands
    viewCommands
    navigationAndDaemonCommands
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
    CommandGroup(after: .textEditing) {
      Button("Find in Sessions") {
        sidebarSearchFocus?.invoke()
      }
      .keyboardShortcut("f", modifiers: .command)
      .disabled(sidebarSearchFocus?.isAvailable != true)
    }
  }

  @CommandsBuilder private var viewCommands: some Commands {
    CommandGroup(after: .sidebar) {
      Button {
        showInspector.toggle()
      } label: {
        Text(showInspector ? "Hide Inspector" : "Show Inspector")
      }
      .keyboardShortcut("i", modifiers: [.command, .option])
    }
    CommandGroup(after: .toolbar) {
      Button("Inspect Session Overview", action: inspectSessionOverview)
        .keyboardShortcut("1", modifiers: [.command, .option])
        .disabled(!displayState.hasSelectedSession)

      Button("Inspect Observer", action: inspectObserver)
        .keyboardShortcut("2", modifiers: [.command, .option])
        .disabled(!displayState.hasObserver)

      Divider()

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
        .keyboardShortcut("r", modifiers: [.command, .shift])
    }
  }

  @CommandsBuilder private var navigationAndDaemonCommands: some Commands {
    CommandMenu("Go") {
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
    }
    CommandMenu("Session") {
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
    }
    CommandMenu("Daemon") {
      Button("Start Daemon", action: startDaemon)
      Button("Install Launch Agent", action: installLaunchAgent)
    }
  }

  @CommandsBuilder private var helpCommands: some Commands {
    CommandGroup(replacing: .help) {
      Link(
        "Harness Monitor Documentation",
        destination: Self.documentationURL
      )
    }
  }

  private func navigateBack() {
    let scope = activeWindowNavigationScope
    Task {
      switch scope {
      case .agents:
        await agentsNavigationBridge.navigateBack()
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
        await agentsNavigationBridge.navigateForward()
      case .main:
        await store.navigateForward()
      }
    }
  }
}
