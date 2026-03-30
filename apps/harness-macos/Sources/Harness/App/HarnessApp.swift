import Foundation
import HarnessKit
import Observation
import SwiftUI

enum HarnessThemeDefaults {
  static let modeKey = "harnessThemeMode"
  static let styleKey = "harnessThemeStyle"
}

enum HarnessThemeMode: String, CaseIterable, Identifiable {
  case auto
  case light
  case dark

  var id: String { rawValue }

  var colorScheme: ColorScheme? {
    switch self {
    case .auto: nil
    case .light: .light
    case .dark: .dark
    }
  }

  var label: String {
    switch self {
    case .auto: "Auto"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}

enum HarnessThemeStyle: String, CaseIterable, Identifiable {
  case gradient
  case flat

  var id: String { rawValue }

  var label: String {
    switch self {
    case .gradient: "Gradient"
    case .flat: "Flat"
    }
  }
}

@main
@MainActor
struct HarnessApp: App {
  @State private var store = HarnessAppStoreFactory.makeStore()
  @AppStorage(HarnessThemeDefaults.modeKey)
  private var storedThemeMode = HarnessThemeMode.auto.rawValue
  @AppStorage(HarnessThemeDefaults.styleKey)
  private var storedThemeStyle = HarnessThemeStyle.gradient.rawValue
  private let isUITesting = ProcessInfo.processInfo.environment["HARNESS_UI_TESTS"] == "1"

  init() {
    if ProcessInfo.processInfo.environment["HARNESS_UI_TESTS"] == "1" {
      UserDefaults.standard.set(HarnessThemeMode.auto.rawValue, forKey: HarnessThemeDefaults.modeKey)
      UserDefaults.standard.set(
        HarnessThemeStyle.gradient.rawValue,
        forKey: HarnessThemeDefaults.styleKey
      )
    }
  }

  private var themeMode: HarnessThemeMode {
    HarnessThemeMode(rawValue: storedThemeMode) ?? .auto
  }

  private var themeStyle: HarnessThemeStyle {
    HarnessThemeStyle(rawValue: storedThemeStyle) ?? .gradient
  }

  private var themeModeBinding: Binding<HarnessThemeMode> {
    Binding(
      get: { themeMode },
      set: { storedThemeMode = $0.rawValue }
    )
  }

  private var themeStyleBinding: Binding<HarnessThemeStyle> {
    Binding(
      get: { themeStyle },
      set: { storedThemeStyle = $0.rawValue }
    )
  }

  var body: some Scene {
    Window("Harness", id: "main") {
      rootContent
    }
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified(showsTitle: true))
    .defaultLaunchBehavior(.presented)
    .defaultSize(width: 1640, height: 980)
    .restorationBehavior(isUITesting ? .disabled : .automatic)
    .commands {
      appCommands
    }

    Settings {
      settingsContent
    }
    .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    .defaultSize(width: 980, height: 680)
    .restorationBehavior(isUITesting ? .disabled : .automatic)
  }

  @ViewBuilder private var rootContent: some View {
    ContentView(store: store, themeStyle: themeStyle)
      .preferredColorScheme(themeMode.colorScheme)
      .tint(HarnessTheme.accent(for: themeStyle))
      .id("root-\(themeMode.rawValue)-\(themeStyle.rawValue)")
      .task {
        await store.bootstrapIfNeeded()
      }
  }

  @CommandsBuilder private var appCommands: some Commands {
    SidebarCommands()
    CommandMenu("Harness") {
      Button("Refresh") {
        Task {
          await store.refresh()
        }
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])

      Divider()

      Button("Start Daemon") {
        Task {
          await store.startDaemon()
        }
      }

      Button("Install Launch Agent") {
        Task {
          await store.installLaunchAgent()
        }
      }

      Divider()

      Button("Observe Selected Session") {
        Task {
          await store.observeSelectedSession()
        }
      }
      .keyboardShortcut("o", modifiers: [.command, .shift])
      .disabled(store.selectedSessionID == nil)

      Button("End Selected Session") {
        Task {
          await store.endSelectedSession()
        }
      }
      .keyboardShortcut("e", modifiers: [.command, .shift])
      .disabled(store.selectedSessionID == nil)
    }
  }

  @ViewBuilder private var settingsContent: some View {
    PreferencesView(
      store: store,
      themeMode: themeModeBinding,
      themeStyle: themeStyleBinding
    )
    .preferredColorScheme(themeMode.colorScheme)
    .tint(HarnessTheme.accent(for: themeStyle))
    .id("settings-\(themeMode.rawValue)-\(themeStyle.rawValue)")
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
