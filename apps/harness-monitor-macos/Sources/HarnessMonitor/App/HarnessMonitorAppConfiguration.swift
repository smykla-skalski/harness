import Foundation
import HarnessMonitorKit
import HarnessMonitorUI
import SwiftData

struct HarnessMonitorAppConfiguration {
  let container: ModelContainer?
  let store: HarnessMonitorStore
  let initialThemeMode: HarnessMonitorThemeMode
  let isUITesting: Bool
  let mainWindowDefaultSize: CGSize

  @MainActor
  static func resolve() -> Self {
    UserDefaults.standard.register(defaults: [
      HarnessMonitorBackdropDefaults.modeKey: HarnessMonitorBackdropMode.none.rawValue,
      HarnessMonitorBackgroundDefaults.imageKey: HarnessMonitorBackgroundSelection.defaultSelection.storageValue,
      HarnessMonitorTextSize.storageKey: HarnessMonitorTextSize.defaultIndex,
      HarnessMonitorDateTimeConfiguration.timeZoneModeKey:
        HarnessMonitorDateTimeConfiguration.defaultTimeZoneModeRawValue,
      HarnessMonitorDateTimeConfiguration.customTimeZoneIdentifierKey:
        HarnessMonitorDateTimeConfiguration.defaultCustomTimeZoneIdentifier,
      "harnessMonitor.board.onboardingDismissed": false,
      "showInspector": true,
    ])

    let environment = HarnessMonitorEnvironment.current
    let isUITesting = environment.values["HARNESS_MONITOR_UI_TESTS"] == "1"
    let launchMode = HarnessMonitorLaunchMode(environment: environment)
    let initialThemeMode =
      isUITesting
      ? (HarnessMonitorThemeMode(rawValue: environment.values["HARNESS_MONITOR_THEME_MODE_OVERRIDE"] ?? "")
        ?? .auto)
      : .auto
    let initialTextSizeIndex =
      isUITesting
      ? (HarnessMonitorTextSize.uiTestOverrideIndex(
        from: environment.values[HarnessMonitorTextSize.uiTestOverrideKey]
      ) ?? HarnessMonitorTextSize.defaultIndex)
      : HarnessMonitorTextSize.defaultIndex
    let initialBackdropMode =
      isUITesting
      ? (HarnessMonitorBackdropMode(
        rawValue: environment.values["HARNESS_MONITOR_BACKDROP_MODE_OVERRIDE"] ?? ""
      ) ?? .none)
      : .none
    let initialBackgroundImage =
      isUITesting
      ? HarnessMonitorBackgroundSelection.decode(
        environment.values["HARNESS_MONITOR_BACKGROUND_IMAGE_OVERRIDE"] ?? ""
      )
      : .defaultSelection
    let initialShowInspector =
      isUITesting
      ? uiTestBoolOverride(from: environment.values["HARNESS_MONITOR_SHOW_INSPECTOR_OVERRIDE"]) ?? true
      : true
    let persistenceSetup = HarnessMonitorPersistenceSetup.resolve(
      environment: environment,
      launchMode: launchMode
    )

    let store = HarnessMonitorAppStoreFactory.makeStore(
      environment: environment,
      modelContainer: persistenceSetup.container,
      persistenceError: persistenceSetup.error
    )

    if isUITesting {
      let uiTestTimeZoneMode =
        HarnessMonitorDateTimeZoneMode(
          rawValue: environment.values[HarnessMonitorDateTimeConfiguration.uiTestTimeZoneModeOverrideKey]
            ?? ""
        ) ?? .local
      let uiTestCustomTimeZone =
        environment.values[HarnessMonitorDateTimeConfiguration.uiTestCustomTimeZoneOverrideKey]
        ?? HarnessMonitorDateTimeConfiguration.defaultCustomTimeZoneIdentifier

      UserDefaults.standard.set(
        initialThemeMode.rawValue,
        forKey: HarnessMonitorThemeDefaults.modeKey
      )
      UserDefaults.standard.set(
        initialTextSizeIndex,
        forKey: HarnessMonitorTextSize.storageKey
      )
      UserDefaults.standard.set(
        initialBackdropMode.rawValue,
        forKey: HarnessMonitorBackdropDefaults.modeKey
      )
      UserDefaults.standard.set(
        initialBackgroundImage.storageValue,
        forKey: HarnessMonitorBackgroundDefaults.imageKey
      )
      UserDefaults.standard.set(
        initialShowInspector,
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
    }

    return Self(
      container: persistenceSetup.container,
      store: store,
      initialThemeMode: initialThemeMode,
      isUITesting: isUITesting,
      mainWindowDefaultSize: HarnessMonitorUITestWindowDefaults.mainWindowSize(
        environment: environment,
        isUITesting: isUITesting
      )
    )
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
