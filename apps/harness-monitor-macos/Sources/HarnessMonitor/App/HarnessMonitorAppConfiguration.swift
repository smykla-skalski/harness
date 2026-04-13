import Foundation
import HarnessMonitorKit
import HarnessMonitorUI
import SwiftData

struct HarnessMonitorAppConfiguration {
  private static let uiTestingBundleIdentifier = "io.harnessmonitor.app.ui-testing"
  private static let uiTestsEnvironmentKey = "HARNESS_MONITOR_UI_TESTS"
  private static let uiTestDefaultDataRootName = "HarnessMonitorUITestHost"
  private static let toastDismissOverrideKey = "HARNESS_MONITOR_TEST_TOAST_DISMISS_MS"
  private static let toastSeedKey = "HARNESS_MONITOR_TEST_SEED_TOASTS"

  let container: ModelContainer?
  let store: HarnessMonitorStore
  let launchMode: HarnessMonitorLaunchMode
  let initialThemeMode: HarnessMonitorThemeMode
  let isUITesting: Bool
  let mainWindowDefaultSize: CGSize
  let perfScenario: HarnessMonitorPerfScenario?
  let preferencesInitialSection: PreferencesSection

  @MainActor
  static func resolve() -> Self {
    var registrationDefaults: [String: Any] = [
      HarnessMonitorBackdropDefaults.modeKey: HarnessMonitorBackdropMode.none.rawValue,
      HarnessMonitorBackgroundDefaults.imageKey:
        HarnessMonitorBackgroundSelection.defaultSelection.storageValue,
      HarnessMonitorTextSize.storageKey: HarnessMonitorTextSize.defaultIndex,
      HarnessMonitorDateTimeConfiguration.timeZoneModeKey:
        HarnessMonitorDateTimeConfiguration.defaultTimeZoneModeRawValue,
      HarnessMonitorDateTimeConfiguration.customTimeZoneIdentifierKey:
        HarnessMonitorDateTimeConfiguration.defaultCustomTimeZoneIdentifier,
      HarnessMonitorCornerAnimationDefaults.enabledKey: false,
      "showInspector": true,
      "inspectorColumnWidth": 420.0,
    ]
    registrationDefaults.merge(
      HarnessMonitorVoicePreferences.registrationDefaults()
    ) { _, newValue in newValue }
    UserDefaults.standard.register(defaults: registrationDefaults)

    let environment = uiTestSafeEnvironment()
    let perfScenario = HarnessMonitorPerfScenario(environment: environment)
    let resolvedEnvironment = perfScenario?.applyingDefaults(to: environment) ?? environment
    let isUITesting = resolvedEnvironment.values[uiTestsEnvironmentKey] == "1"
    let launchMode = HarnessMonitorLaunchMode(environment: resolvedEnvironment)
    let uiTestOverrides = resolveUITestOverrides(
      isUITesting: isUITesting,
      environment: resolvedEnvironment
    )
    let persistenceSetup = HarnessMonitorPersistenceSetup.resolve(
      environment: resolvedEnvironment,
      launchMode: launchMode
    )

    let store = HarnessMonitorAppStoreFactory.makeStore(
      environment: resolvedEnvironment,
      modelContainer: persistenceSetup.container,
      persistenceError: persistenceSetup.error
    )

    if isUITesting {
      let toastDismissDelay = resolvedToastDismissDelay(environment: resolvedEnvironment)
      store.configureUITestBehavior(
        successFeedbackDismissDelay: toastDismissDelay,
        failureFeedbackDismissDelay: toastDismissDelay
      )
      applyUITestDefaults(environment: resolvedEnvironment, overrides: uiTestOverrides)
      seedTestToasts(environment: resolvedEnvironment, store: store)
    }

    return Self(
      container: persistenceSetup.container,
      store: store,
      launchMode: launchMode,
      initialThemeMode: uiTestOverrides.themeMode,
      isUITesting: isUITesting,
      mainWindowDefaultSize: HarnessMonitorUITestWindowDefaults.mainWindowSize(
        environment: resolvedEnvironment,
        isUITesting: isUITesting
      ),
      perfScenario: perfScenario,
      preferencesInitialSection: perfScenario?.initialPreferencesSection ?? .general
    )
  }

  private static func resolveUITestOverrides(
    isUITesting: Bool,
    environment: HarnessMonitorEnvironment
  ) -> UITestOverrides {
    guard isUITesting else {
      return UITestOverrides(
        themeMode: .auto,
        textSizeIndex: HarnessMonitorTextSize.defaultIndex,
        backdropMode: .none,
        backgroundImage: .defaultSelection,
        showInspector: true
      )
    }
    return UITestOverrides(
      themeMode: HarnessMonitorThemeMode(
        rawValue: environment.values["HARNESS_MONITOR_THEME_MODE_OVERRIDE"] ?? ""
      ) ?? .auto,
      textSizeIndex: HarnessMonitorTextSize.uiTestOverrideIndex(
        from: environment.values[HarnessMonitorTextSize.uiTestOverrideKey]
      ) ?? HarnessMonitorTextSize.defaultIndex,
      backdropMode: HarnessMonitorBackdropMode(
        rawValue: environment.values["HARNESS_MONITOR_BACKDROP_MODE_OVERRIDE"] ?? ""
      ) ?? .none,
      backgroundImage: HarnessMonitorBackgroundSelection.decode(
        environment.values["HARNESS_MONITOR_BACKGROUND_IMAGE_OVERRIDE"] ?? ""
      ),
      showInspector: uiTestBoolOverride(
        from: environment.values["HARNESS_MONITOR_SHOW_INSPECTOR_OVERRIDE"]
      ) ?? true
    )
  }

  private struct UITestOverrides {
    let themeMode: HarnessMonitorThemeMode
    let textSizeIndex: Int
    let backdropMode: HarnessMonitorBackdropMode
    let backgroundImage: HarnessMonitorBackgroundSelection
    let showInspector: Bool
  }

  private static func uiTestSafeEnvironment() -> HarnessMonitorEnvironment {
    let environment = HarnessMonitorEnvironment.current
    let isUITestHost = Bundle.main.bundleIdentifier == uiTestingBundleIdentifier
    let isUITesting = environment.values[uiTestsEnvironmentKey] == "1" || isUITestHost
    guard isUITesting else {
      return environment
    }

    var values = environment.values
    values[uiTestsEnvironmentKey] = "1"
    // Never let an external-daemon developer env leak into UI tests; UI tests
    // always run against managed/preview controllers, not a real terminal
    // daemon.
    values[DaemonOwnership.environmentKey] = "0"

    if isUITestHost, isBlank(values[HarnessMonitorLaunchMode.environmentKey]) {
      values[HarnessMonitorLaunchMode.environmentKey] = HarnessMonitorLaunchMode.preview.rawValue
    }

    if isBlank(values[HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey]) {
      values[HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey] = defaultUITestDataHomePath(
        bundleIdentifier: Bundle.main.bundleIdentifier
      )
    }

    return HarnessMonitorEnvironment(values: values, homeDirectory: environment.homeDirectory)
  }

  private static func defaultUITestDataHomePath(bundleIdentifier: String?) -> String {
    let bundleComponent = storagePathComponent(bundleIdentifier ?? uiTestingBundleIdentifier)
    return FileManager.default.temporaryDirectory
      .appendingPathComponent(uiTestDefaultDataRootName, isDirectory: true)
      .appendingPathComponent(
        "\(bundleComponent)-\(ProcessInfo.processInfo.processIdentifier)",
        isDirectory: true
      )
      .path
  }

  private static func storagePathComponent(_ value: String) -> String {
    let allowedScalars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    let component = value.unicodeScalars
      .map { allowedScalars.contains($0) ? String($0) : "-" }
      .joined()
      .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
    return component.isEmpty ? "ui-test-host" : component
  }

  private static func isBlank(_ rawValue: String?) -> Bool {
    rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
  }

  @MainActor
  private static func applyUITestDefaults(
    environment: HarnessMonitorEnvironment,
    overrides: UITestOverrides
  ) {
    let uiTestTimeZoneMode =
      HarnessMonitorDateTimeZoneMode(
        rawValue: environment.values[
          HarnessMonitorDateTimeConfiguration.uiTestTimeZoneModeOverrideKey
        ]
          ?? ""
      ) ?? .local
    let uiTestCustomTimeZone =
      environment.values[
        HarnessMonitorDateTimeConfiguration.uiTestCustomTimeZoneOverrideKey
      ]
      ?? HarnessMonitorDateTimeConfiguration.defaultCustomTimeZoneIdentifier

    UserDefaults.standard.set(
      overrides.themeMode.rawValue,
      forKey: HarnessMonitorThemeDefaults.modeKey
    )
    UserDefaults.standard.set(
      overrides.textSizeIndex,
      forKey: HarnessMonitorTextSize.storageKey
    )
    UserDefaults.standard.set(
      overrides.backdropMode.rawValue,
      forKey: HarnessMonitorBackdropDefaults.modeKey
    )
    UserDefaults.standard.set(
      overrides.backgroundImage.storageValue,
      forKey: HarnessMonitorBackgroundDefaults.imageKey
    )
    UserDefaults.standard.set(
      overrides.showInspector,
      forKey: "showInspector"
    )
    UserDefaults.standard.set(
      uiTestTimeZoneMode.rawValue,
      forKey: HarnessMonitorDateTimeConfiguration.timeZoneModeKey
    )
    UserDefaults.standard.set(
      uiTestCustomTimeZone,
      forKey: HarnessMonitorDateTimeConfiguration.customTimeZoneIdentifierKey
    )
    applyVoiceUITestDefaults(environment: environment)
  }

  private static func resolvedToastDismissDelay(
    environment: HarnessMonitorEnvironment
  ) -> Duration {
    guard
      let rawValue = environment.values[toastDismissOverrideKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !rawValue.isEmpty,
      let milliseconds = Int(rawValue),
      milliseconds > 0
    else {
      return .seconds(1)
    }
    return .milliseconds(milliseconds)
  }

  @MainActor
  private static func seedTestToasts(
    environment: HarnessMonitorEnvironment,
    store: HarnessMonitorStore
  ) {
    guard
      let rawValue = environment.values[toastSeedKey]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !rawValue.isEmpty
    else {
      return
    }
    for component in rawValue.split(separator: ",") {
      let message = component.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !message.isEmpty else { continue }
      store.presentSuccessFeedback(message)
    }
  }

  private static func uiTestBoolOverride(from rawValue: String?) -> Bool? {
    guard let rawValue else {
      return nil
    }

    switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on":
      return true
    case "0", "false", "no", "off":
      return false
    default:
      return nil
    }
  }

  private static func applyVoiceUITestDefaults(environment: HarnessMonitorEnvironment) {
    let localeIdentifier = voiceStringOverride(
      environment.values[HarnessMonitorVoicePreferencesDefaults.uiTestLocaleIdentifierOverrideKey],
      fallback: HarnessMonitorVoicePreferences.uiTestDefaultLocaleIdentifier
    )
    let transcriptInsertionMode =
      HarnessMonitorVoiceTranscriptInsertionMode(
        rawValue: environment.values[
          HarnessMonitorVoicePreferencesDefaults.uiTestTranscriptInsertionModeOverrideKey
        ] ?? ""
      ) ?? .manualConfirm
    let localDaemonSinkEnabled =
      uiTestBoolOverride(
        from: environment.values[
          HarnessMonitorVoicePreferencesDefaults.uiTestLocalDaemonSinkEnabledOverrideKey
        ]
      ) ?? true
    let agentBridgeSinkEnabled =
      uiTestBoolOverride(
        from: environment.values[
          HarnessMonitorVoicePreferencesDefaults.uiTestAgentBridgeSinkEnabledOverrideKey
        ]
      ) ?? true
    let remoteProcessorSinkEnabled =
      uiTestBoolOverride(
        from: environment.values[
          HarnessMonitorVoicePreferencesDefaults.uiTestRemoteProcessorEnabledOverrideKey
        ]
      ) ?? false
    let remoteProcessorURL = voiceStringOverride(
      environment.values[
        HarnessMonitorVoicePreferencesDefaults.uiTestRemoteProcessorURLOverrideKey
      ],
      fallback: ""
    )
    let deliversAudioChunks =
      uiTestBoolOverride(
        from: environment.values[
          HarnessMonitorVoicePreferencesDefaults.uiTestDeliversAudioChunksOverrideKey
        ]
      ) ?? true
    let pendingAudioChunkLimit = HarnessMonitorVoicePreferences.normalizedPendingAudioChunkLimit(
      uiTestIntOverride(
        from: environment.values[
          HarnessMonitorVoicePreferencesDefaults.uiTestPendingAudioChunkLimitOverrideKey
        ]
      ) ?? HarnessMonitorVoicePreferences.defaultPendingAudioChunkLimit
    )
    let pendingTranscriptSegmentLimit =
      HarnessMonitorVoicePreferences.normalizedPendingTranscriptSegmentLimit(
        uiTestIntOverride(
          from: environment.values[
            HarnessMonitorVoicePreferencesDefaults.uiTestPendingTranscriptLimitOverrideKey
          ]
        ) ?? HarnessMonitorVoicePreferences.defaultPendingTranscriptSegmentLimit
      )

    applyVoiceDefaultPairs([
      (localeIdentifier, HarnessMonitorVoicePreferencesDefaults.localeIdentifierKey),
      (localDaemonSinkEnabled, HarnessMonitorVoicePreferencesDefaults.localDaemonSinkEnabledKey),
      (agentBridgeSinkEnabled, HarnessMonitorVoicePreferencesDefaults.agentBridgeSinkEnabledKey),
      (
        remoteProcessorSinkEnabled,
        HarnessMonitorVoicePreferencesDefaults.remoteProcessorSinkEnabledKey
      ),
      (remoteProcessorURL, HarnessMonitorVoicePreferencesDefaults.remoteProcessorURLKey),
      (
        transcriptInsertionMode.rawValue,
        HarnessMonitorVoicePreferencesDefaults.transcriptInsertionModeKey
      ),
      (deliversAudioChunks, HarnessMonitorVoicePreferencesDefaults.deliversAudioChunksKey),
      (pendingAudioChunkLimit, HarnessMonitorVoicePreferencesDefaults.pendingAudioChunkLimitKey),
      (
        pendingTranscriptSegmentLimit,
        HarnessMonitorVoicePreferencesDefaults.pendingTranscriptSegmentLimitKey
      ),
    ])
  }

  private static func applyVoiceDefaultPairs(_ pairs: [(Any, String)]) {
    for (value, key) in pairs {
      UserDefaults.standard.set(value, forKey: key)
    }
  }

  private static func uiTestIntOverride(from rawValue: String?) -> Int? {
    guard let rawValue else {
      return nil
    }
    return Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  private static func voiceStringOverride(_ rawValue: String?, fallback: String) -> String {
    guard let rawValue else {
      return fallback
    }

    let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedValue.isEmpty ? fallback : trimmedValue
  }
}

enum HarnessMonitorPerfScenario: String, CaseIterable, Sendable {
  static let environmentKey = "HARNESS_MONITOR_PERF_SCENARIO"

  case launchDashboard = "launch-dashboard"
  case selectSessionCockpit = "select-session-cockpit"
  case refreshAndSearch = "refresh-and-search"
  case sidebarOverflowSearch = "sidebar-overflow-search"
  case settingsBackdropCycle = "settings-backdrop-cycle"
  case settingsBackgroundCycle = "settings-background-cycle"
  case timelineBurst = "timeline-burst"
  case toastOverlayChurn = "toast-overlay-churn"
  case offlineCachedOpen = "offline-cached-open"

  init?(environment: HarnessMonitorEnvironment) {
    let rawValue = environment.values[Self.environmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard let rawValue, !rawValue.isEmpty else {
      return nil
    }
    self.init(rawValue: rawValue)
  }

  var defaultPreviewScenario: String {
    switch self {
    case .launchDashboard, .selectSessionCockpit:
      return "dashboard-landing"
    case .settingsBackdropCycle, .settingsBackgroundCycle:
      return "dashboard"
    case .refreshAndSearch, .sidebarOverflowSearch:
      return "overflow"
    case .timelineBurst, .toastOverlayChurn:
      return "cockpit"
    case .offlineCachedOpen:
      return "offline-cached"
    }
  }

  var initialPreferencesSection: PreferencesSection {
    switch self {
    case .settingsBackdropCycle, .settingsBackgroundCycle:
      return .appearance
    case .launchDashboard,
      .selectSessionCockpit,
      .refreshAndSearch,
      .sidebarOverflowSearch,
      .timelineBurst,
      .toastOverlayChurn,
      .offlineCachedOpen:
      return .general
    }
  }

  func applyingDefaults(to environment: HarnessMonitorEnvironment) -> HarnessMonitorEnvironment {
    var values = environment.values
    if values[HarnessMonitorLaunchMode.environmentKey]?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    .isEmpty ?? true {
      values[HarnessMonitorLaunchMode.environmentKey] = HarnessMonitorLaunchMode.preview.rawValue
    }
    let previewScenarioIsEmpty =
      values["HARNESS_MONITOR_PREVIEW_SCENARIO"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty ?? true
    if previewScenarioIsEmpty {
      values["HARNESS_MONITOR_PREVIEW_SCENARIO"] = defaultPreviewScenario
    }
    return HarnessMonitorEnvironment(values: values, homeDirectory: environment.homeDirectory)
  }
}

private enum HarnessMonitorUITestWindowDefaults {
  private static let mainWindowWidthKey = "HARNESS_MONITOR_UI_MAIN_WINDOW_WIDTH"
  private static let mainWindowHeightKey = "HARNESS_MONITOR_UI_MAIN_WINDOW_HEIGHT"
  private static let standardMainWindowSize = CGSize(width: 1640, height: 980)

  static func mainWindowSize(environment: HarnessMonitorEnvironment, isUITesting: Bool) -> CGSize {
    guard isUITesting else {
      return standardMainWindowSize
    }

    let width = clampedDimension(
      rawValue: environment.values[mainWindowWidthKey],
      fallback: standardMainWindowSize.width
    )
    let height = clampedDimension(
      rawValue: environment.values[mainWindowHeightKey],
      fallback: standardMainWindowSize.height
    )

    return CGSize(width: width, height: height)
  }

  private static func clampedDimension(rawValue: String?, fallback: CGFloat) -> CGFloat {
    guard
      let rawValue,
      let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
      value.isFinite
    else {
      return fallback
    }

    return CGFloat(max(value, 640))
  }
}

private struct HarnessMonitorPersistenceSetup {
  let container: ModelContainer?
  let error: String?

  static func resolve(
    environment: HarnessMonitorEnvironment,
    launchMode: HarnessMonitorLaunchMode
  ) -> Self {
    if environment.values["HARNESS_MONITOR_FORCE_PERSISTENCE_FAILURE"] == "1" {
      return Self(
        container: nil,
        error: persistenceUnavailableMessage(details: "Forced failure for testing.")
      )
    }

    do {
      let container =
        switch launchMode {
        case .live:
          try HarnessMonitorModelContainer.live(using: environment)
        case .preview, .empty:
          try HarnessMonitorModelContainer.preview()
        }

      return Self(container: container, error: nil)
    } catch {
      return Self(
        container: nil,
        error: persistenceUnavailableMessage(details: error.localizedDescription)
      )
    }
  }

  private static func persistenceUnavailableMessage(details: String) -> String {
    """
    Local persistence is unavailable. Harness Monitor will keep running, but bookmarks,
    notes, and search history are disabled. \(details)
    """
  }
}
