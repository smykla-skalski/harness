import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct GoCommands: Commands {
  let store: HarnessMonitorStore
  let workspaceNavigationBridge: WorkspaceWindowNavigationBridge
  let windowCommandRouting: WindowCommandRoutingState
  let displayState: CommandsDisplayState

  private var activeScope: WindowNavigationScope {
    windowCommandRouting.activeScope ?? .main
  }

  private var canNavigateBack: Bool {
    switch activeScope {
    case .workspace:
      workspaceNavigationBridge.state.canGoBack
    case .session:
      false
    case .main:
      displayState.canNavigateBack
    }
  }

  private var canNavigateForward: Bool {
    switch activeScope {
    case .workspace:
      workspaceNavigationBridge.state.canGoForward
    case .session:
      false
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
      case .workspace:
        await workspaceNavigationBridge.navigateBack()
      case .session:
        break
      case .main:
        await store.navigateBack()
      }
    }
  }

  private func navigateForward() {
    let scope = activeScope
    Task {
      switch scope {
      case .workspace:
        await workspaceNavigationBridge.navigateForward()
      case .session:
        break
      case .main:
        await store.navigateForward()
      }
    }
  }
}
