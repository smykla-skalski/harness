import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct LaunchWindowRestorerMigrator: ViewModifier {
  private static let restoredSessionLimit = 4

  let store: HarnessMonitorStore
  let isEnabled: Bool
  @Environment(\.openWindow)
  private var openWindow
  @Environment(\.dismissWindow)
  private var dismissWindow
  @State private var didRun = false

  func body(content: Content) -> some View {
    content.task {
      await runIfNeeded()
    }
  }

  @MainActor
  private func runIfNeeded() async {
    guard isEnabled, !didRun else {
      return
    }
    didRun = true
    await store.prepareOpenRecentSessions()
    let sessionIDs = await store.recentSessionIDsForLaunchWindows(
      limit: Self.restoredSessionLimit
    )
    for sessionID in sessionIDs {
      openWindow(
        id: HarnessMonitorWindowID.main,
        value: SessionWindowToken(sessionID: sessionID)
      )
    }
    if !sessionIDs.isEmpty {
      dismissWindow(id: HarnessMonitorWindowID.main)
    }
  }
}
