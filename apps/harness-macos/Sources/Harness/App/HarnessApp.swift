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
  private struct PersistenceSetup {
    let container: ModelContainer?
    let error: String?
  }

  @NSApplicationDelegateAdaptor private var delegate: HarnessAppDelegate
  private let container: ModelContainer?
  @State private var store: HarnessStore
  @AppStorage(HarnessThemeDefaults.modeKey)
  private var storedThemeMode = HarnessThemeMode.auto.rawValue
  @AppStorage(HarnessTextSize.storageKey)
  private var textSizeIndex = HarnessTextSize.defaultIndex
  @State private var themeMode: HarnessThemeMode = .auto
  private let isUITesting = ProcessInfo.processInfo.environment["HARNESS_UI_TESTS"] == "1"

  init() {
    let environment = HarnessEnvironment.current
    let uiTesting = environment.values["HARNESS_UI_TESTS"] == "1"
    let launchMode = HarnessLaunchMode(environment: environment)
    let initialThemeMode =
      uiTesting
      ? (HarnessThemeMode(rawValue: environment.values["HARNESS_THEME_MODE_OVERRIDE"] ?? "")
        ?? .auto)
      : .auto
    let persistenceSetup = Self.resolvePersistenceSetup(
      environment: environment,
      launchMode: launchMode
    )
    container = persistenceSetup.container
    let resolvedStore = HarnessAppStoreFactory.makeStore(
      environment: environment,
      modelContext: persistenceSetup.container?.mainContext,
      persistenceError: persistenceSetup.error
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
      if let container {
        rootContent
          .modelContainer(container)
      } else {
        rootContent
      }
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
      .environment(\.fontScale, HarnessTextSize.scale(at: textSizeIndex))
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
    CommandGroup(after: .toolbar) {
      Button("Increase Text Size") {
        if HarnessTextSize.canIncrease(textSizeIndex) {
          textSizeIndex += 1
        }
      }
      .keyboardShortcut("+", modifiers: .command)
      .disabled(!HarnessTextSize.canIncrease(textSizeIndex))

      Button("Decrease Text Size") {
        if HarnessTextSize.canDecrease(textSizeIndex) {
          textSizeIndex -= 1
        }
      }
      .keyboardShortcut("-", modifiers: .command)
      .disabled(!HarnessTextSize.canDecrease(textSizeIndex))

      Button("Reset Text Size") {
        textSizeIndex = HarnessTextSize.defaultIndex
      }
      .keyboardShortcut("0", modifiers: .command)
      .disabled(textSizeIndex == HarnessTextSize.defaultIndex)
    }
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
      .disabled(store.selectedSessionID == nil || !store.isPersistenceAvailable)

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
    .environment(\.fontScale, HarnessTextSize.scale(at: textSizeIndex))
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

  private static func resolvePersistenceSetup(
    environment: HarnessEnvironment,
    launchMode: HarnessLaunchMode
  ) -> PersistenceSetup {
    if environment.values["HARNESS_FORCE_PERSISTENCE_FAILURE"] == "1" {
      return PersistenceSetup(
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

      return PersistenceSetup(container: container, error: nil)
    } catch {
      return PersistenceSetup(
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
