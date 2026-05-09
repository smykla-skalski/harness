import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct RecentSessionsCommand: Commands {
  static let menuTitle = "Open Recent Session"
  static let emptyTitle = "No Recent Sessions"
  static let showWindowTitle = "Show Open Recent Window"
  private static let maxRecentSessions = 10

  let store: HarnessMonitorStore
  @Environment(\.openWindow)
  private var openWindow

  private var recentSessions: [SessionSummary] {
    Array(store.recentSessions.prefix(Self.maxRecentSessions))
  }

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Menu(Self.menuTitle) {
        if recentSessions.isEmpty {
          Button(Self.emptyTitle) {}
            .disabled(true)
        } else {
          ForEach(recentSessions) { session in
            Button(session.displayTitle) {
              openWindow.openHarnessSessionWindow(sessionID: session.sessionId)
            }
          }
          Divider()
        }

        Button(Self.showWindowTitle) {
          openWindow(id: HarnessMonitorWindowID.openRecent)
        }
      }
    }
  }
}
