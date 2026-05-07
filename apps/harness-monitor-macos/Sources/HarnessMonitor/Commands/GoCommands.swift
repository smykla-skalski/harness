import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct GoCommands: Commands {
  let store: HarnessMonitorStore
  let workspaceNavigationBridge: WorkspaceWindowNavigationBridge
  let windowCommandRouting: WindowCommandRoutingState
  let displayState: CommandsDisplayState
  @FocusedValue(\.sessionNavigation)
  private var sessionNavigation

  private var activeScope: WindowNavigationScope {
    windowCommandRouting.activeScope ?? .main
  }

  private var canNavigateBack: Bool {
    switch activeScope {
    case .workspace:
      workspaceNavigationBridge.state.canGoBack
    case .session:
      sessionNavigation?.canGoBack ?? false
    case .main:
      displayState.canNavigateBack
    }
  }

  private var canNavigateForward: Bool {
    switch activeScope {
    case .workspace:
      workspaceNavigationBridge.state.canGoForward
    case .session:
      sessionNavigation?.canGoForward ?? false
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
    switch scope {
    case .workspace:
      Task { await workspaceNavigationBridge.navigateBack() }
    case .session:
      sessionNavigation?.goBack()
    case .main:
      Task { await store.navigateBack() }
    }
  }

  private func navigateForward() {
    let scope = activeScope
    switch scope {
    case .workspace:
      Task { await workspaceNavigationBridge.navigateForward() }
    case .session:
      sessionNavigation?.goForward()
    case .main:
      Task { await store.navigateForward() }
    }
  }
}
