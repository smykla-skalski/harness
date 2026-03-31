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

@main
@MainActor
struct HarnessApp: App {
  @NSApplicationDelegateAdaptor private var delegate: HarnessAppDelegate
  private let container: ModelContainer
  @State private var store: HarnessStore
  @AppStorage(HarnessThemeDefaults.modeKey)
  private var storedThemeMode = HarnessThemeMode.auto.rawValue
  @State private var themeMode: HarnessThemeMode = .auto
  private let isUITesting = ProcessInfo.processInfo.environment["HARNESS_UI_TESTS"] == "1"

  init() {
    let uiTesting = ProcessInfo.processInfo.environment["HARNESS_UI_TESTS"] == "1"
    let initialThemeMode =
      uiTesting
      ? (HarnessThemeMode(
        rawValue: ProcessInfo.processInfo.environment["HARNESS_THEME_MODE_OVERRIDE"] ?? ""
      ) ?? .auto)
      : .auto
    let resolvedContainer =
      (uiTesting
        ? (try? HarnessModelContainer.preview())
        : (try? HarnessModelContainer.live()))
      ?? {
        guard let fallback = try? HarnessModelContainer.preview() else {
          fatalError("Unable to create model container for live or preview store")
        }
        return fallback
      }()
    container = resolvedContainer
    let resolvedStore = HarnessAppStoreFactory.makeStore(
      modelContext: resolvedContainer.mainContext
    )
    _store = State(initialValue: resolvedStore)
    _themeMode = State(initialValue: initialThemeMode)

    if uiTesting {
      UserDefaults.standard.set(
        initialThemeMode.rawValue, forKey: HarnessThemeDefaults.modeKey)
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
    .defaultSize(width: 640, height: 480)
    .windowResizability(.contentSize)
    .restorationBehavior(isUITesting ? .disabled : .automatic)
  }

  private func syncThemeFromStorage() {
    themeMode = HarnessThemeMode(rawValue: storedThemeMode) ?? .auto
  }

  @ViewBuilder private var rootContent: some View {
    ContentView(store: store)
      .frame(minWidth: 900, minHeight: 600)
      .preferredColorScheme(themeMode.colorScheme)
      .tint(HarnessTheme.accent)
      .onAppear { syncThemeFromStorage() }
      .onChange(of: storedThemeMode) { _, _ in syncThemeFromStorage() }
      .onChange(of: themeMode) { _, new in storedThemeMode = new.rawValue }
      .task {
        await store.bootstrapIfNeeded()
      }
  }

  @FocusedValue(\.inspectorVisibility)
  private var inspectorVisibility: Binding<Bool>?

  @CommandsBuilder private var appCommands: some Commands {
    SidebarCommands()
    TextEditingCommands()
    CommandGroup(replacing: .help) {
      Link("Harness Documentation", destination: URL(string: "https://github.com/smykla-skalski/harness")!)
    }
    CommandMenu("Harness") {
      Button("Refresh", action: refreshStore)
        .keyboardShortcut("r", modifiers: [.command, .shift])

      Divider()

      Button("Start Daemon", action: startDaemon)

      Button("Install Launch Agent", action: installLaunchAgent)

      Divider()

      Button("Back") {
        Task { await store.navigateBack() }
      }
      .keyboardShortcut("[", modifiers: [.command])
      .disabled(!store.canNavigateBack)

      Button("Forward") {
        Task { await store.navigateForward() }
      }
      .keyboardShortcut("]", modifiers: [.command])
      .disabled(!store.canNavigateForward)

      Divider()

      Button("Observe Selected Session", action: observeSelectedSession)
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(store.selectedSessionID == nil)

      Button("End Selected Session", action: endSelectedSession)
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(store.selectedSessionID == nil)

      Divider()

      Button(store.selectedSessionBookmarkTitle) {
        store.toggleSelectedSessionBookmark()
      }
      .keyboardShortcut("b", modifiers: [.command, .shift])
      .disabled(store.selectedSessionID == nil)

      Button("Copy Selection ID") {
        store.copySelectedItemID()
      }
      .keyboardShortcut("c", modifiers: [.command, .shift])
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

      Divider()

      Button {
        inspectorVisibility?.wrappedValue.toggle()
      } label: {
        Text(inspectorVisibility?.wrappedValue == true ? "Hide Inspector" : "Show Inspector")
      }
      .keyboardShortcut("i", modifiers: [.command, .option])
      .disabled(inspectorVisibility == nil)
    }
  }

  @ViewBuilder private var settingsContent: some View {
    PreferencesView(
      store: store,
      themeMode: $themeMode
    )
    .frame(minWidth: 600, minHeight: 400)
    .preferredColorScheme(themeMode.colorScheme)
    .tint(HarnessTheme.accent)
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
