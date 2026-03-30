import AppKit
import Foundation
import HarnessKit
import Observation
import SwiftData
import SwiftUI

private final class HarnessAppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    true
  }
}

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
  @NSApplicationDelegateAdaptor private var delegate: HarnessAppDelegate
  private let container: ModelContainer
  @State private var store: HarnessStore
  @AppStorage(HarnessThemeDefaults.modeKey)
  private var storedThemeMode = HarnessThemeMode.auto.rawValue
  @AppStorage(HarnessThemeDefaults.styleKey)
  private var storedThemeStyle = HarnessThemeStyle.gradient.rawValue
  @State private var themeMode: HarnessThemeMode = .auto
  @State private var themeStyle: HarnessThemeStyle = .gradient
  private let isUITesting = ProcessInfo.processInfo.environment["HARNESS_UI_TESTS"] == "1"

  init() {
    let resolvedContainer =
      (try? HarnessModelContainer.live())
      ?? (try? HarnessModelContainer.preview())!
    container = resolvedContainer
    let resolvedStore = HarnessAppStoreFactory.makeStore(
      modelContext: resolvedContainer.mainContext
    )
    _store = State(initialValue: resolvedStore)

    if ProcessInfo.processInfo.environment["HARNESS_UI_TESTS"] == "1" {
      UserDefaults.standard.set(
        HarnessThemeMode.auto.rawValue, forKey: HarnessThemeDefaults.modeKey)
      UserDefaults.standard.set(
        HarnessThemeStyle.gradient.rawValue,
        forKey: HarnessThemeDefaults.styleKey
      )
    }
  }

  var body: some Scene {
    WindowGroup("Harness") {
      rootContent
        .modelContainer(container)
    }
    .windowToolbarStyle(.unified)
    .defaultSize(width: 1640, height: 980)
    .restorationBehavior(isUITesting ? .disabled : .automatic)
    .commands {
      appCommands
    }

    Settings {
      settingsContent
    }
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    .defaultSize(width: 1180, height: 760)
    .restorationBehavior(isUITesting ? .disabled : .automatic)
  }

  private func syncThemeFromStorage() {
    themeMode = HarnessThemeMode(rawValue: storedThemeMode) ?? .auto
    themeStyle = HarnessThemeStyle(rawValue: storedThemeStyle) ?? .gradient
  }

  @ViewBuilder private var rootContent: some View {
    ContentView(store: store, themeStyle: themeStyle)
      .environment(\.harnessThemeStyle, themeStyle)
      .preferredColorScheme(themeMode.colorScheme)
      .tint(HarnessTheme.accent(for: themeStyle))
      .onAppear { syncThemeFromStorage() }
      .onChange(of: storedThemeMode) { _, _ in syncThemeFromStorage() }
      .onChange(of: storedThemeStyle) { _, _ in syncThemeFromStorage() }
      .onChange(of: themeMode) { _, new in storedThemeMode = new.rawValue }
      .onChange(of: themeStyle) { _, new in storedThemeStyle = new.rawValue }
      .task {
        await store.bootstrapIfNeeded()
      }
  }

  @CommandsBuilder private var appCommands: some Commands {
    SidebarCommands()
    CommandMenu("Harness") {
      Button("Refresh", action: refreshStore)
        .keyboardShortcut("r", modifiers: [.command, .shift])

      Divider()

      Button("Start Daemon", action: startDaemon)

      Button("Install Launch Agent", action: installLaunchAgent)

      Divider()

      Button("Observe Selected Session", action: observeSelectedSession)
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(store.selectedSessionID == nil)

      Button("End Selected Session", action: endSelectedSession)
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(store.selectedSessionID == nil)

      Divider()

      Button("Inspect Session Overview") {
        store.inspectorSelection = .none
      }
      .keyboardShortcut("1", modifiers: [.command, .option])
      .disabled(store.selectedSessionID == nil)

      Button("Inspect Observer") {
        store.inspectObserver()
      }
      .keyboardShortcut("2", modifiers: [.command, .option])
      .disabled(store.selectedSession?.observer == nil)
    }
  }

  @ViewBuilder private var settingsContent: some View {
    PreferencesView(
      store: store,
      themeMode: $themeMode,
      themeStyle: $themeStyle
    )
    .environment(\.harnessThemeStyle, themeStyle)
    .preferredColorScheme(themeMode.colorScheme)
    .tint(HarnessTheme.accent(for: themeStyle))
  }

  private func refreshStore() {
    Task {
      await store.refresh()
    }
  }

  private func startDaemon() {
    Task {
      await store.startDaemon()
    }
  }

  private func installLaunchAgent() {
    Task {
      await store.installLaunchAgent()
    }
  }

  private func observeSelectedSession() {
    Task {
      await store.observeSelectedSession()
    }
  }

  private func endSelectedSession() {
    Task {
      await store.endSelectedSession()
    }
  }
}
