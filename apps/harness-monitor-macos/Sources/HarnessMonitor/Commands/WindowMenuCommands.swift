import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct WindowMenuCommands: Commands {
  nonisolated static let mainTitle = "Dashboard"
  nonisolated static let newTabTitle = "New Tab"
  nonisolated static let newTabShortcut: KeyEquivalent = "t"

  enum NewTabDestination: Equatable {
    case newSessionSheet
    case session(String)
  }

  @Environment(\.openWindow)
  private var openWindow
  @FocusedValue(\.sessionNavigation)
  private var sessionNavigation
  let store: HarnessMonitorStore

  var body: some Commands {
    CommandGroup(after: .windowList) {
      Button(Self.newTabTitle) {
        openSessionTab()
      }
      .keyboardShortcut(Self.newTabShortcut, modifiers: .command)

      Button(Self.mainTitle) {
        openWindow.openHarnessDashboardWindow()
      }
      .keyboardShortcut("1", modifiers: [.command, .shift])
    }
  }

  private func openSessionTab() {
    switch Self.newTabDestination(sessionNavigation: sessionNavigation) {
    case .newSessionSheet:
      store.presentedSheet = .newSession
    case .session(let sessionID):
      openWindow.openHarnessSessionWindow(sessionID: sessionID)
    }
  }

  nonisolated static func newTabDestination(
    sessionNavigation: SessionNavigationCommand?
  ) -> NewTabDestination {
    guard let sessionID = sessionNavigation?.sessionID, !sessionID.isEmpty else {
      return .newSessionSheet
    }
    return .session(sessionID)
  }
}
