import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct GoCommands: Commands {
  let store: HarnessMonitorStore
  let displayState: CommandsDisplayState
  @FocusedValue(\.sessionNavigation)
  private var sessionNavigation

  private var usesSessionHistory: Bool {
    sessionNavigation != nil
  }

  private var canNavigateBack: Bool {
    if usesSessionHistory {
      sessionNavigation?.canGoBack ?? false
    } else {
      displayState.canNavigateBack
    }
  }

  private var canNavigateForward: Bool {
    if usesSessionHistory {
      sessionNavigation?.canGoForward ?? false
    } else {
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
    if usesSessionHistory {
      sessionNavigation?.goBack()
    } else {
      Task { await store.navigateBack() }
    }
  }

  private func navigateForward() {
    if usesSessionHistory {
      sessionNavigation?.goForward()
    } else {
      Task { await store.navigateForward() }
    }
  }
}
