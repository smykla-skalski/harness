import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct HarnessMonitorLaunchWindowRestorer: ViewModifier {
  private static let restoredSessionLimit = 4

  let store: HarnessMonitorStore
  let isEnabled: Bool
  @Environment(\.openWindow)
  private var openWindow
  @Environment(\.dismissWindow)
  private var dismissWindow
  @State private var didRestore = false

  func body(content: Content) -> some View {
    content.task {
      await restoreSessionWindowsIfNeeded()
    }
  }

  @MainActor
  private func restoreSessionWindowsIfNeeded() async {
    guard isEnabled, !didRestore else {
      return
    }
    didRestore = true
    await store.prepareOpenRecentSessions()
    let sessionIDs = await store.recentSessionIDsForLaunchWindows(
      limit: Self.restoredSessionLimit
    )
    for sessionID in sessionIDs {
      openWindow(
        id: HarnessMonitorWindowID.session,
        value: SessionWindowToken(sessionID: sessionID)
      )
    }
    if !sessionIDs.isEmpty {
      dismissWindow(id: HarnessMonitorWindowID.main)
    }
  }
}
