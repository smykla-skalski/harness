import Foundation
import HarnessKit
import SwiftData

struct HarnessAppConfiguration {
  let container: ModelContainer?
  let store: HarnessStore
  let initialThemeMode: HarnessThemeMode
  let isUITesting: Bool

  @MainActor
  static func resolve() -> Self {
    UserDefaults.standard.register(defaults: [
      HarnessTextSize.storageKey: HarnessTextSize.defaultIndex,
    ])

    let environment = HarnessEnvironment.current
    let isUITesting = environment.values["HARNESS_UI_TESTS"] == "1"
    let launchMode = HarnessLaunchMode(environment: environment)
    let initialThemeMode =
      isUITesting
      ? (HarnessThemeMode(rawValue: environment.values["HARNESS_THEME_MODE_OVERRIDE"] ?? "")
        ?? .auto)
      : .auto
    let initialTextSizeIndex =
      isUITesting
      ? (HarnessTextSize.uiTestOverrideIndex(
        from: environment.values[HarnessTextSize.uiTestOverrideKey]
      ) ?? HarnessTextSize.defaultIndex)
      : HarnessTextSize.defaultIndex
    let persistenceSetup = HarnessPersistenceSetup.resolve(
      environment: environment,
      launchMode: launchMode
    )

    let store = HarnessAppStoreFactory.makeStore(
      environment: environment,
      modelContext: persistenceSetup.container?.mainContext,
      persistenceError: persistenceSetup.error
    )

    if isUITesting {
      UserDefaults.standard.set(
        initialThemeMode.rawValue,
        forKey: HarnessThemeDefaults.modeKey
      )
      UserDefaults.standard.set(
        initialTextSizeIndex,
        forKey: HarnessTextSize.storageKey
      )
    }

    return Self(
      container: persistenceSetup.container,
      store: store,
      initialThemeMode: initialThemeMode,
      isUITesting: isUITesting
    )
  }
}

private struct HarnessPersistenceSetup {
  let container: ModelContainer?
  let error: String?

  static func resolve(
    environment: HarnessEnvironment,
    launchMode: HarnessLaunchMode
  ) -> Self {
    if environment.values["HARNESS_FORCE_PERSISTENCE_FAILURE"] == "1" {
      return Self(
        container: nil,
        error: persistenceUnavailableMessage(details: "Forced failure for testing.")
      )
    }

    do {
      let container =
        switch launchMode {
        case .live:
          try HarnessModelContainer.live(using: environment)
        case .preview, .empty:
          try HarnessModelContainer.preview()
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
    Local persistence is unavailable. Harness will keep running, but bookmarks,
    notes, and search history are disabled. \(details)
    """
  }
}
