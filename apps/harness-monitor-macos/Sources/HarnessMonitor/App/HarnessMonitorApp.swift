import HarnessMonitorKit
import HarnessMonitorUI
import SwiftData
import SwiftUI

@main
@MainActor
struct HarnessMonitorApp: App {
  @NSApplicationDelegateAdaptor private var delegate: HarnessMonitorAppDelegate
  private let container: ModelContainer?
  private let isUITesting: Bool
  private let mainWindowDefaultSize: CGSize
  @State private var store: HarnessMonitorStore
  @State private var themeMode: HarnessMonitorThemeMode
  @AppStorage(HarnessMonitorTextSize.storageKey)
  private var textSizeIndex = HarnessMonitorTextSize.defaultIndex
  @FocusedValue(\.inspectorVisibility)
  private var inspectorVisibility: Binding<Bool>?

  init() {
    let configuration = HarnessMonitorAppConfiguration.resolve()
    container = configuration.container
    isUITesting = configuration.isUITesting
    mainWindowDefaultSize = configuration.mainWindowDefaultSize
    _store = State(initialValue: configuration.store)
    _themeMode = State(initialValue: configuration.initialThemeMode)
  }

  var body: some Scene {
    WindowGroup("Harness Monitor") {
      mainWindowContent
    }
    .windowToolbarStyle(.unified)
    .defaultSize(width: mainWindowDefaultSize.width, height: mainWindowDefaultSize.height)
    .restorationBehavior(isUITesting ? .disabled : .automatic)
    .commands {
      HarnessMonitorAppCommands(
        store: store,
        textSizeIndex: textSizeIndex,
        inspectorVisibility: inspectorVisibility,
        increaseTextSize: increaseTextSize,
        decreaseTextSize: decreaseTextSize,
        resetTextSize: resetTextSize,
        refreshStore: refreshStore,
        startDaemon: startDaemon,
        installLaunchAgent: installLaunchAgent,
        observeSelectedSession: observeSelectedSession,
        endSelectedSession: endSelectedSession,
        inspectSessionOverview: inspectSessionOverview,
        inspectObserver: inspectObserver
      )
    }

    Window("Preferences", id: HarnessMonitorWindowID.preferences) {
      HarnessMonitorSettingsRootView(
        store: store,
        themeMode: $themeMode
      )
    }
    .windowStyle(.titleBar)
    .defaultSize(width: 860, height: 620)
    .restorationBehavior(isUITesting ? .disabled : .automatic)
  }

  @ViewBuilder private var mainWindowContent: some View {
    if let container {
      HarnessMonitorWindowRootView(
        store: store,
        themeMode: $themeMode
      )
      .modelContainer(container)
    } else {
      HarnessMonitorWindowRootView(
        store: store,
        themeMode: $themeMode
      )
    }
  }

  private func increaseTextSize() {
    guard HarnessMonitorTextSize.canIncrease(textSizeIndex) else {
      return
    }
    textSizeIndex += 1
  }

  private func decreaseTextSize() {
    guard HarnessMonitorTextSize.canDecrease(textSizeIndex) else {
      return
    }
    textSizeIndex -= 1
  }

  private func resetTextSize() {
    textSizeIndex = HarnessMonitorTextSize.defaultIndex
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

  private func inspectSessionOverview() {
    store.inspectorSelection = .none
  }

  private func inspectObserver() {
    store.inspectObserver()
  }
}
