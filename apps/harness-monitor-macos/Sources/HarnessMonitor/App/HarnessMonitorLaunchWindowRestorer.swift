import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct HarnessMonitorLaunchWindowRestorer: ViewModifier {
  private static let restoredSessionLimit = 4

  let store: HarnessMonitorStore
  let isEnabled: Bool
  @Environment(\.openWindow)
  private var openWindow
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
    await store.bootstrapIfNeeded()
    let sessionIDs = await store.recentSessionIDsForLaunchWindows(
      limit: Self.restoredSessionLimit
    )
    for sessionID in sessionIDs {
      openWindow(
        id: HarnessMonitorWindowID.session,
        value: SessionWindowToken(sessionID: sessionID)
      )
    }
  }
}
