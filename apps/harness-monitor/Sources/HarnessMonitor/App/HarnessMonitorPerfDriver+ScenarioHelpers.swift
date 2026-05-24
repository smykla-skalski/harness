import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

@MainActor
extension HarnessMonitorPerfDriver {
  static func openSettingsWindow(openWindow: OpenWindowAction) async {
    openWindow(id: HarnessMonitorWindowID.settings)
    await settle(.milliseconds(1_000))
  }

  static func openAppearanceSettings(openWindow: OpenWindowAction) async {
    UserDefaults.standard.set(
      HarnessMonitorBackdropMode.window.rawValue,
      forKey: HarnessMonitorBackdropDefaults.modeKey
    )
    await openSettingsWindow(openWindow: openWindow)
  }

  static func cycleBackdropModes() async {
    for mode in HarnessMonitorBackdropMode.allCases + [.window, .content] {
      UserDefaults.standard.set(mode.rawValue, forKey: HarnessMonitorBackdropDefaults.modeKey)
      try? await Task.sleep(for: stepDelay)
    }
    await settle()
  }

  static func cycleBackgroundSelections() async {
    UserDefaults.standard.set(
      HarnessMonitorBackdropMode.window.rawValue,
      forKey: HarnessMonitorBackdropDefaults.modeKey
    )

    let backgrounds =
      Array(
        HarnessMonitorBackgroundSelection.bundledLibrary.prefix(6)
      ) + [HarnessMonitorBackgroundSelection.defaultSelection]

    for background in backgrounds {
      UserDefaults.standard.set(
        background.storageValue,
        forKey: HarnessMonitorBackgroundDefaults.imageKey
      )
      try? await Task.sleep(for: stepDelay)
    }

    await settle()
  }

  static func burstTimeline(
    sessionID: String,
    store: HarnessMonitorStore
  ) async -> Bool {
    for batch in 1...8 {
      guard
        await store.replacePreviewTimeline(
          sessionID: sessionID,
          entries: PreviewFixtures.timelineBurst(batch: batch)
        )
      else {
        let sid = sessionID
        HarnessMonitorLogger.store.error(
          "Timeline perf scenario missing preview session snapshot for \(sid, privacy: .public)"
        )
        return false
      }
      try? await Task.sleep(for: shortDelay)
    }
    await settle()
    return true
  }

  static func churnToastOverlay(store: HarnessMonitorStore) async {
    let firstToast = store.presentSuccessFeedback("Observe session")
    try? await Task.sleep(for: shortDelay)

    let secondToast = store.presentFailureFeedback("Create task failed")
    try? await Task.sleep(for: shortDelay)

    let thirdToast = store.presentSuccessFeedback("Copied session ID")
    try? await Task.sleep(for: shortDelay)

    store.dismissFeedback(id: secondToast)
    try? await Task.sleep(for: shortDelay)

    let fourthToast = store.presentFailureFeedback("Observer unavailable")
    try? await Task.sleep(for: shortDelay)

    store.dismissFeedback(id: firstToast)
    try? await Task.sleep(for: shortDelay)

    store.dismissFeedback(id: fourthToast)
    try? await Task.sleep(for: shortDelay)

    store.dismissFeedback(id: thirdToast)
    await settle()
  }
}
