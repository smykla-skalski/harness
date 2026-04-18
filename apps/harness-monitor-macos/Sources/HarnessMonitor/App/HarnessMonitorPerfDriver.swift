import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

@MainActor
enum HarnessMonitorPerfDriver {
  private static let signpostBridge = HarnessMonitorSignpostBridge(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )
  private static let stepDelay: Duration = envMilliseconds(
    "HARNESS_MONITOR_PERF_STEP_DELAY_MS", fallback: 450
  )
  private static let shortDelay: Duration = envMilliseconds(
    "HARNESS_MONITOR_PERF_SHORT_DELAY_MS", fallback: 180
  )
  private static let settleDelay: Duration = envMilliseconds(
    "HARNESS_MONITOR_PERF_SETTLE_DELAY_MS", fallback: 900
  )

  private static func envMilliseconds(_ key: String, fallback: Int) -> Duration {
    guard let raw = ProcessInfo.processInfo.environment[key],
      let value = Int(raw), value > 0
    else {
      return .milliseconds(fallback)
    }
    return .milliseconds(value)
  }

  static func run(
    scenario: HarnessMonitorPerfScenario,
    store: HarnessMonitorStore,
    openWindow: OpenWindowAction
  ) async {
    await signpostBridge.withInterval(name: scenario.signpostName) {
      switch scenario {
      case .launchDashboard:
        await store.bootstrapIfNeeded()
        await settle()
      case .selectSessionCockpit:
        await settle()
        await store.selectSession(PreviewFixtures.summary.sessionId)
        await settle()
      case .refreshAndSearch:
        await settle()
        await store.refresh()
        await runSearchPasses(
          queries: ["timeline", "observer", "blocked"],
          store: store
        )
      case .sidebarOverflowSearch:
        await settle()
        await runSearchPasses(
          queries: ["sidebar", "search", "observer", "blocked", "transport"],
          store: store
        )
      case .settingsBackdropCycle:
        await openAppearanceSettings(openWindow: openWindow)
        await cycleBackdropModes()
      case .settingsBackgroundCycle:
        await openAppearanceSettings(openWindow: openWindow)
        await cycleBackgroundSelections()
      case .timelineBurst:
        await settle()
        await store.selectSession(PreviewFixtures.summary.sessionId)
        await burstTimeline(store: store)
      case .toastOverlayChurn:
        await settle()
        await store.selectSession(PreviewFixtures.summary.sessionId)
        await churnToastOverlay(store: store)
      case .offlineCachedOpen:
        await settle()
      }
    }
  }

  private static func settle(_ delay: Duration? = nil) async {
    try? await Task.sleep(for: delay ?? settleDelay)
  }

  private static func runSearchPasses(
    queries: [String],
    store: HarnessMonitorStore
  ) async {
    for query in queries {
      store.searchText = query
      try? await Task.sleep(for: stepDelay)
    }
    store.searchText = ""
    await settle()
  }

  private static func openAppearanceSettings(openWindow: OpenWindowAction) async {
    UserDefaults.standard.set(
      HarnessMonitorBackdropMode.window.rawValue,
      forKey: HarnessMonitorBackdropDefaults.modeKey
    )
    openWindow(id: HarnessMonitorWindowID.preferences)
    await settle(.milliseconds(1_000))
  }

  private static func cycleBackdropModes() async {
    for mode in HarnessMonitorBackdropMode.allCases + [.window, .content] {
      UserDefaults.standard.set(mode.rawValue, forKey: HarnessMonitorBackdropDefaults.modeKey)
      try? await Task.sleep(for: stepDelay)
    }
    await settle()
  }

  private static func cycleBackgroundSelections() async {
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

  private static func burstTimeline(store: HarnessMonitorStore) async {
    for batch in 1...8 {
      store.timeline = PreviewFixtures.timelineBurst(batch: batch)
      try? await Task.sleep(for: shortDelay)
    }
    await settle()
  }

  private static func churnToastOverlay(store: HarnessMonitorStore) async {
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

extension HarnessMonitorPerfScenario {
  var includesBootstrapInMeasurement: Bool {
    switch self {
    case .launchDashboard:
      true
    case .selectSessionCockpit,
      .refreshAndSearch,
      .sidebarOverflowSearch,
      .settingsBackdropCycle,
      .settingsBackgroundCycle,
      .timelineBurst,
      .toastOverlayChurn,
      .offlineCachedOpen:
      false
    }
  }

  var signpostName: StaticString {
    switch self {
    case .launchDashboard: "launch-dashboard"
    case .selectSessionCockpit: "select-session-cockpit"
    case .refreshAndSearch: "refresh-and-search"
    case .sidebarOverflowSearch: "sidebar-overflow-search"
    case .settingsBackdropCycle: "settings-backdrop-cycle"
    case .settingsBackgroundCycle: "settings-background-cycle"
    case .timelineBurst: "timeline-burst"
    case .toastOverlayChurn: "toast-overlay-churn"
    case .offlineCachedOpen: "offline-cached-open"
    }
  }
}
