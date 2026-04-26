import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct GoCommands: Commands {
  let store: HarnessMonitorStore
  let agentsNavigationBridge: AgentsWindowNavigationBridge
  let windowCommandRouting: WindowCommandRoutingState
  let displayState: CommandsDisplayState

  private var activeScope: WindowNavigationScope {
    windowCommandRouting.activeScope ?? .main
  }

  private var canNavigateBack: Bool {
    switch activeScope {
    case .agents:
      agentsNavigationBridge.state.canGoBack
    case .main:
      displayState.canNavigateBack
    }
  }

  private var canNavigateForward: Bool {
    switch activeScope {
    case .agents:
      agentsNavigationBridge.state.canGoForward
    case .main:
      displayState.canNavigateForward
    }
  }

  var body: some Commands {
    CommandMenu("Go") {
      Button("Back", action: navigateBack)
        .keyboardShortcut("[", modifiers: [.command])
        .disabled(!canNavigateBack)

      Button("Forward", action: navigateForward)
        .keyboardShortcut("]", modifiers: [.command])
        .disabled(!canNavigateForward)
    }
  }

  private func navigateBack() {
    let scope = activeScope
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
    let scope = activeScope
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
