import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct GoCommands: Commands {
  let store: HarnessMonitorStore
  let displayState: CommandsDisplayState
  @FocusedValue(\.windowNavigation)
  private var windowNavigation

  private var usesWindowHistory: Bool {
    windowNavigation != nil
  }

  private var canNavigateBack: Bool {
    if usesWindowHistory {
      windowNavigation?.canGoBack ?? false
    } else {
      displayState.canNavigateBack
    }
  }

  private var canNavigateForward: Bool {
    if usesWindowHistory {
      windowNavigation?.canGoForward ?? false
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

  @MainActor
  private func navigateBack() {
    if usesWindowHistory {
      windowNavigation?.navigateBack()
    } else {
      Task { await store.navigateBack() }
    }
  }

  @MainActor
  private func navigateForward() {
    if usesWindowHistory {
      windowNavigation?.navigateForward()
    } else {
      Task { await store.navigateForward() }
    }
  }
}
